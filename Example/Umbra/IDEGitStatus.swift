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

struct IDEGitChange: Identifiable, Equatable, Sendable {
    let path: String
    let relativePath: String
    var staged: IDEGitFileStatus?
    var unstaged: IDEGitFileStatus?

    var id: String { path }
}

/// One row of the commit graph: which lanes run through it and how the commit's dot connects to
/// the rows above and below.
struct IDEGitGraphRow: Equatable, Sendable {
    var column = 0
    var laneCount = 1
    /// Lanes drawn as a full-height vertical line (not touching this commit).
    var through: [Int] = []
    var hasTop = false
    var hasBottom = false
    /// Lanes that converge onto this commit from the row above.
    var mergesFromTop: [Int] = []
    /// Lanes this commit's extra/moved parents leave toward in the row below.
    var branchesToBottom: [Int] = []
}

struct IDEGitCommit: Identifiable, Equatable, Sendable {
    var graph: IDEGitGraphRow?
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
        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) { Self.loadSnapshot(root: rootURL) }.value
            guard let self, !Task.isCancelled, self.rootURL == rootURL else { return }
            self.apply(snapshot)
            if let selected = self.selectedChangePath,
               !snapshot.changes.contains(where: { $0.path == selected }) {
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
        historyTask = Task { [weak self] in
            if debounced { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) {
                Self.loadHistory(root: rootURL, branch: branch, author: author, search: search)
            }.value
            guard let self, !Task.isCancelled, self.rootURL == rootURL else { return }
            let commits = result.commits
            if result.branches != self.branches { self.branches = result.branches }
            if result.authors != self.authors { self.authors = result.authors }
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
        commitDetailTask = Task { [weak self] in
            let text = await Task.detached(priority: .utility) {
                (try? Self.runGit(root: rootURL, arguments: ["show", "--no-color", "--stat", "--patch", hash]))
                    ?? "Could not load commit."
            }.value
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
        runGitAction(["add", "--", relative])
    }

    func unstage(path: String) {
        guard let relative = relativePath(for: path) else { return }
        runGitAction(["restore", "--staged", "--", relative])
    }

    func stageAll() {
        runGitAction(["add", "-A"])
    }

    func unstageAll() {
        runGitAction(["restore", "--staged", "."])
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
        runGitAction(["commit", "-m", message]) { [weak self] in
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
        diffTask = Task { [weak self] in
            let text = await Task.detached(priority: .utility) {
                Self.loadDiff(root: rootURL, path: path, change: change)
            }.value
            guard let self, !Task.isCancelled, self.selectedChangePath == path else { return }
            self.diffText = text
        }
    }

    private func runGitAction(_ arguments: [String], onSuccess: (() -> Void)? = nil) {
        guard let rootURL else { return }
        actionTask?.cancel()
        isBusy = true
        actionStatus = ""
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                _ = try await Task.detached(priority: .utility) {
                    try Self.runGit(root: rootURL, arguments: arguments)
                }.value
                guard !Task.isCancelled else { return }
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
        var snapshot = parse(porcelain: output, toplevel: toplevel)
        snapshot.currentBranch = loadCurrentBranch(root: root, runner: runner, git: git)
        return snapshot
    }

    nonisolated private static func loadHistory(
        root: URL,
        branch: String?,
        author: String?,
        search: String
    ) -> (commits: [IDEGitCommit], branches: [String], authors: [String]) {
        let format = "%H%x1f%h%x1f%an%x1f%ar%x1f%D%x1f%P%x1f%s%x1e"
        var arguments = ["--no-optional-locks", "log", "-n", "300", "--no-color", "--topo-order", "--fixed-strings", "-i"]
        arguments.append("--pretty=format:\(format)")
        if let author { arguments.append("--author=\(author)") }
        if !search.isEmpty { arguments.append("--grep=\(search)") }
        arguments.append(branch ?? "--all")
        var commits: [IDEGitCommit] = []
        if let output = try? runGit(root: root, arguments: arguments) {
            commits = output.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { record in
                let fields = record.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\u{1f}", maxSplits: 6, omittingEmptySubsequences: false)
                    .map(String.init)
                guard fields.count == 7 else { return nil }
                return IDEGitCommit(
                    graph: nil,
                    hash: fields[0],
                    shortHash: fields[1],
                    author: fields[2],
                    relativeDate: fields[3],
                    refs: fields[4],
                    parents: fields[5].split(separator: " ").map(String.init),
                    subject: fields[6]
                )
            }
        }
        // Filtered logs drop ancestors, so their lanes would dangle; show plain rows instead.
        if author == nil && search.isEmpty { assignGraph(&commits) }

        let branchOutput = (try? runGit(
            root: root,
            arguments: ["--no-optional-locks", "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"]
        )) ?? ""
        let branches = branchOutput.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
        let authorOutput = (try? runGit(
            root: root,
            arguments: ["--no-optional-locks", "log", "--all", "-n", "5000", "--format=%an"]
        )) ?? ""
        var seen = Set<String>()
        let authors = authorOutput.split(separator: "\n").map(String.init).filter { seen.insert($0).inserted }.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return (commits, branches, authors)
    }

    nonisolated private static func assignGraph(_ commits: inout [IDEGitCommit]) {
        var lanes: [String?] = []
        for index in commits.indices {
            let commit = commits[index]
            var row = IDEGitGraphRow()
            let matching = lanes.indices.filter { lanes[$0] == commit.hash }
            let column: Int
            if let first = matching.first {
                column = first
                row.hasTop = true
                row.mergesFromTop = Array(matching.dropFirst())
                for extra in matching.dropFirst() { lanes[extra] = nil }
            } else if let free = lanes.firstIndex(where: { $0 == nil }) {
                column = free
            } else {
                column = lanes.count
                lanes.append(nil)
            }
            row.column = column
            row.through = lanes.indices.filter { $0 != column && lanes[$0] != nil && !matching.contains($0) }
            let widthBefore = lanes.count

            if let first = commit.parents.first {
                row.hasBottom = true
                if let other = lanes.indices.first(where: { $0 != column && lanes[$0] == first }) {
                    lanes[column] = nil
                    row.branchesToBottom.append(other)
                } else {
                    lanes[column] = first
                }
                for parent in commit.parents.dropFirst() {
                    if let existing = lanes.firstIndex(where: { $0 == parent }) {
                        row.branchesToBottom.append(existing)
                    } else {
                        let slot = lanes.firstIndex(where: { $0 == nil }) ?? lanes.count
                        if slot == lanes.count { lanes.append(parent) } else { lanes[slot] = parent }
                        row.branchesToBottom.append(slot)
                    }
                }
            } else {
                lanes[column] = nil
            }
            row.laneCount = max(widthBefore, lanes.count, column + 1)
            while let last = lanes.last, last == nil { lanes.removeLast() }
            commits[index].graph = row
        }
    }

    nonisolated private static func loadCurrentBranch(root: URL, runner: SystemProcessRunner, git: String) -> String? {
        if let branchOutput = try? runner.run(
            executable: git,
            arguments: ["-C", root.path, "branch", "--show-current"],
            currentDirectory: nil,
            environment: nil
        ) {
            let branch = branchOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !branch.isEmpty { return branch }
        }
        guard
            let shaOutput = try? runner.run(
                executable: git,
                arguments: ["-C", root.path, "rev-parse", "--short", "HEAD"],
                currentDirectory: nil,
                environment: nil
            )
        else { return nil }
        let sha = shaOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    nonisolated private static func loadDiff(root: URL, path: String, change: IDEGitChange?) -> String {
        guard let relative = relativePath(for: path, repositoryRoot: root.path) else {
            return "Could not resolve path for diff."
        }
        var sections: [String] = []
        if change?.unstaged != nil {
            if let diff = try? runGit(root: root, arguments: ["diff", "--", relative]), !diff.isEmpty {
                sections.append("--- Unstaged changes ---\n\(diff)")
            }
        }
        if change?.staged != nil {
            if let diff = try? runGit(root: root, arguments: ["diff", "--cached", "--", relative]), !diff.isEmpty {
                sections.append("--- Staged changes ---\n\(diff)")
            }
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

    nonisolated private static func runGit(root: URL, arguments: [String]) throws -> String {
        let runner = SystemProcessRunner()
        var args = ["-C", root.path]
        args.append(contentsOf: arguments)
        return try runner.run(executable: "/usr/bin/git", arguments: args, currentDirectory: nil, environment: nil)
    }

    nonisolated private static func describe(_ error: Error) -> String {
        switch error {
        case ProcessRunError.nonZeroExit(_, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Git command failed." : trimmed
        case ProcessRunError.executableNotFound:
            return "Git is not available."
        default:
            return error.localizedDescription
        }
    }

    nonisolated static func parse(porcelain: String, toplevel: String) -> GitSnapshot {
        var snapshot = GitSnapshot(repositoryRoot: toplevel)
        var changeMap: [String: IDEGitChange] = [:]
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

            if code == "!!" {
                snapshot.statuses[path] = .ignored
                continue
            }

            let staged = statusFromIndexChar(code.first ?? " ")
            let unstaged = statusFromWorkTreeChar(code.last ?? " ")
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
