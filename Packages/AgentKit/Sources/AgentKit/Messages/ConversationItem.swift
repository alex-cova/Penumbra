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

extension ConversationItem {
    /// `items` with an output added after any tool call that has none. A history saved while a run was
    /// going (the app closed, a crash) can end in calls nobody answered, and both APIs reject that. The
    /// output says the call may have partly run, so the model checks before repeating it. Idempotent.
    public static func answeringUnansweredCalls(_ items: [ConversationItem]) -> [ConversationItem] {
        var answered = Set<String>()
        for case .toolOutput(let callID, _) in items { answered.insert(callID) }
        guard items.contains(where: { if case .toolCall(let id, _, _) = $0 { !answered.contains(id) } else { false } }) else {
            return items
        }
        var result: [ConversationItem] = []
        var group: [(id: String, name: String)] = []
        func closeGroup() {
            for call in group where !answered.contains(call.id) {
                result.append(.toolOutput(callID: call.id, output: interruptedCallOutput(name: call.name)))
            }
            group = []
        }
        for item in items {
            switch item {
            case .toolCall(let id, let name, _):
                group.append((id, name))
            case .toolOutput:
                break
            default:
                closeGroup()
            }
            result.append(item)
        }
        closeGroup()
        return result
    }

    static func interruptedCallOutput(name: String) -> String {
        "Tool execution interrupted: \(name). The app closed before it returned, so it may have partly run. Check the current state (read the file, git_status) before repeating it."
    }
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

    /// What was added since `earlier`, never below zero.
    func minus(_ earlier: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: max(0, inputTokens - earlier.inputTokens),
            outputTokens: max(0, outputTokens - earlier.outputTokens),
            cachedInputTokens: max(0, cachedInputTokens - earlier.cachedInputTokens),
            reasoningTokens: max(0, reasoningTokens - earlier.reasoningTokens))
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            reasoningTokens: lhs.reasoningTokens + rhs.reasoningTokens)
    }
}
