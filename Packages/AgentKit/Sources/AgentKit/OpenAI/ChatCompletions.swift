import Foundation

/// What a Chat Completions endpoint accepts. Servers that speak the protocol differ in the corners,
/// so each endpoint carries its own flags and the request leaves out what it would reject.
public struct ChatCompletionsCapabilities: Sendable, Equatable {
    /// `strict: true` on tools, with every property required and optional ones nullable.
    public var strictTools: Bool
    /// `stream_options.include_usage`: usage in a last chunk. Without it the budget falls back to estimates.
    public var usageInStream: Bool
    /// Sent as `parallel_tool_calls` when set; `nil` leaves the server's default.
    public var parallelToolCalls: Bool?
    /// `max_completion_tokens` (newer OpenAI) or `max_tokens` (everything else).
    public var maxTokensField: String
    public var sendsReasoningEffort: Bool
    public var promptCacheKey: Bool

    public init(
        strictTools: Bool, usageInStream: Bool, parallelToolCalls: Bool? = nil,
        maxTokensField: String, sendsReasoningEffort: Bool, promptCacheKey: Bool
    ) {
        self.strictTools = strictTools
        self.usageInStream = usageInStream
        self.parallelToolCalls = parallelToolCalls
        self.maxTokensField = maxTokensField
        self.sendsReasoningEffort = sendsReasoningEffort
        self.promptCacheKey = promptCacheKey
    }

    public static let openAI = ChatCompletionsCapabilities(
        strictTools: true, usageInStream: true, maxTokensField: "max_completion_tokens",
        sendsReasoningEffort: true, promptCacheKey: true)

    /// Azure, LM Studio, Ollama's `/v1` and the like: the conservative subset.
    public static let compatible = ChatCompletionsCapabilities(
        strictTools: false, usageInStream: true, maxTokensField: "max_tokens",
        sendsReasoningEffort: false, promptCacheKey: false)
}

/// Builds the `/v1/chat/completions` body. Stateless like the Responses encoder: the whole history
/// every turn, tool order and key order fixed.
public enum ChatCompletionsRequestEncoder {
    public static let providerID = "openai-chat"

    public static func body(for request: LLMRequest, capabilities: ChatCompletionsCapabilities) throws -> Data {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages(for: request)),
            "stream": true,
        ]
        if capabilities.usageInStream { body["stream_options"] = ["include_usage": true] }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                var function: [String: JSONValue] = [
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.schema(strict: capabilities.strictTools),
                ]
                if capabilities.strictTools { function["strict"] = true }
                return ["type": "function", "function": .object(function)]
            })
            if let parallel = capabilities.parallelToolCalls { body["parallel_tool_calls"] = .bool(parallel) }
        }
        if capabilities.sendsReasoningEffort, let effort = request.reasoningEffort { body["reasoning_effort"] = .string(effort) }
        if let limit = request.maxOutputTokens { body[capabilities.maxTokensField] = .int(limit) }
        if capabilities.promptCacheKey, let key = request.cacheKey { body["prompt_cache_key"] = .string(key) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(body))
    }

    /// An assistant turn's text and tool calls are one message with `tool_calls`; each output is a
    /// `tool` message. Provider items from other APIs are dropped.
    static func messages(for request: LLMRequest) -> [JSONValue] {
        var result: [JSONValue] = []
        if !request.system.isEmpty { result.append(["role": "system", "content": .string(request.system)]) }

        var assistantText: String?
        var assistantCalls: [JSONValue] = []
        func flushAssistant() {
            guard assistantText != nil || !assistantCalls.isEmpty else { return }
            var message: [String: JSONValue] = ["role": "assistant", "content": assistantText.map(JSONValue.string) ?? .null]
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
                assistantCalls.append([
                    "id": .string(id), "type": "function",
                    "function": ["name": .string(name), "arguments": .string(arguments)],
                ])
            case .toolOutput(let callID, let output):
                flushAssistant()
                result.append(["role": "tool", "tool_call_id": .string(callID), "content": .string(output)])
            case .opaque:
                continue
            }
        }
        flushAssistant()
        return result
    }
}

/// Reads a Chat Completions stream. Tool calls arrive as fragments keyed by `index` (the id and name
/// only in the first); usage comes in a last chunk with no choices, after `finish_reason`; so the end
/// is emitted when the server says `[DONE]`.
public struct ChatCompletionsEventDecoder: StreamDecoder {
    private struct Call {
        var id: String
        var name = ""
        var arguments = ""
        var started = false
    }

    private var calls: [Int: Call] = [:]
    private var order: [Int] = []
    private var finishReason: String?

