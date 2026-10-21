import Foundation

/// Builds the `/v1/messages` body. Stateless like the OpenAI encoders: the whole history every turn,
/// tool order and key order fixed so the prompt cache survives.
public enum AnthropicRequestEncoder {
    public static let providerID = "anthropic"

    /// What the API requires and the loop has no opinion on: the largest answer when the host sets none.
    static let defaultMaxTokens = 32_000

    public static func body(for request: LLMRequest) throws -> Data {
        let maxTokens = request.maxOutputTokens ?? defaultMaxTokens
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .int(maxTokens),
            "stream": true,
            "messages": .array(messages(for: request)),
        ]
        if !request.system.isEmpty { body["system"] = .string(request.system) }
        if !request.tools.isEmpty {
            // `eager_input_streaming` lets a large argument (a whole file) arrive as it is written; the
            // session already treats arguments that do not parse as a failed call.
            body["tools"] = .array(request.tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.schema(strict: false),
                    "eager_input_streaming": true,
                ])
            })
        }
        applyReasoning(to: &body, request: request, maxTokens: maxTokens)
        // The provider keys its cache on the prefix, not on a name: any key asks for caching.
        if request.cacheKey != nil { body["cache_control"] = ["type": "ephemeral"] }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(body))
    }

    // MARK: Reasoning

    /// Models that take `thinking: {type: "adaptive"}` and `output_config.effort`. Older ones need a
    /// token budget, and a model this list does not know is treated as old, which still works.
    static func supportsAdaptiveThinking(_ model: String) -> Bool {
        let adaptive = ["opus-5", "sonnet-5", "haiku-5", "fable-5", "mythos-5", "opus-4-6", "opus-4-7", "opus-4-8", "sonnet-4-6"]
        return adaptive.contains { model.contains($0) }
    }

    static let efforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    private static func applyReasoning(to body: inout [String: JSONValue], request: LLMRequest, maxTokens: Int) {
        guard let effort = request.reasoningEffort?.lowercased(), !effort.isEmpty else { return }
        if supportsAdaptiveThinking(request.model) {
            guard let level = normalizedEffort(effort) else { return }
            // `summarized` so the transcript can show the reasoning; the default would stream empty blocks.
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
            body["output_config"] = ["effort": .string(level)]
        } else {
            let budget: Int
            switch effort {
            case "minimal", "low": budget = 2_048
            case "medium": budget = 8_192
            default: budget = 16_000
            }
            // The budget must stay below `max_tokens` and above 1,024.
            let capped = min(budget, maxTokens - 1)
            if capped >= 1_024 { body["thinking"] = ["type": "enabled", "budget_tokens": .int(capped)] }
        }
    }

    private static func normalizedEffort(_ effort: String) -> String? {
        if efforts.contains(effort) { return effort }
        if effort == "minimal" { return "low" }
        return nil
    }

    // MARK: Messages

    /// An assistant turn is one message of thinking, text and `tool_use` blocks; the outputs of its
    /// calls are one user message of `tool_result` blocks (first, as the API requires) and any text
    /// the user or the editor added. Provider items from other APIs are dropped.
    static func messages(for request: LLMRequest) -> [JSONValue] {
        var result: [JSONValue] = []
        var assistant: [JSONValue] = []
        var toolResults: [JSONValue] = []
        var userText: [JSONValue] = []

        func flushAssistant() {
            guard !assistant.isEmpty else { return }
            result.append(["role": "assistant", "content": .array(assistant)])
            assistant = []
        }
        func flushUser() {
            let blocks = toolResults + userText
            guard !blocks.isEmpty else { return }
            result.append(["role": "user", "content": .array(blocks)])
            toolResults = []
            userText = []
        }

        for item in request.items {
            switch item {
            case .user(let text):
                flushAssistant()
                userText.append(["type": "text", "text": .string(text)])
            case .toolOutput(let callID, let output):
                flushAssistant()
                toolResults.append([
                    "type": "tool_result", "tool_use_id": .string(callID), "content": .string(output),
                ])
            case .assistant(let text):
                flushUser()
                // An empty text block is a 400.
                if !text.isEmpty { assistant.append(["type": "text", "text": .string(text)]) }
            case .toolCall(let id, let name, let arguments):
                flushUser()
                assistant.append([
                    "type": "tool_use", "id": .string(id), "name": .string(name), "input": input(from: arguments),
                ])
            case .opaque(let opaque):
                // A thinking block goes back exactly as it came, to the client that produced it.
                guard opaque.provider == providerID else { continue }
                flushUser()
                assistant.append(opaque.payload)
            }
        }
        flushAssistant()
        flushUser()
        return result
    }

    /// `input` must be an object. Arguments that did not parse were answered with an error already,
    /// so an empty object keeps the history valid.
    private static func input(from arguments: String) -> JSONValue {
        if let value = try? JSONValue(parsing: arguments), case .object = value { return value }
        return .object([:])
    }
}
