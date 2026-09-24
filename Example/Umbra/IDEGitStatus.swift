import AppKit
import Foundation
import GitIntelligence
import Observation

enum IDEGitFileStatus: Equatable {
    case modified
    case added
    case untracked
    case conflicted
    case ignored
}

struct IDEGitChange: Identifiable, Equatable, Sendable {
    let path: String
    let relativePath: String
    var staged: IDEGitFileStatus?
    var unstaged: IDEGitFileStatus?

    var id: String { path }
}

struct IDEGitCommit: Identifiable, Equatable, Sendable {
    var graph: GitGraphRow?
    let hash: String
    let shortHash: String
    let author: String
    let relativeDate: String
    let refs: String
    let parents: [String]
    let subject: String

    var id: String { hash }
}

/// `git status` for the open project, exposed to the Explorer as per-path statuses. Refreshed on
/// demand (saves, app activation) and by `IDEProjectWatcher` batches so commits/stages from the
/// terminal show up too. Silently empty when the folder is not a git repository or git is unavailable.
@MainActor
@Observable
final class IDEGitStatusModel {
    private(set) var statuses: [String: IDEGitFileStatus] = [:]
    private(set) var dirtyDirectories: Set<String> = []
    private(set) var currentBranch: String?
    private(set) var changes: [IDEGitChange] = []
    private(set) var diffText: String?
    private(set) var commits: [IDEGitCommit] = []
    private(set) var commitDetailText: String?
    private(set) var branches: [String] = []
    private(set) var authors: [String] = []
    var historyBranch: String?
    var historyAuthor: String?
    var historySearch = ""
    private(set) var isBusy = false
    private(set) var actionStatus = ""
    var commitMessage = ""
    var selectedChangePath: String?
    var selectedCommitHash: String?
    var isRepository: Bool { repositoryRoot != nil }

    private var repositoryRoot: String?