    public init() {}

    public var isComplete: Bool { finishReason != nil }

    public mutating func events(forPayload payload: String) throws -> [LLMEvent] {
        let json: JSONValue
        do { json = try JSONValue(parsing: payload) } catch { throw LLMError.malformedEvent("Invalid JSON in stream event.") }

        if let error = json["error"], error != .null {
            throw LLMError.api(
                message: error["message"]?.stringValue ?? error.stringValue ?? "The API reported an error.",
                code: error["code"]?.stringValue)
        }

        var events: [LLMEvent] = []
        if let choice = json["choices"]?.arrayValue?.first {
            let delta = choice["delta"]
            // Servers disagree on the name: `reasoning_content` (DeepSeek, vLLM), `reasoning` (Ollama).
            if let reasoning = (delta?["reasoning_content"]?.stringValue ?? delta?["reasoning"]?.stringValue), !reasoning.isEmpty {
                events.append(.reasoningDelta(reasoning))
            }
            if let text = delta?["content"]?.stringValue, !text.isEmpty { events.append(.textDelta(text)) }
            for fragment in delta?["tool_calls"]?.arrayValue ?? [] { events += apply(fragment) }
            if let reason = choice["finish_reason"]?.stringValue { finishReason = reason }
        }
        if let usage = json["usage"], usage != .null {
            events.append(.usage(TokenUsage(
                inputTokens: usage["prompt_tokens"]?.intValue ?? 0,
                outputTokens: usage["completion_tokens"]?.intValue ?? 0,
                cachedInputTokens: usage["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0,
                reasoningTokens: usage["completion_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0)))
        }
        return events
    }

    private mutating func apply(_ fragment: JSONValue) -> [LLMEvent] {
        let index = fragment["index"]?.intValue ?? order.count
        if calls[index] == nil {
            calls[index] = Call(id: fragment["id"]?.stringValue ?? "call_\(index)")
            order.append(index)
        }
        var events: [LLMEvent] = []
        if let id = fragment["id"]?.stringValue, !id.isEmpty, calls[index]?.started == false { calls[index]?.id = id }
        if let name = fragment["function"]?["name"]?.stringValue, !name.isEmpty, calls[index]?.started == false {
            calls[index]?.name = name
            calls[index]?.started = true
            events.append(.toolCallStarted(id: calls[index]!.id, name: name))
        }
        if let arguments = fragment["function"]?["arguments"]?.stringValue, !arguments.isEmpty {
            calls[index]?.arguments += arguments
            if calls[index]?.started == true { events.append(.toolCallArgumentsDelta(id: calls[index]!.id, delta: arguments)) }
        }
        return events
    }

    public mutating func finish() throws -> [LLMEvent] {
        var events: [LLMEvent] = []
        for index in order {
            guard let call = calls[index], call.started else { continue }
            events.append(.toolCallFinished(id: call.id, name: call.name, arguments: call.arguments.isEmpty ? "{}" : call.arguments))
        }
        let hasCalls = events.contains { if case .toolCallFinished = $0 { true } else { false } }
        let reason: FinishReason
        switch finishReason {
        case "length": reason = .length
        case "content_filter": reason = .contentFilter
        // Some servers say "stop" even when the turn made calls.
        default: reason = hasCalls ? .toolCalls : .completed
        }
        events.append(.finished(reason))
        return events
    }
}

/// OpenAI's `/v1/chat/completions`, and the many servers that copy it (Azure, LM Studio, vLLM,
/// Ollama's `/v1`). Pick `capabilities` for the endpoint.
public struct OpenAIChatCompletionsClient: LLMClient {
    public var providerID: String { ChatCompletionsRequestEncoder.providerID }

    public let endpoint: LLMEndpoint
    public let capabilities: ChatCompletionsCapabilities
    private let transport: any LLMTransport
    private let retry: RetryPolicy

    public init(
        endpoint: LLMEndpoint = .openAI,
        capabilities: ChatCompletionsCapabilities = .openAI,
        transport: any LLMTransport = URLSessionTransport(),
        retry: RetryPolicy = .default
    ) {
        self.endpoint = endpoint
        self.capabilities = capabilities
        self.transport = transport
        self.retry = retry
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let endpoint = endpoint
        let capabilities = capabilities
        return HTTPStreamClient(
            transport: transport, retry: retry, framing: .sse,
            makeRequest: {
                endpoint.urlRequest(path: "chat/completions", body: try ChatCompletionsRequestEncoder.body(for: request, capabilities: capabilities))
            },
            makeDecoder: { ChatCompletionsEventDecoder() }
        ).stream()
    }
}
