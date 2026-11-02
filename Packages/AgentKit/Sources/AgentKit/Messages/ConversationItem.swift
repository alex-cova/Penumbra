import Foundation

/// One entry of a conversation as the loop keeps it. Provider-neutral: each `LLMClient` renders
/// these into its own wire format.
public enum ConversationItem: Sendable, Hashable, Codable {
    case user(String)
    /// A user turn with text and image parts. `.user` stays so saved chats still decode.
    /// Image bytes live as files beside the session (`SessionStore`) and are referenced by id;
    /// they are never inline in the JSON.
    case userParts([UserPart])
    case assistant(String)
    /// `arguments` is the JSON object the model produced, as text.
    case toolCall(id: String, name: String, arguments: String)
    /// Every `toolCall` gets exactly one of these; both APIs reject a history with an unanswered call.
    case toolOutput(callID: String, output: String)
    case opaque(OpaqueItem)
}

/// One part of a `.userParts` message. Images are untrusted content: a dropped file, a paste,
/// or (later) a tool screenshot, never something the model produced.
public enum UserPart: Sendable, Hashable, Codable {
    case text(String)
    /// `id` names the image file beside the session; `mediaType` is `image/jpeg`, `image/png`,
    /// `image/gif` or `image/webp`.
    case image(id: String, mediaType: String)
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

    /// The text of a user turn, joining `.userParts` text parts. `nil` for anything else.
    public var userText: String? {
        switch self {
        case .user(let text): return text
        case .userParts(let parts):
            let texts = parts.compactMap { part -> String? in if case .text(let t) = part { t } else { nil } }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        default: return nil
        }
    }

    /// Image ids in a `.userParts` turn, in order. Empty for anything else.
    public var imageIDs: [String] {
        guard case .userParts(let parts) = self else { return [] }
        return parts.compactMap { part in if case .image(let id, _) = part { id } else { nil } }
    }

    /// Whether this turn carries at least one image.
    public var hasImages: Bool {
        guard case .userParts(let parts) = self else { return false }
        return parts.contains { if case .image = $0 { true } else { false } }
    }

    /// Whether this item opens a user turn (a plain or parts message). Turn tracking, cuts and
    /// history counts treat both alike.
    public var isUserTurn: Bool {
        switch self {
        case .user, .userParts: true
        default: false
        }
    }

    /// The note a client without image support (or with missing bytes) gets in place of an image.
    public static func imageUnavailableNote(id: String) -> String {
        "[image \(id) was attached but this model cannot see images, or the image file is missing. Describe what you need in words, or switch to a vision model.]"
    }

    /// The note compaction leaves where older images were.
    public static func imageElidedNote(count: Int) -> String {
        count == 1 ? "[image omitted to save context. Ask for it again if you need it.]"
            : "[\(count) images omitted to save context. Ask for them again if you need them.]"
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
