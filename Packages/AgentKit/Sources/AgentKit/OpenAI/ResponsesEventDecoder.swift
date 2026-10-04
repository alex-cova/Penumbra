import Foundation

/// Turns the `data:` payloads of one Responses stream into `LLMEvent`s. Holds the state a stream
/// needs: argument deltas name an item, not a call.
public struct ResponsesEventDecoder: Sendable {
    private var callIDByItemID: [String: String] = [:]
    private var sawToolCall = false

    public init() {}

    /// Anything not listed here decodes to nothing and is skipped. Throws for `error` and
    /// `response.failed`.
    public mutating func events(forPayload payload: String) throws -> [LLMEvent] {
        let json: JSONValue
        do {
            json = try JSONValue(parsing: payload)
        } catch {
            throw LLMError.malformedEvent("Invalid JSON in stream event.")
        }
        guard let type = json["type"]?.stringValue else { return [] }

        switch type {
        case "response.output_text.delta":
            return json["delta"]?.stringValue.map { [.textDelta($0)] } ?? []

        case "response.reasoning_summary_text.delta":
            return json["delta"]?.stringValue.map { [.reasoningDelta($0)] } ?? []

        case "response.output_item.added":
            guard let item = json["item"], item["type"]?.stringValue == "function_call",
                  let callID = item["call_id"]?.stringValue, let name = item["name"]?.stringValue
            else { return [] }
            if let itemID = item["id"]?.stringValue { callIDByItemID[itemID] = callID }
            sawToolCall = true
            return [.toolCallStarted(id: callID, name: name)]

        case "response.function_call_arguments.delta":
            guard let itemID = json["item_id"]?.stringValue, let callID = callIDByItemID[itemID],
                  let delta = json["delta"]?.stringValue
            else { return [] }
            return [.toolCallArgumentsDelta(id: callID, delta: delta)]

        case "response.output_item.done":
            guard let item = json["item"], let itemType = item["type"]?.stringValue else { return [] }
            switch itemType {
            case "function_call":
                guard let callID = item["call_id"]?.stringValue, let name = item["name"]?.stringValue else { return [] }
                sawToolCall = true
                return [.toolCallFinished(id: callID, name: name, arguments: item["arguments"]?.stringValue ?? "{}")]
            case "reasoning":
                // Kept whole, `encrypted_content` included, so the next turn can replay it. Without
                // it (the request didn't ask for it) the item is only a reference to something the
                // server never stored (`store: false`), and sending it back fails.
                guard item["encrypted_content"]?.stringValue != nil else { return [] }
                return [.opaqueItem(OpaqueItem(provider: ResponsesRequestEncoder.providerID, payload: item))]
            default:
                return []
            }

        case "response.completed":
            let response = json["response"]
            return usage(from: response).map { [.usage($0)] }.orEmpty
                + [.finished(sawToolCall ? .toolCalls : .completed)]

        case "response.incomplete":
            let response = json["response"]
            let reason = response?["incomplete_details"]?["reason"]?.stringValue
            let finish: FinishReason = reason == "content_filter" ? .contentFilter : .length
            return usage(from: response).map { [.usage($0)] }.orEmpty + [.finished(finish)]

        case "response.failed":
            let error = json["response"]?["error"]
            throw LLMError.api(
                message: error?["message"]?.stringValue ?? "The response failed.",
                code: error?["code"]?.stringValue)

        case "error":
            throw LLMError.api(
                message: json["message"]?.stringValue ?? "The API reported an error.",
                code: json["code"]?.stringValue)

        default:
            return []
        }
    }

    private func usage(from response: JSONValue?) -> TokenUsage? {
        guard let usage = response?["usage"] else { return nil }
        return TokenUsage(
            inputTokens: usage["input_tokens"]?.intValue ?? 0,
            outputTokens: usage["output_tokens"]?.intValue ?? 0,
            cachedInputTokens: usage["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0,
            reasoningTokens: usage["output_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0)
    }
}

private extension Optional where Wrapped == [LLMEvent] {
    var orEmpty: [LLMEvent] { self ?? [] }
}
