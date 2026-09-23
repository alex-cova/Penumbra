import AppKit
import Foundation
import JavaIntelligence
import Observation

enum IDEGitFileStatus: Equatable {
    case modified
    case added
    case untracked
    case conflicted
    case ignored
}

/// `git status` for the open project, exposed to the Explorer as per-path statuses. Refreshed on
/// demand (saves, app activation) and by `IDEProjectWatcher` batches so commits/stages from the
/// terminal show up too. Silently empty when the folder is not a git repository or git is unavailable.
@MainActor
@Observable
final class IDEGitStatusModel {
    private(set) var statuses: [String: IDEGitFileStatus] = [:]
    private(set) var dirtyDirectories: Set<String> = []
    private var repositoryRoot: String?

    @ObservationIgnored private var rootURL: URL?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherPass = false

    init() {
        // Lives as long as the workspace (the app), so the observer is never removed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func setRoot(_ url: URL?) {
        refreshTask?.cancel()
        refreshTask = nil
        needsAnotherPass = false
        rootURL = url?.standardizedFileURL
        apply(GitSnapshot())
        guard rootURL != nil else { return }
        refresh()
    }

    func refresh() {
        guard let rootURL else { return }
        if refreshTask != nil {
            needsAnotherPass = true
            return
        }
        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) { Self.loadSnapshot(root: rootURL) }.value
            guard let self, !Task.isCancelled, self.rootURL == rootURL else { return }
            self.apply(snapshot)
            self.refreshTask = nil
            if self.needsAnotherPass {
                self.needsAnotherPass = false
                self.refresh()
            }
        }
    }

    /// Exact hit first; otherwise an ignored/untracked ancestor directory covers everything below
    /// it (git reports those collapsed as `dir/`); otherwise a folder holding changes reads as modified.
    func status(for url: URL, isDirectory: Bool) -> IDEGitFileStatus? {
        guard !statuses.isEmpty || !dirtyDirectories.isEmpty else { return nil }
        let path = url.standardizedFileURL.path
        if let exact = statuses[path] { return exact }
        if let repositoryRoot {
            var ancestor = (path as NSString).deletingLastPathComponent
            while ancestor.count > repositoryRoot.count, ancestor.hasPrefix(repositoryRoot) {
                if let status = statuses[ancestor], status == .ignored || status == .untracked {
                    return status
                }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
        }
        if isDirectory, dirtyDirectories.contains(path) { return .modified }
        return nil
    }

    private func apply(_ snapshot: GitSnapshot) {
        if snapshot.statuses != statuses { statuses = snapshot.statuses }
        if snapshot.dirtyDirectories != dirtyDirectories { dirtyDirectories = snapshot.dirtyDirectories }
        repositoryRoot = snapshot.repositoryRoot
    }

    // MARK: - Loading

    struct GitSnapshot: Sendable {
        var statuses: [String: IDEGitFileStatus] = [:]
        var dirtyDirectories: Set<String> = []
        var repositoryRoot: String?
    }

    nonisolated private static func loadSnapshot(root: URL) -> GitSnapshot {
        let runner = SystemProcessRunner()
        let git = "/usr/bin/git"
        guard
            let top = try? runner.run(
                executable: git,
                arguments: ["-C", root.path, "rev-parse", "--show-toplevel"],
                currentDirectory: nil,
                environment: nil
            ),
            let output = try? runner.run(
                executable: git,
                arguments: ["--no-optional-locks", "-C", root.path, "status", "--porcelain=v1", "-z", "--ignored", "--untracked-files=normal"],
                currentDirectory: nil,
                environment: nil
            )
        else {
            return GitSnapshot()
        }
        let toplevel = URL(fileURLWithPath: top.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path
        return parse(porcelain: output, toplevel: toplevel)
    }

    nonisolated static func parse(porcelain: String, toplevel: String) -> GitSnapshot {
        var snapshot = GitSnapshot(repositoryRoot: toplevel)
        let records = porcelain.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard record.count > 3 else { continue }
            let code = record.prefix(2)
            var relative = String(record.dropFirst(3))
            if code.contains("R") || code.contains("C") { index += 1 }  // the origin path follows
            if relative.hasSuffix("/") { relative.removeLast() }
            let path = (toplevel as NSString).appendingPathComponent(relative)

            let status: IDEGitFileStatus
            switch code {
            case "!!": status = .ignored
            case "??": status = .untracked
            case "AA", "DD": status = .conflicted
            default:
                if code.contains("U") {
                    status = .conflicted
                } else if code.first == "A" {
                    status = .added
                } else {
                    status = .modified
                }
            }
            snapshot.statuses[path] = status
            guard status != .ignored else { continue }
            var ancestor = (path as NSString).deletingLastPathComponent
            while ancestor.count > toplevel.count, ancestor.hasPrefix(toplevel) {
                snapshot.dirtyDirectories.insert(ancestor)
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            snapshot.dirtyDirectories.insert(toplevel)
        }
        return snapshot
    }
}
