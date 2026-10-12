import Foundation
import GitIntelligence
import Observation

/// What every Umbra git model shares: the one runner (so each command reaches the Git console),
/// repository discovery, and turning an error or git's output into one line for the user.
enum IDEGitSupport {
    /// Every git child process Umbra starts goes through this runner. It reports to the console store.
    static let runner = SystemGitRunner(observer: IDEGitCommandObserver())

    /// The repository for `root`: `existing` when it still covers `root`, else a fresh discovery.
    /// Throws `GitError.notARepository` when `root` is not inside a work tree.
    nonisolated static func repository(
        for root: URL,
        existing: GitRepository?,
        network: GitNetworkEnvironment = IDEGitSupport.networkEnvironment
    ) async throws -> GitRepository {
        let standardized = root.standardizedFileURL
        if let existing {
            let repoRoot = existing.root.standardizedFileURL.path
            let path = standardized.path
            if path == repoRoot || path.hasPrefix(repoRoot + "/") {
                return existing
            }
        }
        guard let discovered = await GitRepository.discover(from: standardized, runner: runner, network: network) else {
            throw GitError.notARepository
        }
        return discovered
    }

    /// What network commands run with. Phase 1 swaps this for the askpass environment.
    nonisolated static var networkEnvironment: GitNetworkEnvironment { .batchMode }

    /// The first line of git's report, cut to 200 characters: what a status line or toast shows.
    nonisolated static func statusLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if line.count <= 200 { return line }
        return String(line.prefix(200))
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let git = error as? GitError, let message = git.errorDescription, !message.isEmpty {
            return message
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Git command failed." : message
    }

    /// `absolutePath` relative to `repositoryRoot`, "." for the root itself, nil outside it.
    nonisolated static func relativePath(for absolutePath: String, repositoryRoot: String) -> String? {
        guard absolutePath == repositoryRoot || absolutePath.hasPrefix(repositoryRoot + "/") else { return nil }
        if absolutePath == repositoryRoot { return "." }
        return String(absolutePath.dropFirst(repositoryRoot.count + 1))
    }
}

/// Receives every command the shared runner finishes (from a background thread) and hands the ones
/// worth showing to the main-actor store. A query that succeeded is dropped there: a status refresh
/// runs several and they would bury the commands the user started.
struct IDEGitCommandObserver: GitCommandObserving {
    func gitCommandFinished(_ record: GitCommandRecord) {
        if record.isReadOnly && record.succeeded { return }
        Task { @MainActor in IDEGitCommandStore.shared.append(record) }
    }
}

/// The Git console's data: the most recent commands of every window, newest last. Each window
/// reads its own repository's through `records(under:)`.
@MainActor
@Observable
final class IDEGitCommandStore {
    static let shared = IDEGitCommandStore()

    static let capacity = 500

    private(set) var records: [GitCommandRecord] = []

    func append(_ record: GitCommandRecord) {
        records.append(record)
        if records.count > Self.capacity {
            records.removeFirst(records.count - Self.capacity)
        }
    }

    /// The commands that ran in `root` or below it (a subdirectory command counts).
    func records(under root: String?) -> [GitCommandRecord] {
        guard let root else { return [] }
        return records.filter { record in
            let path = record.directory.standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }
    }

    func clear(under root: String?) {
        guard let root else { return }
        let doomed = Set(records(under: root).map(\.id))
        records.removeAll { doomed.contains($0.id) }
    }
}
