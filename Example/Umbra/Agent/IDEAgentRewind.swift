import AgentKit
import Foundation

/// A message a chat can go back to, and what going back would undo.
struct IDEAgentRewindTarget: Identifiable, Equatable {
    /// The user entry's id.
    let id: UUID
    let text: String
    /// Where the message sits in the session's history.
    let itemIndex: Int
    /// Runs from this message on that changed files and are not reverted yet, oldest first.
    let runs: [RunID]
    /// Files those runs changed, counted per run.
    let files: Int
    /// How many messages of yours come after it.
    let laterMessages: Int
}

enum IDEAgentRewind {
    /// Messages that can be rewound to, newest first. A message needs a recorded position; compaction
    /// removes them from everything before it.
    static func targets(in entries: [IDEAgentEntry]) -> [IDEAgentRewindTarget] {
        var targets: [IDEAgentRewindTarget] = []
        for (position, entry) in entries.enumerated() where entry.kind == .user {
            guard let itemIndex = entry.itemIndex else { continue }
            let later = entries[(position + 1)...]
            let cards = later.filter { $0.kind == .changes && !$0.isReverted && $0.run != nil }
            targets.append(IDEAgentRewindTarget(
                id: entry.id, text: entry.text, itemIndex: itemIndex, runs: cards.compactMap(\.run),
                files: cards.reduce(0) { $0 + $1.fileChanges.count }, laterMessages: later.filter { $0.kind == .user }.count))
        }
        return targets.reversed()
    }

    enum Scope: Equatable, CaseIterable {
        /// Take the conversation back to before the message; the files stay as they are.
        case conversation
        /// Put the files back as they were before the message; the conversation stays.
        case code
        case both

        var title: String {
            switch self {
            case .conversation: "Conversation only"
            case .code: "Code only"
            case .both: "Code and conversation"
            }
        }

        var detail: String {
            switch self {
            case .conversation: "Forget everything from this message on. Files the agent changed since stay as they are."
            case .code: "Revert the files the agent changed from this message on. The conversation stays."
            case .both: "Revert those files and forget everything from this message on."
            }
        }
    }
}

/// A request to show the rewind sheet, optionally on one message.
struct IDEAgentRewindRequest: Identifiable {
    let id = UUID()
    var entryID: UUID?
}
