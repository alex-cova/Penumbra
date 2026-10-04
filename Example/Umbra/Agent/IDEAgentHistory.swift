import AgentKit
import Foundation

/// The part of a transcript row that survives a restart. Live output, approval cards and the
/// "files changed" card do not: the checkpoints behind them are in memory, so Revert would not work.
struct IDEAgentPersistedEntry: Codable, Equatable {
    enum Kind: String, Codable { case user, assistant, toolCall, notice, error, changes }

    var kind: Kind
    var text: String
    var toolName: String?
    var callID: String?
    var outputText: String?
    var outputIsError: Bool?
    var detail: String?
    var attachments: [String]?
    var planOutcome: String?
    var itemIndex: Int?
    /// For the "files changed" card: the run, its files, which of them the run created, and whether it was reverted.
    var run: UUID?
    var paths: [String]?
    var created: [String]?
    var isReverted: Bool?

    init?(_ entry: IDEAgentEntry) {
        text = entry.text
        callID = entry.callID
        detail = entry.detail
        attachments = entry.attachments.isEmpty ? nil : entry.attachments
        itemIndex = entry.itemIndex
        switch entry.kind {
        case .user: kind = .user
        case .assistant: kind = .assistant
        case .notice: kind = .notice
        case .error: kind = .error
        case .changes:
            // The card is kept only for a run whose originals are on disk (see `restoredEntry`).
            guard let run = entry.run, !entry.fileChanges.isEmpty else { return nil }
            kind = .changes
            self.run = run
            paths = entry.fileChanges.map(\.path)
            created = entry.fileChanges.filter(\.isCreation).map(\.path)
            isReverted = entry.isReverted
        case .toolCall(let name):
            // A call that never finished (the app quit mid-run) has nothing worth showing.
            guard let output = entry.output else { return nil }
            kind = .toolCall
            toolName = name
            outputText = output.text
            outputIsError = output.isError
            planOutcome = entry.planOutcome
        }
    }

    /// The row for the transcript. A "files changed" card needs the originals from `blobs`, so it comes
    /// back only when they are all there: without them neither Show Diff nor Revert could work.
    func restoredEntry(blobs: (any CheckpointBlobStore)?) -> IDEAgentEntry? {
        guard kind == .changes else { return entry }
        guard let run, let paths, !paths.isEmpty else { return nil }
        let created = Set(self.created ?? [])
        var changes: [IDEAgentFileChange] = []
        for path in paths {
            if created.contains(path) {
                changes.append(IDEAgentFileChange(path: path, original: nil))
            } else if let original = blobs?.get(run: run, path: path) {
                changes.append(IDEAgentFileChange(path: path, original: original))
            } else {
                return nil
            }
        }
        var entry = IDEAgentEntry(kind: .changes, text: "")
        entry.run = run
        entry.fileChanges = changes
        entry.isReverted = isReverted ?? false
        return entry
    }

    var entry: IDEAgentEntry {
        switch kind {
        case .changes: IDEAgentEntry(kind: .changes, text: "")
        case .user:
            {
                var entry = IDEAgentEntry(kind: .user, text: text)
                entry.detail = detail
                entry.attachments = attachments ?? []
                entry.itemIndex = itemIndex
                return entry
            }()
        case .assistant: IDEAgentEntry(kind: .assistant, text: text)
        case .notice: IDEAgentEntry(kind: .notice, text: text)
        case .error: IDEAgentEntry(kind: .error, text: text)
        case .toolCall:
            {
                var entry = IDEAgentEntry(kind: .toolCall(name: toolName ?? "tool"), text: text, callID: callID)
                entry.output = ToolOutput(outputText ?? "", isError: outputIsError ?? false)
                entry.planOutcome = planOutcome
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
    static func encode(
        entries: [IDEAgentEntry], cost: Double?, todos: [TodoItem] = [], customTitle: String? = nil, checkpoints: [RunSnapshot] = []
    ) -> Data? {
        try? JSONEncoder().encode(IDEAgentSavedTranscript(
            entries: entries.compactMap(IDEAgentPersistedEntry.init), cost: cost, todos: todos.isEmpty ? nil : todos,
            customTitle: customTitle?.isEmpty == false ? customTitle : nil, checkpoints: checkpoints.isEmpty ? nil : checkpoints))
    }

    /// A blob from before cost was saved is a bare array of rows; it reads as having no known cost.
    static func decode(_ data: Data?) -> (
        entries: [IDEAgentPersistedEntry], cost: Double?, todos: [TodoItem], customTitle: String?, checkpoints: [RunSnapshot]
    ) {
        guard let data else { return ([], 0, [], nil, []) }
        if let saved = try? JSONDecoder().decode(IDEAgentSavedTranscript.self, from: data) {
            return (saved.entries, saved.cost, saved.todos ?? [], saved.customTitle, saved.checkpoints ?? [])
        }
        if let rows = try? JSONDecoder().decode([IDEAgentPersistedEntry].self, from: data) { return (rows, nil, [], nil, []) }
        return ([], 0, [], nil, [])
    }
}
