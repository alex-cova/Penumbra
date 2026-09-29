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

/// Hands the paths a background revert changed back to the main actor.
private nonisolated final class RevertOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    var value: Set<String> { lock.withLock { paths } }
    func set(_ newValue: Set<String>) { lock.withLock { paths = newValue } }
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
    private(set) var localBranches: [String] = []
    private(set) var authors: [String] = []
    var historyBranch: String?
    var historyAuthor: String?
    /// The file whose history the History tab is showing (an absolute path), or nil for the whole repository.
    private(set) var historyFilePath: String?
    var historySearch = ""
    private(set) var isBusy = false
    private(set) var actionStatus = ""
    /// False when `actionStatus` is a successful git report rather than a failure.
    private(set) var actionFailed = false
    var commitMessage = ""
    /// The row that drives the diff. It is always a member of `selectedChangePaths` when set.
    var selectedChangePath: String?
    /// Every selected row, for actions that take several files (Revert…).
    private(set) var selectedChangePaths: Set<String> = []
    var selectedCommitHash: String?
    var isRepository: Bool { repositoryRoot != nil }
    var repositoryRootPath: String? { repositoryRoot }

    /// True when an open editor inside the repository still has unsaved edits. Switch and pull refuse then.
    @ObservationIgnored var hasUnsavedEditors: (@MainActor () -> Bool)?
    /// Reloads clean editor buffers after a switch or pull has changed files on disk.
    @ObservationIgnored var onWorkingTreeChanged: (@MainActor () -> Void)?
    /// Called after every status refresh has been applied (saves, app activation, watcher batches).
    @ObservationIgnored var onRefreshed: (@MainActor () -> Void)?

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
        historyFilePath = nil
        needsAnotherPass = false
        rootURL = url?.standardizedFileURL
        commitMessage = ""
        selectedChangePath = nil
        selectedChangePaths = []
        diffText = nil
        actionStatus = ""
        actionFailed = false
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
            let remaining = Set(loaded.snapshot.changes.map(\.path))
            self.selectedChangePaths.formIntersection(remaining)
            if let selected = self.selectedChangePath, !remaining.contains(selected) {
                self.selectChange(self.selectedChangePaths.sorted().first)
            } else if let selected = self.selectedChangePath {
                self.loadDiff(for: selected)
            }
            self.refreshTask = nil
            self.loadHistory()
            self.onRefreshed?()
            if self.needsAnotherPass {
                self.needsAnotherPass = false
                self.refresh()
            }
        }
    }

    /// Narrows the History tab to the commits that touched `path` (following renames).
    func showFileHistory(path: String) {
        guard relativePath(for: path) != nil else { return }
        historyFilePath = path
        selectCommit(nil)
        commits = []
        loadHistory()
    }

    /// `git blame` of the file at `path` (absolute) against `contents`, the editor's live text, so
    /// unsaved edits come back as uncommitted lines. Nil when the file is outside the repository or
    /// git has no blame for it (untracked, or a repository without commits).
    func blame(path: String, contents: Data) async -> [GitBlameLine]? {
        guard let rootURL, let relative = relativePath(for: path) else { return nil }
        return await Self.loadBlame(root: rootURL, existing: repository, relativePath: relative, contents: contents)
    }

    /// Back to the history of the whole repository.
    func clearFileHistory() {
        guard historyFilePath != nil else { return }
        historyFilePath = nil
        selectCommit(nil)
        commits = []
        loadHistory()
    }

    func loadHistory(debounced: Bool = false) {
        guard let rootURL else { return }
        historyTask?.cancel()
        let branch = historyBranch
        let author = historyAuthor
        let search = historySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let filePath = historyFilePath.flatMap { relativePath(for: $0) }
        let existing = repository
        historyTask = Task { [weak self] in
            if debounced { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            let loaded = await Self.loadHistory(root: rootURL, existing: existing, branch: branch, author: author, search: search, filePath: filePath)
            guard let self, !Task.isCancelled, self.rootURL == rootURL else { return }
            // The file changed (or was cleared) while this loaded: its commits are for another list.
            guard self.historyFilePath.flatMap({ self.relativePath(for: $0) }) == filePath else { return }
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
        let filePath = historyFilePath.flatMap { relativePath(for: $0) }
        commitDetailTask = Task { [weak self] in
            let text = await Self.loadShow(root: rootURL, existing: existing, hash: hash, filePath: filePath)
            guard let self, !Task.isCancelled, self.selectedCommitHash == hash else { return }
            self.commitDetailText = text
        }
    }

    func selectChange(_ path: String?) {
        selectedChangePath = path
        selectedChangePaths = path.map { [$0] } ?? []
        loadDiff(for: path)
    }

    /// ⌘-click: adds or removes one row, keeping the others.
    func toggleChangeSelection(_ path: String) {
        if selectedChangePaths.remove(path) != nil {
            if selectedChangePath == path {
                selectedChangePath = selectedChangePaths.sorted().first
                loadDiff(for: selectedChangePath)
            }
        } else {
            selectedChangePaths.insert(path)
            selectedChangePath = path
            loadDiff(for: path)
        }
    }

    /// ⇧-click: selects the rows of `visible` (a list in display order) from the primary row to `path`.
    func extendChangeSelection(to path: String, in visible: [String]) {
        guard let anchor = selectedChangePath, let from = visible.firstIndex(of: anchor),
              let to = visible.firstIndex(of: path) else {
            selectChange(path)
            return
        }
        selectedChangePaths.formUnion(visible[min(from, to)...max(from, to)])
        selectedChangePath = path
        loadDiff(for: path)
    }

    func stage(path: String) {
        guard let relative = relativePath(for: path) else { return }
        runGitAction { try await $0.stage(paths: [relative]); return "" }
    }

    func unstage(path: String) {
        guard let relative = relativePath(for: path) else { return }
        runGitAction { try await $0.unstage(paths: [relative]); return "" }
    }

    func stageAll() {
        runGitAction { try await $0.stageAll(); return "" }
    }

    func unstageAll() {
        runGitAction { try await $0.unstageAll(); return "" }
    }

    func commit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            fail("Enter a commit message.")
            return
        }
        guard changes.contains(where: { $0.staged != nil }) else {
            fail("Nothing staged to commit.")
            return
        }
        runGitAction { _ = try await $0.commit(message: message, paths: [], untrackedPaths: [], amend: false); return "" } onSuccess: { [weak self] in
            self?.commitMessage = ""
            self?.selectedChangePath = nil
            self?.selectedChangePaths = []
            self?.diffText = nil
        }
    }

    func switchBranch(_ name: String) {
        guard name != currentBranch else { return }
        guard !refuseUnsaved(before: "switching branches") else { return }
        runGitAction({ try await $0.switchBranch(name) }) { [weak self] in
            self?.onWorkingTreeChanged?()
        }
    }

    func createBranch(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail("Enter a branch name.")
            return
        }
        runGitAction { try await $0.createBranch(trimmed) }
    }

    /// Puts `paths` (absolute) back to their last committed content, discarding staged and unstaged
    /// changes. Files with no committed version (untracked, or staged as new) are left alone and
    /// reported as skipped. `then` receives the absolute paths that were reverted, to reload the
    /// editors that show them; nothing is reverted, and `onFailure` runs, when none qualifies.
    func revert(
        paths: [String],
        then: (@MainActor (Set<String>) -> Void)? = nil,
        onFailure: (@MainActor (String) -> Void)? = nil
    ) {
        let requested = paths.compactMap { path in relativePath(for: path).map { (path, $0) } }
        guard !requested.isEmpty else { return }
        let absoluteByRelative = Dictionary(requested.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let outcome = RevertOutcome()
        runGitAction({ repo in
            let result = try await repo.revert(paths: requested.map(\.1))
            outcome.set(Set(result.reverted.compactMap { absoluteByRelative[$0] }))
            if result.reverted.isEmpty {
                let what = result.skipped.count == 1 ? "\(result.skipped[0]) is not" : "None of the \(result.skipped.count) files are"
                throw GitError.failed(status: 1, stderr: "\(what) in the last commit, so there is nothing to revert to.", stdout: Data())
            }
            var line = result.reverted.count == 1 ? "Reverted \(result.reverted[0])" : "Reverted \(result.reverted.count) files"
            if !result.skipped.isEmpty {
                line += "; skipped \(result.skipped.count) not in the last commit"
            }
            return line
        }, onSuccess: { then?(outcome.value) }, onFailure: onFailure)
    }

    func revert(path: String, then: (@MainActor () -> Void)? = nil, onFailure: (@MainActor (String) -> Void)? = nil) {
        revert(paths: [path], then: { _ in then?() }, onFailure: onFailure)
    }

    func push() {
        runGitAction { try await $0.push() }
    }

    func pull() {
        guard !refuseUnsaved(before: "pulling") else { return }
        runGitAction({ try await $0.pull() }) { [weak self] in
            self?.onWorkingTreeChanged?()
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
        if snapshot.localBranches != localBranches { localBranches = snapshot.localBranches }
        if snapshot.changes != changes { changes = snapshot.changes }
    }

    private func refuseUnsaved(before action: String) -> Bool {
        guard hasUnsavedEditors?() == true else { return false }
        fail("Save unsaved changes before \(action).")
        return true
    }

    private func fail(_ message: String) {
        actionStatus = message
        actionFailed = true
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
        _ action: @escaping @Sendable (GitRepository) async throws -> String,
        onSuccess: (@MainActor () -> Void)? = nil,
        onFailure: (@MainActor (String) -> Void)? = nil
    ) {
        guard let rootURL else { return }
        actionTask?.cancel()
        isBusy = true
        actionStatus = ""
        actionFailed = false
        let existing = repository
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                let repo = try await Self.repository(for: rootURL, existing: existing)
                let reported = try await action(repo)
                guard !Task.isCancelled else { return }
                self.repository = repo
                let line = Self.statusLine(reported)
                if !line.isEmpty {
                    self.actionStatus = line
                    self.actionFailed = false
                }
                onSuccess?()
                self.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                self.actionStatus = Self.describe(error)
                self.actionFailed = true
                onFailure?(self.actionStatus)
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
        var localBranches: [String] = []
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
        var snapshot = parse(entries: entries, toplevel: repo.root.standardizedFileURL.path, branch: branch)
        snapshot.localBranches = ((try? await repo.branches()) ?? [])
            .compactMap { $0.kind == .localBranch ? $0.name : nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (repo, snapshot)
    }

    nonisolated private static func loadHistory(
        root: URL,
        existing: GitRepository?,
        branch: String?,
        author: String?,
        search: String,
        filePath: String? = nil
    ) async -> (repository: GitRepository?, history: HistoryLoad) {
        guard let repo = try? await repository(for: root, existing: existing) else {
            return (nil, HistoryLoad())
        }
        var history = HistoryLoad()
        let scope: GitLogScope = if let branch, !branch.isEmpty { .branch(branch) } else { .all }
        let grep = search.isEmpty ? nil : search
        if let commits = try? await repo.log(scope: scope, grep: grep, author: author, path: filePath, limit: 300) {
            history.commits = commits
            // Filtered logs drop ancestors, so their lanes would dangle; show plain rows instead.
            if author == nil && search.isEmpty && filePath == nil {
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

    /// The commit, or with `filePath` just that file's change in it. A file's diff can be empty
    /// for a commit that changed it under an older name; the whole commit is shown then.
    nonisolated private static func loadBlame(root: URL, existing: GitRepository?, relativePath: String, contents: Data) async -> [GitBlameLine]? {
        guard let repo = try? await repository(for: root, existing: existing) else { return nil }
        return try? await repo.blame(relativePath: relativePath, contents: contents)
    }

    nonisolated private static func loadShow(root: URL, existing: GitRepository?, hash: String, filePath: String?) async -> String {
        guard let repo = try? await repository(for: root, existing: existing) else {
            return "Could not load commit."
        }
        if let filePath, let diff = try? await repo.commitDiff(hash: hash, path: filePath), !diff.isEmpty {
            return diff
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

    nonisolated private static func statusLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if line.count <= 200 { return line }
        return String(line.prefix(200))
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
