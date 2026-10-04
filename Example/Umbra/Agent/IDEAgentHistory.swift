import AgentKit
import Foundation

/// The part of a transcript row that survives a restart. Live output, approval cards and the
/// "files changed" card do not: the checkpoints behind them are in memory, so Revert would not work.
struct IDEAgentPersistedEntry: Codable, Equatable {
    enum Kind: String, Codable { case user, assistant, toolCall, notice, error }

    var kind: Kind
    var text: String
    var toolName: String?
    var callID: String?
    var outputText: String?
    var outputIsError: Bool?
    var detail: String?

    init?(_ entry: IDEAgentEntry) {
        text = entry.text
        callID = entry.callID
        detail = entry.detail
        switch entry.kind {
        case .user: kind = .user
        case .assistant: kind = .assistant
        case .notice: kind = .notice
        case .error: kind = .error
        case .changes: return nil
        case .toolCall(let name):
            // A call that never finished (the app quit mid-run) has nothing worth showing.
            guard let output = entry.output else { return nil }
            kind = .toolCall
            toolName = name
            outputText = output.text
            outputIsError = output.isError
        }
    }

    var entry: IDEAgentEntry {
        switch kind {
        case .user:
            {
                var entry = IDEAgentEntry(kind: .user, text: text)
                entry.detail = detail
                return entry
            }()
        case .assistant: IDEAgentEntry(kind: .assistant, text: text)
        case .notice: IDEAgentEntry(kind: .notice, text: text)
        case .error: IDEAgentEntry(kind: .error, text: text)
        case .toolCall:
            {
                var entry = IDEAgentEntry(kind: .toolCall(name: toolName ?? "tool"), text: text, callID: callID)
                entry.output = ToolOutput(outputText ?? "", isError: outputIsError ?? false)
                return entry
            }()
        }
    }

    static func encode(_ entries: [IDEAgentEntry]) -> Data? {
        try? JSONEncoder().encode(entries.compactMap(IDEAgentPersistedEntry.init))
    }

    static func decode(_ data: Data?) -> [IDEAgentEntry] {
        guard let data, let persisted = try? JSONDecoder().decode([IDEAgentPersistedEntry].self, from: data) else { return [] }
        return persisted.map(\.entry)
    }
}

extension IDEAgentSavedTranscript {
    static func encode(entries: [IDEAgentEntry], cost: Double?, todos: [TodoItem] = [], customTitle: String? = nil) -> Data? {
        try? JSONEncoder().encode(IDEAgentSavedTranscript(
            entries: entries.compactMap(IDEAgentPersistedEntry.init), cost: cost, todos: todos.isEmpty ? nil : todos,
            customTitle: customTitle?.isEmpty == false ? customTitle : nil))
    }

    /// A blob from before cost was saved is a bare array of rows; it reads as having no known cost.
    static func decode(_ data: Data?) -> (entries: [IDEAgentPersistedEntry], cost: Double?, todos: [TodoItem], customTitle: String?) {
        guard let data else { return ([], 0, [], nil) }
        if let saved = try? JSONDecoder().decode(IDEAgentSavedTranscript.self, from: data) {
            return (saved.entries, saved.cost, saved.todos ?? [], saved.customTitle)
        }
        if let rows = try? JSONDecoder().decode([IDEAgentPersistedEntry].self, from: data) { return (rows, nil, [], nil) }
        return ([], 0, [], nil)
    }
}
