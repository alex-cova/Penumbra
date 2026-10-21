import Foundation

/// Reads a Messages API stream. Content arrives as numbered blocks (text, thinking, `tool_use`)
/// that open, receive deltas and close; usage is split between `message_start` (input) and
/// `message_delta` (output, cumulative), so it is reported once, at `message_stop`.
public struct AnthropicEventDecoder: StreamDecoder {
    private enum Block {
        case text
        case thinking(text: String, signature: String)
        case toolUse(id: String, name: String, arguments: String)
        case ignored
    }

    private var blocks: [Int: Block] = [:]
    private var inputTokens = 0
    private var cacheReadTokens = 0
    private var cacheCreationTokens = 0
    private var outputTokens = 0
    private var stopReason: String?
    private var sawStop = false

    public init() {}

    public var isComplete: Bool { sawStop }

    public mutating func events(forPayload payload: String) throws -> [LLMEvent] {
        let json: JSONValue
        do { json = try JSONValue(parsing: payload) } catch { throw LLMError.malformedEvent("Invalid JSON in stream event.") }

        switch json["type"]?.stringValue {
        case "message_start":
            readUsage(json["message"]?["usage"])
            return []
        case "content_block_start":
            return start(index: json["index"]?.intValue ?? 0, block: json["content_block"])
        case "content_block_delta":
            return delta(index: json["index"]?.intValue ?? 0, delta: json["delta"])
        case "content_block_stop":
            return stop(index: json["index"]?.intValue ?? 0)
        case "message_delta":
            if let reason = json["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
            readUsage(json["usage"])
            return []
        case "message_stop":
            sawStop = true
            return finish()
        case "error":
            throw Self.error(from: json["error"])
        default:
            // `ping` and event types this decoder does not know.
            return []
        }
    }

    public mutating func finish() -> [LLMEvent] {
        var events: [LLMEvent] = []
        // Anthropic's input count leaves out what the cache served; ours includes it.
        let input = inputTokens + cacheReadTokens + cacheCreationTokens
        events.append(.usage(TokenUsage(inputTokens: input, outputTokens: outputTokens, cachedInputTokens: cacheReadTokens)))
        let reason: FinishReason
        switch stopReason {
        case "tool_use": reason = .toolCalls
        case "max_tokens", "model_context_window_exceeded": reason = .length
        case "refusal": reason = .contentFilter
        default: reason = .completed
        }
        events.append(.finished(reason))
        return events
    }

    // MARK: Blocks

    private mutating func start(index: Int, block: JSONValue?) -> [LLMEvent] {
        switch block?["type"]?.stringValue {
        case "text":
            blocks[index] = .text
            if let text = block?["text"]?.stringValue, !text.isEmpty { return [.textDelta(text)] }
            return []
        case "thinking":
            blocks[index] = .thinking(text: block?["thinking"]?.stringValue ?? "", signature: block?["signature"]?.stringValue ?? "")
            return []
        case "redacted_thinking":
            // Nothing to show; it only has to go back unchanged.
            blocks[index] = .ignored
            guard let block else { return [] }
            return [.opaqueItem(OpaqueItem(provider: AnthropicRequestEncoder.providerID, payload: block))]
        case "tool_use":
            let id = block?["id"]?.stringValue ?? "toolu_\(index)"
            let name = block?["name"]?.stringValue ?? ""
            blocks[index] = .toolUse(id: id, name: name, arguments: "")
            return [.toolCallStarted(id: id, name: name)]
        default:
            // Server tools and block types added later.
            blocks[index] = .ignored
            return []
        }
    }

    private mutating func delta(index: Int, delta: JSONValue?) -> [LLMEvent] {
        guard let kind = delta?["type"]?.stringValue else { return [] }
        switch (kind, blocks[index]) {
        case ("text_delta", _):
            guard let text = delta?["text"]?.stringValue, !text.isEmpty else { return [] }
            return [.textDelta(text)]
        case ("thinking_delta", .thinking(let text, let signature)?):
            let piece = delta?["thinking"]?.stringValue ?? ""
            blocks[index] = .thinking(text: text + piece, signature: signature)
            return piece.isEmpty ? [] : [.reasoningDelta(piece)]
        case ("signature_delta", .thinking(let text, let signature)?):
            blocks[index] = .thinking(text: text, signature: signature + (delta?["signature"]?.stringValue ?? ""))
            return []
        case ("input_json_delta", .toolUse(let id, let name, let arguments)?):
            let piece = delta?["partial_json"]?.stringValue ?? ""
            blocks[index] = .toolUse(id: id, name: name, arguments: arguments + piece)
            return piece.isEmpty ? [] : [.toolCallArgumentsDelta(id: id, delta: piece)]
        default:
            return []
        }
    }

    private mutating func stop(index: Int) -> [LLMEvent] {
        defer { blocks[index] = nil }
        switch blocks[index] {
        case .thinking(let text, let signature)?:
            // A block with no signature cannot be replayed, so it is not kept.
            guard !signature.isEmpty else { return [] }
            let payload: JSONValue = ["type": "thinking", "thinking": .string(text), "signature": .string(signature)]
            return [.opaqueItem(OpaqueItem(provider: AnthropicRequestEncoder.providerID, payload: payload))]
        case .toolUse(let id, let name, let arguments)?:
            return [.toolCallFinished(id: id, name: name, arguments: arguments.isEmpty ? "{}" : arguments)]
        default:
            return []
        }
    }

    // MARK: Usage and errors

    private mutating func readUsage(_ usage: JSONValue?) {
        guard let usage else { return }
        if let value = usage["input_tokens"]?.intValue { inputTokens = value }
        if let value = usage["cache_read_input_tokens"]?.intValue { cacheReadTokens = value }
        if let value = usage["cache_creation_input_tokens"]?.intValue { cacheCreationTokens = value }
        if let value = usage["output_tokens"]?.intValue { outputTokens = value }
    }

    /// An `error` event inside a stream that started fine. Overload and rate limits are worth a retry,
    /// so they map to the errors `RetryPolicy` retries.
    static func error(from error: JSONValue?) -> LLMError {
        let type = error?["type"]?.stringValue
        let message = error?["message"]?.stringValue ?? "The API reported an error."
        switch type {
        case "overloaded_error", "api_error": return .server(status: 529, message: message)
        case "rate_limit_error": return .rateLimited(retryAfter: nil)
        case "authentication_error", "permission_error": return .unauthorized
        case "invalid_request_error" where HTTPErrorClassifier.isContextLength(message): return .contextLengthExceeded
        default: return .api(message: message, code: type)
        }
    }
}
