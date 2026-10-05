import Foundation

/// Builds Ollama's native `/api/chat` body. The native API, not the OpenAI-compatible `/v1`, because
/// only it takes the context size (`options.num_ctx`): `/v1` runs at whatever the server was started
/// with and silently drops the oldest messages that don't fit.
public enum OllamaRequestEncoder {
    public static let providerID = "ollama"

    public static func body(
        for request: LLMRequest, contextLength: Int, supportsThinking: Bool, keepAlive: String = "30m"
    ) throws -> Data {
        var options: [String: JSONValue] = ["num_ctx": .int(contextLength)]
        if let limit = request.maxOutputTokens { options["num_predict"] = .int(limit) }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages(for: request)),
            "stream": true,
            "options": .object(options),
            "keep_alive": .string(keepAlive),
        ]
        // Only models that think accept the field; for them, say so either way, since some think by default.
        if supportsThinking { body["think"] = .bool(request.reasoningEffort != nil) }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                ["type": "function", "function": [
                    "name": .string(tool.name), "description": .string(tool.description), "parameters": tool.schema(strict: false),
                ]]
            })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(body))
    }

    /// Tool-call arguments are an object here (a string in OpenAI's API), and a tool message names
    /// the tool and the call, because Ollama versions differ in which one they match on.
    static func messages(for request: LLMRequest) -> [JSONValue] {
        var result: [JSONValue] = []
        if !request.system.isEmpty { result.append(["role": "system", "content": .string(request.system)]) }

        var toolNames: [String: String] = [:]
        var assistantText: String?
        var assistantCalls: [JSONValue] = []
        func flushAssistant() {
            guard assistantText != nil || !assistantCalls.isEmpty else { return }
            var message: [String: JSONValue] = ["role": "assistant", "content": .string(assistantText ?? "")]
            if !assistantCalls.isEmpty { message["tool_calls"] = .array(assistantCalls) }
            result.append(.object(message))
            assistantText = nil
            assistantCalls = []
        }

        for item in request.items {
            switch item {
            case .user(let text):
                flushAssistant()
                result.append(["role": "user", "content": .string(text)])
            case .assistant(let text):
                flushAssistant()
                assistantText = text
            case .toolCall(let id, let name, let arguments):
                toolNames[id] = name
                let object = (try? JSONValue(parsing: arguments))?.objectValue ?? [:]
                assistantCalls.append(["id": .string(id), "function": ["name": .string(name), "arguments": .object(object)]])
            case .toolOutput(let callID, let output):
                flushAssistant()
                var message: [String: JSONValue] = ["role": "tool", "content": .string(output), "tool_call_id": .string(callID)]
                if let name = toolNames[callID] { message["tool_name"] = .string(name) }
                result.append(.object(message))
            case .opaque:
                continue
            }
        }
        flushAssistant()
        return result
    }
}

/// Reads Ollama's NDJSON chat stream. Text and thinking arrive as deltas; tool calls arrive whole,
/// usually in the last (`done: true`) object, with their arguments already an object.
public struct OllamaEventDecoder: StreamDecoder {
    private var callCount = 0
    private var sawCall = false

    public init() {}

    public mutating func events(forPayload payload: String) throws -> [LLMEvent] {
        let json: JSONValue
        do { json = try JSONValue(parsing: payload) } catch { throw LLMError.malformedEvent("Invalid JSON in stream event.") }

        if let error = json["error"]?.stringValue {
            if HTTPErrorClassifier.isContextLength(error) { throw LLMError.contextLengthExceeded }
            throw LLMError.api(message: error, code: nil)
        }

        var events: [LLMEvent] = []
        let message = json["message"]
        if let thinking = message?["thinking"]?.stringValue, !thinking.isEmpty { events.append(.reasoningDelta(thinking)) }
        if let text = message?["content"]?.stringValue, !text.isEmpty { events.append(.textDelta(text)) }
        for call in message?["tool_calls"]?.arrayValue ?? [] {
            guard let name = call["function"]?["name"]?.stringValue else { continue }
            let id = call["id"]?.stringValue ?? "call_\(callCount)"
            callCount += 1
            sawCall = true
            let arguments: String
            switch call["function"]?["arguments"] {
            case .object(let object)?: arguments = (try? JSONValue.object(object).serialized()) ?? "{}"
            case .string(let text)?: arguments = text.isEmpty ? "{}" : text
            default: arguments = "{}"
            }
            events.append(.toolCallStarted(id: id, name: name))
            events.append(.toolCallFinished(id: id, name: name, arguments: arguments))
        }

        if json["done"]?.boolValue == true {
            events.append(.usage(TokenUsage(
                inputTokens: json["prompt_eval_count"]?.intValue ?? 0, outputTokens: json["eval_count"]?.intValue ?? 0)))
            events.append(.finished(json["done_reason"]?.stringValue == "length" ? .length : (sawCall ? .toolCalls : .completed)))
        }
        return events
    }
}

/// A local (or remote) Ollama server, through its native chat API.
public struct OllamaClient: LLMClient {
    public static let defaultBaseURL = URL(string: "http://localhost:11434")!

    public var providerID: String { OllamaRequestEncoder.providerID }

    public let endpoint: LLMEndpoint
    /// `options.num_ctx`. Kept fixed for a session: a different value makes Ollama reload the model.
    public let contextLength: Int
    public let supportsThinking: Bool
    public let keepAlive: String
    private let transport: any LLMTransport
    private let retry: RetryPolicy

    public init(
        endpoint: LLMEndpoint = LLMEndpoint(baseURL: OllamaClient.defaultBaseURL),
        contextLength: Int = 32_768,
        supportsThinking: Bool = false,
        keepAlive: String = "30m",
        transport: any LLMTransport = URLSessionTransport(),
        retry: RetryPolicy = .default
    ) {
        self.endpoint = endpoint
        self.contextLength = contextLength
        self.supportsThinking = supportsThinking
        self.keepAlive = keepAlive
        self.transport = transport
        self.retry = retry
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let endpoint = endpoint
        let (contextLength, supportsThinking, keepAlive) = (contextLength, supportsThinking, keepAlive)
        return HTTPStreamClient(
            transport: transport, retry: retry, framing: .ndjson,
            makeRequest: {
                endpoint.urlRequest(
                    path: "api/chat",
                    body: try OllamaRequestEncoder.body(
                        for: request, contextLength: contextLength, supportsThinking: supportsThinking, keepAlive: keepAlive),
                    accept: "application/x-ndjson")
            },
            makeDecoder: { OllamaEventDecoder() }
        ).stream()
    }
}