    @ObservationIgnored private var rootURL: URL?
    @ObservationIgnored private var repository: GitRepository?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var diffTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var commitDetailTask: Task<Void, Never>?

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
        diffTask?.cancel()
        diffTask = nil
        actionTask?.cancel()
        actionTask = nil
        historyTask?.cancel()
        historyTask = nil
        commitDetailTask?.cancel()
        commitDetailTask = nil
        repository = nil
        commits = []
        selectedCommitHash = nil
        commitDetailText = nil
        needsAnotherPass = false
        rootURL = url?.standardizedFileURL
        commitMessage = ""
        selectedChangePath = nil
        diffText = nil
        actionStatus = ""
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
        let existing = repository
        refreshTask = Task { [weak self] in
            let loaded = await Self.loadSnapshot(root: rootURL, existing: existing)
            guard let self, !Task.isCancelled, self.rootURL == rootURL else { return }
            self.repository = loaded.repository
            self.apply(loaded.snapshot)
            if let selected = self.selectedChangePath,
               !loaded.snapshot.changes.contains(where: { $0.path == selected }) {
                self.selectChange(nil)
            } else if let selected = self.selectedChangePath {
                self.loadDiff(for: selected)
            }
            self.refreshTask = nil
            self.loadHistory()
            if self.needsAnotherPass {
                self.needsAnotherPass = false
                self.refresh()
            }
        }
    }

    func loadHistory(debounced: Bool = false) {
        guard let rootURL else { return }
        historyTask?.cancel()
        let branch = historyBranch
        let author = historyAuthor
        let search = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = repository
        historyTask = Task { [weak self] in
            if debounced { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            let loaded = await Self.loadHistory(root: rootURL, existing: existing, branch: branch, author: author, search: search)
            guard let self, !Task.isCancelled, self.rootURL == rootURL else { return }
            if loaded.repository != nil { self.repository = loaded.repository }
            let commits = Self.present(loaded.history)
            if loaded.history.branches != self.branches { self.branches = loaded.history.branches }
            if loaded.history.authors != self.authors { self.authors = loaded.history.authors }
            if commits != self.commits { self.commits = commits }
            if let selected = self.selectedCommitHash, !commits.contains(where: { $0.hash == selected }) {
                self.selectCommit(nil)
            }
        }
    }

    func selectCommit(_ hash: String?) {
        selectedCommitHash = hash
        commitDetailTask?.cancel()
        guard let hash, let rootURL else {
            commitDetailText = nil
            return
        }
        let existing = repository
        commitDetailTask = Task { [weak self] in
            let text = await Self.loadShow(root: rootURL, existing: existing, hash: hash)
            guard let self, !Task.isCancelled, self.selectedCommitHash == hash else { return }
            self.commitDetailText = text
        }
    }

    func selectChange(_ path: String?) {
        selectedChangePath = path
        loadDiff(for: path)
    }

    func stage(path: String) {
        guard let relative = relativePath(for: path) else { return }
        runGitAction { try await $0.stage(paths: [relative]) }
    }

    func unstage(path: String) {
        guard let relative = relativePath(for: path) else { return }
        runGitAction { try await $0.unstage(paths: [relative]) }
    }

    func stageAll() {
        runGitAction { try await $0.stageAll() }
    }

    func unstageAll() {
        runGitAction { try await $0.unstageAll() }
    }

    func commit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            actionStatus = "Enter a commit message."
            return
        }
        guard changes.contains(where: { $0.staged != nil }) else {
            actionStatus = "Nothing staged to commit."
            return
        }
        runGitAction { _ = try await $0.commit(message: message, paths: [], untrackedPaths: [], amend: false) } onSuccess: { [weak self] in
            self?.commitMessage = ""
            self?.selectedChangePath = nil
            self?.diffText = nil
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
        if snapshot.repositoryRoot != repositoryRoot { repositoryRoot = snapshot.repositoryRoot }
        if snapshot.currentBranch != currentBranch { currentBranch = snapshot.currentBranch }
        if snapshot.changes != changes { changes = snapshot.changes }
    }

    private func loadDiff(for path: String?) {
        diffTask?.cancel()
        guard let path, let rootURL else {
            diffText = nil
            return
        }
        let change = changes.first(where: { $0.path == path })
        let existing = repository
        diffTask = Task { [weak self] in
            let text = await Self.loadDiff(root: rootURL, existing: existing, path: path, change: change)
            guard let self, !Task.isCancelled, self.selectedChangePath == path else { return }
            self.diffText = text
        }
    }

    private func runGitAction(
        _ action: @escaping @Sendable (GitRepository) async throws -> Void,
        onSuccess: (@MainActor () -> Void)? = nil
    ) {
        guard let rootURL else { return }
        actionTask?.cancel()
        isBusy = true
        actionStatus = ""
        let existing = repository
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                let repo = try await Self.repository(for: rootURL, existing: existing)
                try await action(repo)
                guard !Task.isCancelled else { return }
                self.repository = repo
                onSuccess?()
                self.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                self.actionStatus = Self.describe(error)
            }
        }
    }

    private func relativePath(for absolutePath: String) -> String? {
        guard let repositoryRoot else { return nil }
        guard absolutePath == repositoryRoot || absolutePath.hasPrefix(repositoryRoot + "/") else { return nil }
        if absolutePath == repositoryRoot { return "." }
        return String(absolutePath.dropFirst(repositoryRoot.count + 1))
    }

    // MARK: - Loading

    struct GitSnapshot: Sendable {
        var statuses: [String: IDEGitFileStatus] = [:]
        var dirtyDirectories: Set<String> = []
        var repositoryRoot: String?
        var currentBranch: String?
        var changes: [IDEGitChange] = []
    }

    struct HistoryLoad: Sendable {
        var commits: [GitCommit] = []
        var graphs: [GitGraphRow] = []
        var branches: [String] = []
        var authors: [String] = []
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static func present(_ history: HistoryLoad) -> [IDEGitCommit] {
        history.commits.enumerated().map { index, commit in
            IDEGitCommit(
                graph: history.graphs.indices.contains(index) ? history.graphs[index] : nil,
                hash: commit.hash,
                shortHash: commit.shortHash,
                author: commit.author,
                relativeDate: relativeFormatter.localizedString(for: commit.date, relativeTo: Date()),
                refs: commit.refs.map(\.name).filter { $0 != "HEAD" }.joined(separator: ", "),
                parents: commit.parents,
                subject: commit.subject
            )
        }
    }

    nonisolated private static func repository(for root: URL, existing: GitRepository?) async throws -> GitRepository {
        let standardized = root.standardizedFileURL
        if let existing {
            let repoRoot = existing.root.standardizedFileURL.path
            let path = standardized.path
            if path == repoRoot || path.hasPrefix(repoRoot + "/") {
                return existing
            }
        }
        guard let discovered = await GitRepository.discover(from: standardized) else {
            throw GitError.notARepository
        }
        return discovered
    }

    nonisolated private static func loadSnapshot(root: URL, existing: GitRepository?) async -> (repository: GitRepository?, snapshot: GitSnapshot) {
        guard let repo = try? await repository(for: root, existing: existing),
              let entries = try? await repo.status(includingIgnored: true)
        else {
            return (nil, GitSnapshot())
        }
        let branch = await repo.currentBranch()
        return (repo, parse(entries: entries, toplevel: repo.root.standardizedFileURL.path, branch: branch))
    }

    nonisolated private static func loadHistory(
        root: URL,
        existing: GitRepository?,
        branch: String?,
        author: String?,
        search: String
    ) async -> (repository: GitRepository?, history: HistoryLoad) {
        guard let repo = try? await repository(for: root, existing: existing) else {
            return (nil, HistoryLoad())
        }
        var history = HistoryLoad()
        let scope: GitLogScope = if let branch, !branch.isEmpty { .branch(branch) } else { .all }
        let grep = search.isEmpty ? nil : search
        if let commits = try? await repo.log(scope: scope, grep: grep, author: author, limit: 300) {
            history.commits = commits
            // Filtered logs drop ancestors, so their lanes would dangle; show plain rows instead.
            if author == nil && search.isEmpty {
                var layout = GitGraphLayout()
                history.graphs = layout.append(commits)
            }
        }
        if let refs = try? await repo.branches() {
            history.branches = refs.map(\.name)
        }
        history.authors = (try? await repo.authors()) ?? []
        return (repo, history)
    }

    nonisolated private static func loadShow(root: URL, existing: GitRepository?, hash: String) async -> String {
        guard let repo = try? await repository(for: root, existing: existing) else {
            return "Could not load commit."
        }
        return (try? await repo.show(hash: hash)) ?? "Could not load commit."
    }

    nonisolated private static func loadDiff(root: URL, existing: GitRepository?, path: String, change: IDEGitChange?) async -> String {
        guard let repo = try? await repository(for: root, existing: existing) else {
            return "Could not resolve path for diff."
        }
        let toplevel = repo.root.standardizedFileURL.path
        guard let relative = relativePath(for: path, repositoryRoot: toplevel) else {
            return "Could not resolve path for diff."
        }
        var sections: [String] = []
        if change?.unstaged != nil, let diff = try? await repo.unstagedDiff(path: relative), !diff.isEmpty {
            sections.append("--- Unstaged changes ---\n\(diff)")
        }
        if change?.staged != nil, let diff = try? await repo.stagedDiff(path: relative), !diff.isEmpty {
            sections.append("--- Staged changes ---\n\(diff)")
        }
        if sections.isEmpty {
            return "No diff available."
        }
        return sections.joined(separator: "\n\n")
    }

    nonisolated private static func relativePath(for absolutePath: String, repositoryRoot: String) -> String? {
        guard absolutePath == repositoryRoot || absolutePath.hasPrefix(repositoryRoot + "/") else { return nil }
        if absolutePath == repositoryRoot { return "." }
        return String(absolutePath.dropFirst(repositoryRoot.count + 1))
    }

    nonisolated private static func describe(_ error: Error) -> String {
        if let git = error as? GitError, let message = git.errorDescription, !message.isEmpty {
            return message
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Git command failed." : message
    }

    nonisolated static func parse(entries: [GitStatusEntry], toplevel: String, branch: String?) -> GitSnapshot {
        var snapshot = GitSnapshot(repositoryRoot: toplevel, currentBranch: branch)
        var changeMap: [String: IDEGitChange] = [:]
        for entry in entries {
            var relative = entry.path
            if relative.hasSuffix("/") { relative.removeLast() }
            let path = (toplevel as NSString).appendingPathComponent(relative)
            if entry.isIgnored {
                snapshot.statuses[path] = .ignored
                continue
            }
            let staged = statusFromIndexChar(entry.indexCode)
            let unstaged = statusFromWorkTreeChar(entry.worktreeCode)
            let combined = combinedStatus(staged: staged, unstaged: unstaged)
            if let combined {
                snapshot.statuses[path] = combined
                if combined != .ignored {
                    markDirty(path: path, toplevel: toplevel, snapshot: &snapshot)
                    if staged != nil || unstaged != nil {
                        changeMap[path] = IDEGitChange(
                            path: path,
                            relativePath: relative,
                            staged: staged,
                            unstaged: unstaged
                        )
                    }
                }
            }
        }
        snapshot.changes = changeMap.values.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return snapshot
    }

    nonisolated private static func statusFromIndexChar(_ char: Character) -> IDEGitFileStatus? {
        switch char {
        case " ": return nil
        case "A": return .added
        case "U": return .conflicted
        case "M", "D", "R", "C": return .modified
        default: return .modified
        }
    }

    nonisolated private static func statusFromWorkTreeChar(_ char: Character) -> IDEGitFileStatus? {
        switch char {
        case " ": return nil
        case "?": return .untracked
        case "!": return .ignored
        case "A": return .added
        case "U": return .conflicted
        case "M", "D", "R", "C": return .modified
        default: return .modified
        }
    }

    nonisolated private static func combinedStatus(staged: IDEGitFileStatus?, unstaged: IDEGitFileStatus?) -> IDEGitFileStatus? {
        if unstaged == .ignored || staged == .ignored { return .ignored }
        if unstaged == .conflicted || staged == .conflicted { return .conflicted }
        if unstaged == .untracked { return .untracked }
        if staged == .added || unstaged == .added { return .added }
        if staged != nil || unstaged != nil { return .modified }
        return nil
    }

    nonisolated private static func markDirty(path: String, toplevel: String, snapshot: inout GitSnapshot) {
        var ancestor = (path as NSString).deletingLastPathComponent
        while ancestor.count > toplevel.count, ancestor.hasPrefix(toplevel) {
            snapshot.dirtyDirectories.insert(ancestor)
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        snapshot.dirtyDirectories.insert(toplevel)
    }
}
