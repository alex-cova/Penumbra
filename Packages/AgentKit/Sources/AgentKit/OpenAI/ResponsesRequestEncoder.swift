import Foundation

/// Builds the `/v1/responses` body. Stateless by design: the full input every turn, `store: false`,
/// no `previous_response_id`, so the session owns history and nothing is kept on OpenAI's side.
public enum ResponsesRequestEncoder {
    public static let providerID = "openai-responses"

    public static func body(for request: LLMRequest, strictTools: Bool = true) throws -> Data {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "input": .array(request.items.compactMap(inputItem)),
            "stream": true,
            "store": false,
        ]
        if !request.system.isEmpty { body["instructions"] = .string(request.system) }
        if !request.tools.isEmpty {
            // Request order is the caller's order: it must stay fixed so the cached prefix survives.
            body["tools"] = .array(request.tools.map { tool in
                .object([
                    "type": "function",
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.schema(strict: strictTools),
                    "strict": .bool(strictTools),
                ])
            })
        }
        if let effort = request.reasoningEffort {
            body["reasoning"] = ["effort": .string(effort), "summary": "auto"]
            body["include"] = ["reasoning.encrypted_content"]
        }
        if let limit = request.maxOutputTokens { body["max_output_tokens"] = .int(limit) }
        if let key = request.cacheKey { body["prompt_cache_key"] = .string(key) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(body))
    }

    private static func inputItem(_ item: ConversationItem) -> JSONValue? {
        switch item {
        case .user(let text):
            return ["role": "user", "content": .string(text)]
        case .assistant(let text):
            return ["role": "assistant", "content": .string(text)]
        case .toolCall(let id, let name, let arguments):
            return ["type": "function_call", "call_id": .string(id), "name": .string(name), "arguments": .string(arguments)]
        case .toolOutput(let callID, let output):
            return ["type": "function_call_output", "call_id": .string(callID), "output": .string(output)]
        case .opaque(let opaque):
            // Replayed only to the client that produced it.
            return opaque.provider == providerID ? opaque.payload : nil
        }
    }
}
