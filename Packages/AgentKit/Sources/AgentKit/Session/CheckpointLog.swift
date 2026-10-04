import Foundation

public typealias RunID = UUID

/// What one run did to one file: the text before the run's first change (`nil` when the file did
/// not exist), and a hash of the last text the agent wrote, which is how Revert knows the user has
/// not touched the file since.
public struct FileChange: Sendable, Hashable {
    public let path: String
    public let original: String?
    public fileprivate(set) var lastWrittenHash: UInt64?

    public var isCreation: Bool { original == nil }
}

public struct RunRecord: Sendable, Hashable, Identifiable {
    public let id: RunID
    public let label: String
    public let startedAt: Date
    /// In the order the files were first changed.
    public fileprivate(set) var changes: [FileChange]
    public fileprivate(set) var isReverted: Bool
}

/// A file Revert did not restore because its text is no longer what the agent wrote. It is never
/// overwritten; the host shows both sides for the user to decide.
public struct RevertConflict: Sendable, Hashable {
    public let path: String
    public let original: String?
    /// `nil` when the file is gone.
    public let current: String?
}

public struct RevertReport: Sendable, Hashable {
    public var reverted: [String] = []
    public var conflicts: [RevertConflict] = []
    public var failures: [String: String] = [:]

    public var isComplete: Bool { conflicts.isEmpty && failures.isEmpty }
}

/// Checkpoints per run, kept in memory for the window's lifetime. Before a file's first change in a
/// run its original text is recorded; after each change the hash of what was written. The oldest
/// runs are dropped past `maxBytes`, so they lose Revert first.
public actor CheckpointLog {
    public private(set) var runs: [RunRecord] = []
    private var labels: [RunID: String] = [:]
    private let maxBytes: Int

    public init(maxBytes: Int = 32_000_000) {
        self.maxBytes = maxBytes
    }

    /// Registers a run. It only becomes a record once it changes a file.
    public func beginRun(label: String) -> RunID {
        let id = RunID()
        labels[id] = String(label.prefix(80))
        return id
    }

    public func run(_ id: RunID) -> RunRecord? { runs.first { $0.id == id } }

    public func changes(in id: RunID) -> [FileChange] { run(id)?.changes ?? [] }

    /// Hash of the last text the agent wrote to each file in this run. A host compares an open,
    /// unsaved buffer against it to tell the agent's edits from the user's own.
    public func writtenHashes(in id: RunID) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for change in changes(in: id) {
            if let hash = change.lastWrittenHash { result[change.path] = hash }
        }
        return result
    }

    public nonisolated static func hash(of text: String) -> UInt64 { ReadLedger.hash(text) }

    /// Call before changing `path`. Only the first call per file per run records anything.
    public func willChange(run id: RunID, path: String, original: String?) {
        var index = runs.firstIndex { $0.id == id }
        if index == nil {
            runs.append(RunRecord(
                id: id, label: labels[id] ?? "", startedAt: Date(), changes: [], isReverted: false))
            index = runs.count - 1
        }
        guard let index, !runs[index].changes.contains(where: { $0.path == path }) else { return }
        runs[index].changes.append(FileChange(
            path: path, original: original, lastWrittenHash: original.map(ReadLedger.hash)))
        evictIfNeeded()
    }

    /// Call after a change, with the text now in the file.
    public func didChange(run id: RunID, path: String, written: String) {
        guard let index = runs.firstIndex(where: { $0.id == id }),
              let change = runs[index].changes.firstIndex(where: { $0.path == path })
        else { return }
        runs[index].changes[change].lastWrittenHash = ReadLedger.hash(written)
    }

    /// Restores a run's files, newest change first. A file whose text still matches the agent's last
    /// write goes back (a buffer in one undo group, a created file to the Trash); any other file is
    /// reported, never overwritten.
    public func revert(_ id: RunID, using workspace: any AgentWorkspace, ledger: ReadLedger? = nil) async -> RevertReport {
        guard let index = runs.firstIndex(where: { $0.id == id }), !runs[index].isReverted else { return RevertReport() }
        var report = RevertReport()

        for (position, change) in runs[index].changes.enumerated().reversed() {
            let current: String?
            do {
                current = try await workspace.readText(path: change.path)
            } catch AgentWorkspaceError.notFound {
                current = nil
            } catch {
                report.failures[change.path] = error.localizedDescription
                continue
            }

            if current == nil, change.isCreation {
                report.reverted.append(change.path)
                continue
            }
            guard let current, ReadLedger.hash(current) == change.lastWrittenHash else {
                report.conflicts.append(RevertConflict(path: change.path, original: change.original, current: current))
                continue
            }

            do {
                if let original = change.original {
                    if original != current {
                        let whole = AgentTextEdit(location: 0, length: (current as NSString).length, replacement: original)
                        try await workspace.replaceText(path: change.path, expecting: current, edits: [whole])
                    }
                    await ledger?.record(path: change.path, text: original)
                    // Now at its original text, so a retry after a partial revert sees it as done.
                    runs[index].changes[position].lastWrittenHash = ReadLedger.hash(original)
                } else {
                    try await workspace.trashFile(path: change.path)
                }
                report.reverted.append(change.path)
            } catch {
                report.failures[change.path] = error.localizedDescription
            }
        }
        if report.isComplete { runs[index].isReverted = true }
        return report
    }

    private func evictIfNeeded() {
        func size(_ run: RunRecord) -> Int { run.changes.reduce(0) { $0 + ($1.original?.utf8.count ?? 0) } }
        var total = runs.reduce(0) { $0 + size($1) }
        // The newest run always stays, so the current one can be reverted.
        while total > maxBytes, runs.count > 1 {
            total -= size(runs.removeFirst())
        }
    }
}

/// A run's checkpoint handle, given to tools that change files.
public struct CheckpointScope: Sendable {
    public let log: CheckpointLog
    public let run: RunID

    public init(log: CheckpointLog, run: RunID) {
        self.log = log
        self.run = run
    }

    public func willChange(path: String, original: String?) async {
        await log.willChange(run: run, path: path, original: original)
    }

    public func didChange(path: String, written: String) async {
        await log.didChange(run: run, path: path, written: written)
    }
}
