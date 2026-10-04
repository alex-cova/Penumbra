import Foundation

/// One entry of a conversation as the loop keeps it. Provider-neutral: each `LLMClient` renders
/// these into its own wire format.
public enum ConversationItem: Sendable, Hashable, Codable {
    case user(String)
    case assistant(String)
    /// `arguments` is the JSON object the model produced, as text.
    case toolCall(id: String, name: String, arguments: String)
    /// Every `toolCall` gets exactly one of these; both APIs reject a history with an unanswered call.
    case toolOutput(callID: String, output: String)
    case opaque(OpaqueItem)
}

/// A provider item the loop stores and replays without reading, such as an OpenAI reasoning item
/// with `encrypted_content`. Only the client that produced it may send it back.
public struct OpaqueItem: Sendable, Hashable, Codable {
    /// `LLMClient.providerID` of the producer.
    public let provider: String
    public let payload: JSONValue

    public init(provider: String, payload: JSONValue) {
        self.provider = provider
        self.payload = payload
    }
}

public struct TokenUsage: Sendable, Hashable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// Part of `inputTokens` the provider served from its prompt cache.
    public var cachedInputTokens: Int
    public var reasoningTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0, reasoningTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens)
    }
}
