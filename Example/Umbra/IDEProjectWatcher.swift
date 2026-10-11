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

    private static let coalescingDelay: Duration = .milliseconds(150)
    private static let latency: CFTimeInterval = 0.5

    /// Watches `url`'s tree (nil stops watching it). Open files stay watched either way.
    func setRoot(_ url: URL?) {
        root = url
        rootPath = url?.path ?? ""
        canonicalRoot = url.map { IDEFSEventStream.canonicalPath($0.path) } ?? ""
        pending = Batch()
        flushTask?.cancel()
        flushTask = nil
        restartStream(force: true)
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
        openFiles = [:]
        openFileInput = []
        pending = Batch()
        flushTask?.cancel()
        flushTask = nil
        replaceStream(with: nil)
        filter.update(root: "", openFiles: [])
    }

    /// The directories the stream must cover: the root, plus the parent of each open file outside it.
    private var wantedRoots: [String] {
        var roots: Set<String> = []
        if !canonicalRoot.isEmpty { roots.insert(canonicalRoot) }
        for path in openFiles.keys where !Self.isInside(path, root: canonicalRoot) {
            roots.insert((path as NSString).deletingLastPathComponent)
        }
        return roots.sorted()
    }

    /// Recreates the stream when the directories it must cover changed (or always with `force`).
    /// The new stream starts before the old one stops, so no change falls in between.
    private func restartStream(force: Bool) {
        filter.update(root: canonicalRoot, openFiles: Set(openFiles.keys))
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
        if Self.isInside(path, root: canonicalRoot) {
            if let range = path.range(of: "/.git/") {
                let tail = path[range.upperBound...]
                if tail == "index" || tail == "HEAD" { pending.gitMetadataChanged = true }
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
            guard !batch.paths.isEmpty || !batch.openFilePaths.isEmpty || batch.gitMetadataChanged else { return }
            for handler in self.onBatch { handler(batch) }
        }
    }

    nonisolated private static func isInside(_ path: String, root: String) -> Bool {
        !root.isEmpty && (path == root || path.hasPrefix(root + "/"))
    }

    /// Everything outside the directories the Explorer never lists, plus the two `.git` files that
    /// signal a stage/commit/checkout.
    nonisolated private static func isRelevant(_ path: String) -> Bool {
        if let range = path.range(of: "/.git/") {
            let tail = path[range.upperBound...]
            return tail == "index" || tail == "HEAD"
        }
        if path.hasSuffix("/.git") { return false }
        for component in path.split(separator: "/") where IDEProjectModel.ignoredDirectoryNames.contains(String(component)) {
            return false
        }
        return true
    }

    /// What the stream's queue may pass on: under the root, the relevant paths; anywhere, an open file.
    private final class Filter: Sendable {
        private struct State {
            var root = ""
            var openFiles: Set<String> = []
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        func update(root: String, openFiles: Set<String>) {
            state.withLock { $0 = State(root: root, openFiles: openFiles) }
        }

        func accepts(_ path: String) -> Bool {
            state.withLock { state in
                if state.openFiles.contains(path) { return true }
                return IDEProjectWatcher.isInside(path, root: state.root) && IDEProjectWatcher.isRelevant(path)
            }
        }
    }
}
