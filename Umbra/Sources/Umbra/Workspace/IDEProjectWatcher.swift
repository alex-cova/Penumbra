import Foundation
import os

/// Umbra's one file-watching engine: a single FSEvents stream (``IDEFSEventStream``) shared by
/// everything that reacts to on-disk changes — the Explorer tree, git status, local history, the
/// indexes and language services, the project systems' build files, open editor buffers and hex
/// tabs. Nothing else in Umbra watches files; new features subscribe to ``onBatch``.
///
/// The stream covers the project root and, for open files outside it (or a window with no folder),
/// those files' parent directories. Events are coalesced into `Batch`es on the main actor.
@MainActor
final class IDEProjectWatcher {
    struct Batch {
        /// Every reported path inside the project root, mapped into the root's own (un-resolved)
        /// path space. Never contains paths the Explorer ignores (`node_modules`, `.build`…).
        var paths: Set<String> = []
        /// Open files (``setOpenFiles(_:)``) that are not in ``paths``: outside the root, or under a
        /// directory the Explorer ignores. Spelled as they were registered.
        var openFilePaths: Set<String> = []
        /// `.git/index` or `.git/HEAD` changed: a stage, commit, or checkout.
        var gitMetadataChanged = false
        /// A ref moved: `HEAD`, `refs/**` (branches, tags, remotes, the stash), `packed-refs`,
        /// `ORIG_HEAD` or `FETCH_HEAD`. The log and the branch lists are stale.
        var gitRefsChanged = false
        /// A merge, rebase, cherry-pick or revert started, advanced or ended.
        var gitOperationChanged = false

        /// Directories whose listing may have changed. Hidden entries never appear in the tree.
        var affectedDirectories: Set<String> {
            var directories: Set<String> = []
            for path in paths {
                let name = (path as NSString).lastPathComponent
                guard !name.hasPrefix(".") else { continue }
                directories.insert((path as NSString).deletingLastPathComponent)
            }
            return directories
        }
    }

    /// Subscribers run on the main actor, in registration order.
    var onBatch: [(Batch) -> Void] = []

    private(set) var root: URL?
    /// Canonical path → the spelling it was registered with.
    private var openFiles: [String: String] = [:]
    private var openFileInput: Set<String> = []
    private let filter = Filter()
    private var stream: IDEFSEventStream?
    private var streamTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pending = Batch()
    private var rootPath = ""
    private var canonicalRoot = ""
    /// Canonical path of the resolved git directory when it is not already inside the project.
    private var gitDirectory = ""

    private static let coalescingDelay: Duration = .milliseconds(150)
    private static let latency: CFTimeInterval = 0.5

    /// Watches `url`'s tree (nil stops watching it). Open files stay watched either way.
    func setRoot(_ url: URL?) {
        root = url
        rootPath = url?.path ?? ""
        canonicalRoot = url.map { IDEFSEventStream.canonicalPath($0.path) } ?? ""
        gitDirectory = ""
        pending = Batch()
        flushTask?.cancel()
        flushTask = nil
        restartStream(force: true)
    }

    /// Watches `url` when it is the repository's git directory and that directory sits outside the
    /// project (a nested folder, a linked worktree, a submodule whose `.git` is a file). A git
    /// directory already inside the project is covered by the project root, so it is not added again.
    func setGitDirectory(_ url: URL?) {
        let next = url.map { IDEFSEventStream.canonicalPath($0.path) } ?? ""
        let watched = Self.separateGitDirectory(next, projectRoot: canonicalRoot)
        guard watched != gitDirectory else { return }
        gitDirectory = watched
        restartStream(force: false)
    }

    /// The files open in editors, by standardized path. They are reported even when they are
    /// outside the root or under a directory the Explorer ignores.
    func setOpenFiles(_ paths: Set<String>) {
        // Called on every tab refresh: resolve paths only when the set changed.
        guard paths != openFileInput else { return }
        openFileInput = paths
        var next: [String: String] = [:]
        for path in paths { next[IDEFSEventStream.canonicalPath(path)] = path }
        guard next != openFiles else { return }
        openFiles = next
        restartStream(force: false)
    }

    /// Stops watching the root and every open file.
    func stop() {
        root = nil
        rootPath = ""
        canonicalRoot = ""
        gitDirectory = ""
        openFiles = [:]
        openFileInput = []
        pending = Batch()
        flushTask?.cancel()
        flushTask = nil
        replaceStream(with: nil)
        filter.update(root: "", openFiles: [], gitDirectory: "")
    }

    /// The directories the stream must cover: the root, plus the parent of each open file outside it.
    private var wantedRoots: [String] {
        var roots: Set<String> = []
        if !canonicalRoot.isEmpty { roots.insert(canonicalRoot) }
        if !gitDirectory.isEmpty { roots.insert(gitDirectory) }
        for path in openFiles.keys where !Self.isInside(path, root: canonicalRoot) {
            roots.insert((path as NSString).deletingLastPathComponent)
        }
        return roots.sorted()
    }

    /// Recreates the stream when the directories it must cover changed (or always with `force`).
    /// The new stream starts before the old one stops, so no change falls in between.
    private func restartStream(force: Bool) {
        filter.update(root: canonicalRoot, openFiles: Set(openFiles.keys), gitDirectory: gitDirectory)
        let roots = wantedRoots
        guard force || roots != (stream?.roots ?? []) else { return }
        guard !roots.isEmpty else {
            replaceStream(with: nil)
            return
        }
        let filter = self.filter
        replaceStream(with: IDEFSEventStream(roots: roots, latency: Self.latency) { filter.accepts($0) })
    }

