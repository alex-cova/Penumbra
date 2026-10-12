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
    /// The files the selected commit changed (all of them, also in a file's history).
    private(set) var selectedCommitFiles: [GitChangedFile] = []
    private(set) var branches: [String] = []
    private(set) var localBranches: [String] = []
    /// The current branch against its upstream; nil without one (a branch never pushed).
    private(set) var sync: GitSyncStatus?
    /// HEAD and the merge, rebase, cherry-pick or revert in progress, read from `.git` on every refresh.
    private(set) var repositoryState = GitRepositoryState(head: .unknown)
    private(set) var authors: [String] = []
    var historyBranch: String?
    var historyAuthor: String?
    /// Only commits newer than this (the Log's date menu); nil lists every date.
    var historySince: Date?
    /// Only commits touching this folder or file (relative to the root); empty for all.
    var historyPathFilter = ""
    /// How many commits the log asks for; "Load more" raises it.
    private(set) var historyLimit = 300
    /// Every selected commit in the Log (⌘/⇧-click); `selectedCommitHash` is the primary one.
    var selectedCommitHashes: Set<String> = []
    /// The branches that contain the selected commit.
    private(set) var commitBranches: [String] = []
    /// The history of selected lines of a file, shown in place of the log while it is set.
    var lineHistory: IDEGitLineHistory?
    /// The file whose history the History tab is showing (an absolute path), or nil for the whole repository.
    private(set) var historyFilePath: String?
    var historySearch = ""
    private(set) var isBusy = false
    /// The progress line of the fetch, pull or push that is running (nil when none is, or git has
    /// said nothing yet). The status bar and the Changes header show it.
    private(set) var networkProgress: GitProgress?
    /// True while a fetch, pull, push or clone runs. Only one runs at a time; local commands
    /// (stage, commit) still go through meanwhile.
    private(set) var isNetworkBusy = false
    /// Every local and remote-tracking branch with its upstream and ahead/behind, from the last refresh.
    private(set) var branchInfos: [GitBranch] = []
    private(set) var tags: [GitTag] = []
    private(set) var remoteInfos: [GitRemote] = []
    /// The result of the last Compare with Branch; nil until one runs.
    private(set) var comparison: GitComparison?
    /// Set once the repository's `commit.template` was offered, so it is not put back after a commit.
    @ObservationIgnored var templateOffered = false
    /// The stash, newest first, reloaded when refs change.
    var stashes: [GitStash] = []
    /// The stash the Stashes tab has selected (by commit, since indices shift), and its files.
    var selectedStashHash: String?
    var stashFiles: [GitStashChange] = []
    /// Sheets the git features present, one at a time, in the window's root view.
    let sheets = IDEGitSheetQueue()
    private(set) var actionStatus = ""
    /// Called with each git action's outcome line (`true` when it failed), so the host can post a
    /// notification.
    @ObservationIgnored var onActionReport: (@MainActor (_ message: String, _ isFailure: Bool) -> Void)?
    /// False when `actionStatus` is a successful git report rather than a failure.
    private(set) var actionFailed = false
    var commitMessage = ""
    /// Amend, sign-off and skip-hooks, kept between commits in this window.
    var commitOptions = IDEGitCommitOptions()
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
    /// Called when `compare(with:)` has a result, so the host can show the Compare tab.
    @ObservationIgnored var onShowComparison: (@MainActor () -> Void)?
    /// Asks the History panel to select its Stashes sub-tab.
    @ObservationIgnored var requestShowStashes: (@MainActor () -> Void)?

    private var repositoryRoot: String?

    @ObservationIgnored private(set) var rootURL: URL?
    @ObservationIgnored private(set) var repository: GitRepository?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var diffTask: Task<Void, Never>?
    @ObservationIgnored private var actionTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var commitDetailTask: Task<Void, Never>?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored var autoFetchTask: Task<Void, Never>?
    @ObservationIgnored private var busyCount = 0
    /// Names this window's credential prompts to the askpass server.
    @ObservationIgnored let askPassSession = UUID().uuidString
    /// Refs changed (or may have) since the log was loaded. A status refresh alone does not reload
    /// the log: a save or a stage cannot change it, and the log costs a `log --all` per reload.
    @ObservationIgnored private var historyStale = true
    /// New commits may have new authors; typing in the search box must not re-read them.
    @ObservationIgnored private var authorsStale = true

    init() {
        // Lives as long as the workspace (the app), so the observer is never removed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteRefsChanged()
                self?.refresh()
            }
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
        networkTask?.cancel()
        networkTask = nil
        autoFetchTask?.cancel()
        autoFetchTask = nil
        isNetworkBusy = false
        networkProgress = nil
        sheets.cancelAll()
        registerAskPass(active: url != nil)
        repository = nil
        commits = []
        selectedCommitHash = nil
        commitDetailText = nil
        selectedCommitFiles = []
        historyFilePath = nil
        needsAnotherPass = false
        historyStale = true
        authorsStale = true
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
        startAutoFetch()
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
            self.offerCommitTemplate()
            if self.historyStale {
                self.historyStale = false
                self.loadHistory()
                self.loadStashes()
            }
            self.onRefreshed?()
            if self.needsAnotherPass {
                self.needsAnotherPass = false
                self.refresh()
            }
        }
    }

    /// A branch, tag, HEAD or remote ref moved (the project watcher saw `.git/refs`, `packed-refs`,
    /// `HEAD`…): the next refresh reloads the log and the author list.
    func setHistoryLimit(_ value: Int) { historyLimit = value }
    func setTags(_ value: [GitTag]) { tags = value }
    func setRemotes(_ value: [GitRemote]) { remoteInfos = value }
    func setComparison(_ value: GitComparison?) { comparison = value }

    func noteRefsChanged() {
        historyStale = true
        authorsStale = true
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

    /// The blob of `relativePath` in `HEAD`. `found` is false when git could not be asked;
    /// `data` is nil when `HEAD` has no such file.
    func headContents(relativePath: String) async -> (found: Bool, data: Data?) {
        guard let rootURL else { return (false, nil) }
        return await Self.loadHead(root: rootURL, existing: repository, relativePath: relativePath)
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
        let includeAuthors = authorsStale || authors.isEmpty
        let since = historySince
        let limit = historyLimit
        let folder = historyPathFilter.trimmingCharacters(in: .whitespaces)
        let paths = folder.isEmpty ? [] : [folder]
        historyTask = Task { [weak self] in
            if debounced { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            let loaded = await Self.loadHistory(
                root: rootURL, existing: existing, branch: branch, author: author, search: search,
                filePath: filePath, includeAuthors: includeAuthors, since: since, paths: paths, limit: limit
            )
            guard let self, !Task.isCancelled, self.rootURL == rootURL else { return }
            // The file changed (or was cleared) while this loaded: its commits are for another list.
            guard self.historyFilePath.flatMap({ self.relativePath(for: $0) }) == filePath else { return }
            if loaded.repository != nil { self.repository = loaded.repository }
            let commits = Self.present(loaded.history)
            if loaded.history.branches != self.branches { self.branches = loaded.history.branches }
            if includeAuthors {
                self.authorsStale = false
                if loaded.history.authors != self.authors { self.authors = loaded.history.authors }
            }
            if commits != self.commits { self.commits = commits }
            if let selected = self.selectedCommitHash, !commits.contains(where: { $0.hash == selected }) {
                self.selectCommit(nil)
            }
        }
    }

    func selectCommit(_ hash: String?) {
        selectedCommitHash = hash
        selectedCommitHashes = hash.map { [$0] } ?? []
        commitBranches = []
        commitDetailTask?.cancel()
        guard let hash, let rootURL else {
            commitDetailText = nil
            selectedCommitFiles = []
            return
        }
        let existing = repository
        let filePath = historyFilePath.flatMap { relativePath(for: $0) }
        commitDetailTask = Task { [weak self] in
            let text = await Self.loadShow(root: rootURL, existing: existing, hash: hash, filePath: filePath)
            let files = await Self.loadCommitFiles(root: rootURL, existing: existing, hash: hash)
            guard let self, !Task.isCancelled, self.selectedCommitHash == hash else { return }
            self.commitDetailText = text
            self.selectedCommitFiles = files
            if let repo = try? await IDEGitSupport.repository(for: rootURL, existing: existing) {
                let branches = await repo.branchesContaining(hash)
                if self.selectedCommitHash == hash { self.commitBranches = branches }
            }
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

    /// Commit with the options in `commitOptions`, after the pre-commit checks.
    func commit() {
        requestCommit(options: commitOptions)
    }

    func switchBranch(_ name: String) {
        guard name != currentBranch else { return }
        guard !refuseUnsaved(before: "switching branches") else { return }
        switchToLocal(name)
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

    /// Pull (fast-forward only), then push what is left: the "Pull & Push" button of the sync section.
    func pullAndPush() {
        guard !refuseUnsaved(before: "pulling") else { return }
        runGitAction({
            _ = try await $0.pull()
            return try await $0.push()
        }) { [weak self] in
            self?.onWorkingTreeChanged?()
        }
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
        if snapshot.branchInfos != branchInfos { branchInfos = snapshot.branchInfos }
        if snapshot.changes != changes { changes = snapshot.changes }
        if snapshot.sync != sync { sync = snapshot.sync }
        if snapshot.state != repositoryState { repositoryState = snapshot.state }
    }

    func refuseUnsaved(before action: String) -> Bool {
        guard hasUnsavedEditors?() == true else { return false }
        fail("Save unsaved changes before \(action).")
        return true
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

    // MARK: - Diff viewer

    /// One side of a diff tab: a version git stores, or the file on disk (empty when it is gone).
    func diffContent(_ source: IDEDiffSource) async -> IDEDiffContent {
        switch source {
        case .text(let text):
            return .text(text)
        case .workingTree(let path):
            return await Task.detached(priority: .userInitiated) {
                guard let data = FileManager.default.contents(atPath: path) else { return IDEDiffContent.text("") }
                return Self.diffContent(of: data)
            }.value
        case .revision(let revision, let path):
            guard let rootURL else { return .failed("This folder is not a git repository.") }
            return await Self.loadRevision(root: rootURL, existing: repository, revision: revision, path: path)
        }
    }

    /// Stages one hunk (or, with `reverse`, unstages it) and refreshes. Returns git's complaint, or nil.
    func applyHunk(_ patch: String, reverse: Bool) async -> String? {
        guard let rootURL else { return "This folder is not a git repository." }
        do {
            let repo = try await IDEGitSupport.repository(for: rootURL, existing: repository)
            try await repo.applyPatch(patch, toIndex: true, reverse: reverse)
            refresh()
            return nil
        } catch {
            return IDEGitSupport.describe(error)
        }
    }

    /// `path` (absolute) relative to the repository root, or nil outside it.
    func repositoryRelativePath(for path: String) -> String? {
        relativePath(for: path)
    }

    nonisolated private static func loadCommitFiles(root: URL, existing: GitRepository?, hash: String) async -> [GitChangedFile] {
        guard let repo = try? await IDEGitSupport.repository(for: root, existing: existing) else { return [] }
        return (try? await repo.commitChanges(hash: hash)) ?? []
    }

    nonisolated private static func loadRevision(root: URL, existing: GitRepository?, revision: GitRevision, path: String) async -> IDEDiffContent {
        do {
            let repo = try await IDEGitSupport.repository(for: root, existing: existing)
            guard let data = try await repo.fileContents(at: revision, path: path) else { return .text("") }
            return diffContent(of: data)
        } catch {
            return .failed(IDEGitSupport.describe(error))
        }
    }

    /// Text, unless a NUL in the first 8 KB says it is binary (git's own test).
    nonisolated static func diffContent(of data: Data) -> IDEDiffContent {
        if data.prefix(8_000).contains(0) { return .binary }
        return .text(String(decoding: data, as: UTF8.self))
    }

    /// Runs `action` against the repository off the main actor and reports its one-line outcome.
    /// A `network` action (fetch, pull, push) runs with the askpass credential helper and reports
    /// progress; only one runs at a time, and it is not cancelled by a local command.
    func runGitAction(
        _ action: @escaping @Sendable (GitRepository) async throws -> String,
        network: Bool = false,
        credentials: Bool = false,
        onSuccess: (@MainActor () -> Void)? = nil,
        onFailure: (@MainActor (String) -> Void)? = nil
    ) {
        guard let rootURL else { return }
        if network {
            guard networkTask == nil else {
                fail("Another remote operation is still running.")
                return
            }
            isNetworkBusy = true
        } else {
            actionTask?.cancel()
        }
        busyCount += 1
        isBusy = true
        actionStatus = ""
        actionFailed = false
        let existing = repository
        let environment = (network || credentials) ? IDEGitAskPassServer.shared.environment(session: askPassSession) : nil
        var progress: GitProgressHandler?
        if network {
            progress = { [weak self] value in
                Task { @MainActor in self?.networkProgress = value }
            }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busyCount -= 1
                self.isBusy = self.busyCount > 0
                if network {
                    self.networkTask = nil
                    self.isNetworkBusy = false
                    self.networkProgress = nil
                }
            }
            do {
                let repo = try await IDEGitSupport.repository(for: rootURL, existing: existing)
                var configured = repo
                if let environment { configured = configured.withNetwork(environment) }
                if let progress { configured = configured.withProgress(progress) }
                let reported = try await action(configured)
                guard !Task.isCancelled else { return }
                self.repository = repo
                self.noteRefsChanged()
                let line = IDEGitSupport.statusLine(reported)
                if !line.isEmpty {
                    self.actionStatus = line
                    self.actionFailed = false
                    onActionReport?(line, false)
                }
                onSuccess?()
                self.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                // A rebase or merge that stopped on a conflict moved refs and left state behind.
                self.noteRefsChanged()
                self.refresh()
                self.actionStatus = IDEGitSupport.describe(error)
                self.actionFailed = true
                onActionReport?(self.actionStatus, true)
                onFailure?(self.actionStatus)
            }
        }
        if network { networkTask = task } else { actionTask = task }
    }

    /// What a successful commit leaves behind in the panel.
    func resetAfterCommit() {
        commitMessage = ""
        selectedChangePath = nil
        selectedChangePaths = []
        diffText = nil
        commitOptions.amend = false
        commitOptions.pushAfter = false
    }

    /// Reports a result the model decided itself (nothing to do, for instance) like an action's outcome.
    func succeed(_ message: String) {
        actionStatus = message
        actionFailed = false
        onActionReport?(message, false)
    }

    /// Puts `message` where a failed action's message goes, for refusals the model decides itself.
    func fail(_ message: String) {
        actionStatus = message
        actionFailed = true
        onActionReport?(message, true)
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
        var branchInfos: [GitBranch] = []
        var changes: [IDEGitChange] = []
        var sync: GitSyncStatus?
        var state = GitRepositoryState(head: .unknown)
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

    nonisolated private static func loadSnapshot(root: URL, existing: GitRepository?) async -> (repository: GitRepository?, snapshot: GitSnapshot) {
        guard let repo = try? await IDEGitSupport.repository(for: root, existing: existing),
              let entries = try? await repo.status(includingIgnored: true)
        else {
            return (nil, GitSnapshot())
        }
        let branch = await repo.currentBranch()
        var snapshot = parse(entries: entries, toplevel: repo.root.standardizedFileURL.path, branch: branch)
        let infos = (try? await repo.branchList()) ?? []
        snapshot.branchInfos = infos
        snapshot.localBranches = infos
            .compactMap { $0.kind == .local ? $0.name : nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        snapshot.sync = await repo.syncStatus()
        snapshot.state = repo.state()
        return (repo, snapshot)
    }

    nonisolated private static func loadHistory(
        root: URL,
        existing: GitRepository?,
        branch: String?,
        author: String?,
        search: String,
        filePath: String? = nil,
        includeAuthors: Bool = true,
        since: Date? = nil,
        paths: [String] = [],
        limit: Int = 300
    ) async -> (repository: GitRepository?, history: HistoryLoad) {
        guard let repo = try? await IDEGitSupport.repository(for: root, existing: existing) else {
            return (nil, HistoryLoad())
        }
        var history = HistoryLoad()
        let scope: GitLogScope = if let branch, !branch.isEmpty { .branch(branch) } else { .all }
        let grep = search.isEmpty ? nil : search
        if let commits = try? await repo.log(
            scope: scope, grep: grep, author: author, path: filePath, paths: paths, since: since, limit: limit
        ) {
            history.commits = commits
            // Filtered logs drop ancestors, so their lanes would dangle; show plain rows instead.
            if author == nil && search.isEmpty && filePath == nil && since == nil && paths.isEmpty {
                var layout = GitGraphLayout()
                history.graphs = layout.append(commits)
            }
        }
        if let refs = try? await repo.branches() {
            history.branches = refs.map(\.name)
        }
        if includeAuthors {
            history.authors = (try? await repo.authors()) ?? []
        }
        return (repo, history)
    }

    /// The commit, or with `filePath` just that file's change in it. A file's diff can be empty
    /// for a commit that changed it under an older name; the whole commit is shown then.
    nonisolated private static func loadBlame(root: URL, existing: GitRepository?, relativePath: String, contents: Data) async -> [GitBlameLine]? {
        guard let repo = try? await IDEGitSupport.repository(for: root, existing: existing) else { return nil }
        return try? await repo.blame(relativePath: relativePath, contents: contents)
    }

    nonisolated private static func loadHead(root: URL, existing: GitRepository?, relativePath: String) async -> (found: Bool, data: Data?) {
        guard let repo = try? await IDEGitSupport.repository(for: root, existing: existing) else { return (false, nil) }
        do {
            return (true, try await repo.fileContents(at: .head, path: relativePath))
        } catch {
            return (false, nil)
        }
    }

    nonisolated private static func loadShow(root: URL, existing: GitRepository?, hash: String, filePath: String?) async -> String {
        guard let repo = try? await IDEGitSupport.repository(for: root, existing: existing) else {
            return "Could not load commit."
        }
        if let filePath, let diff = try? await repo.commitDiff(hash: hash, path: filePath), !diff.isEmpty {
            return diff
        }
        return (try? await repo.show(hash: hash)) ?? "Could not load commit."
    }

    nonisolated private static func loadDiff(root: URL, existing: GitRepository?, path: String, change: IDEGitChange?) async -> String {
        guard let repo = try? await IDEGitSupport.repository(for: root, existing: existing) else {
            return "Could not resolve path for diff."
        }
        let toplevel = repo.root.standardizedFileURL.path
        guard let relative = IDEGitSupport.relativePath(for: path, repositoryRoot: toplevel) else {
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
            // `AA`, `DD`, `AU`, `UD`…: git's unmerged pairs, whatever letters they carry.
            let staged = entry.isConflicted ? IDEGitFileStatus.conflicted : statusFromIndexChar(entry.indexCode)
            let unstaged = entry.isConflicted ? IDEGitFileStatus.conflicted : statusFromWorkTreeChar(entry.worktreeCode)
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