    private func replaceStream(with next: IDEFSEventStream?) {
        let previous = stream
        let previousTask = streamTask
        stream = next
        streamTask = nil
        if let next {
            next.start()
            streamTask = Task { [weak self] in
                for await path in next.paths {
                    guard let self, !Task.isCancelled else { return }
                    self.record(canonicalPath: path)
                }
            }
        }
        previousTask?.cancel()
        previous?.stop()
    }

    private func record(canonicalPath path: String) {
        if let tail = Self.gitTail(path, gitDirectory: gitDirectory) {
            note(tail)
        } else if Self.isInside(path, root: canonicalRoot) {
            if let range = path.range(of: "/.git/") {
                note(path[range.upperBound...])
            } else if Self.isRelevant(path) {
                pending.paths.insert(rootPath + path.dropFirst(canonicalRoot.count))
            } else if let open = openFiles[path] {
                pending.openFilePaths.insert(open)
            }
        } else if let open = openFiles[path] {
            pending.openFilePaths.insert(open)
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalescingDelay)
            guard let self, !Task.isCancelled else { return }
            let batch = self.pending
            self.pending = Batch()
            self.flushTask = nil
            guard !batch.paths.isEmpty || !batch.openFilePaths.isEmpty || batch.gitMetadataChanged
                || batch.gitRefsChanged || batch.gitOperationChanged
            else { return }
            for handler in self.onBatch { handler(batch) }
        }
    }

    nonisolated private static func isInside(_ path: String, root: String) -> Bool {
        !root.isEmpty && (path == root || path.hasPrefix(root + "/"))
    }

    /// Empty when `gitDirectory` is blank or already inside the project, so one index write is not delivered twice.
    nonisolated static func separateGitDirectory(_ gitDirectory: String, projectRoot: String) -> String {
        guard !gitDirectory.isEmpty, !isInside(gitDirectory, root: projectRoot) else { return "" }
        return gitDirectory
    }

    /// The path relative to `gitDirectory`, or nil when `path` is not inside it.
    nonisolated static func gitTail(_ path: String, gitDirectory: String) -> Substring? {
        guard isInside(path, root: gitDirectory), path != gitDirectory else { return nil }
        return path.dropFirst(gitDirectory.count + 1)
    }

    /// `index` and `HEAD` refresh status. Refs and operation files do too, and also reload the log.
    nonisolated static func classifyGitTail(_ tail: Substring) -> (metadata: Bool, refs: Bool, operation: Bool) {
        (metadata: tail == "index" || tail == "HEAD", refs: isRefsFile(tail), operation: isOperationFile(tail))
    }

    private func note(_ tail: Substring) {
        let kind = Self.classifyGitTail(tail)
        if kind.metadata { pending.gitMetadataChanged = true }
        if kind.refs { pending.gitRefsChanged = true }
        if kind.operation { pending.gitOperationChanged = true }
    }

    /// Index, refs, and operation files only. Object files are not a reason to refresh.
    nonisolated static func isGitDirectorySignal(_ tail: Substring) -> Bool {
        tail == "index" || isRefsFile(tail) || isOperationFile(tail)
    }

    /// Everything outside the directories the Explorer never lists, plus the `.git` files that
    /// signal a stage/commit/checkout, a moved ref, or a merge/rebase in progress.
    nonisolated private static func isRelevant(_ path: String) -> Bool {
        if let range = path.range(of: "/.git/") {
            let tail = path[range.upperBound...]
            return tail == "index" || isRefsFile(tail) || isOperationFile(tail)
        }
        if path.hasSuffix("/.git") { return false }
        for component in path.split(separator: "/") where IDEProjectModel.ignoredDirectoryNames.contains(String(component)) {
            return false
        }
        return true
    }

    /// What can move a branch, tag or remote ref. `HEAD` is here too: a checkout changes which
    /// branch is current and so the log's decorations.
    nonisolated static func isRefsFile(_ tail: Substring) -> Bool {
        tail == "HEAD" || tail == "packed-refs" || tail == "ORIG_HEAD" || tail == "FETCH_HEAD"
            || tail.hasPrefix("refs/")
    }

    /// The files git writes while a multi-step command is in progress, and removes when it ends.
    nonisolated static func isOperationFile(_ tail: Substring) -> Bool {
        tail == "MERGE_HEAD" || tail == "MERGE_MSG" || tail == "CHERRY_PICK_HEAD" || tail == "REVERT_HEAD"
            || tail == "BISECT_LOG" || tail.hasPrefix("rebase-merge/") || tail.hasPrefix("rebase-apply/")
            || tail.hasPrefix("sequencer/")
    }

    /// What the stream's queue may pass on: under the root, the relevant paths; anywhere, an open file.
    private final class Filter: Sendable {
        private struct State {
            var root = ""
            var openFiles: Set<String> = []
            var gitDirectory = ""
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        func update(root: String, openFiles: Set<String>, gitDirectory: String) {
            state.withLock { $0 = State(root: root, openFiles: openFiles, gitDirectory: gitDirectory) }
        }

        func accepts(_ path: String) -> Bool {
            state.withLock { state in
                if state.openFiles.contains(path) { return true }
                if let tail = IDEProjectWatcher.gitTail(path, gitDirectory: state.gitDirectory) {
                    return IDEProjectWatcher.isGitDirectorySignal(tail)
                }
                return IDEProjectWatcher.isInside(path, root: state.root) && IDEProjectWatcher.isRelevant(path)
            }
        }
    }
}
