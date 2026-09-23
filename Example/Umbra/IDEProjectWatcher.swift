import EditorIntelligence
import Foundation
import JavaIntelligence

/// One FSEvents stream over the project root, shared by everything that reacts to on-disk changes
/// (the Explorer tree and git status). Events are coalesced into `Batch`es on the main actor.
@MainActor
final class IDEProjectWatcher {
    struct Batch {
        /// Every reported path, mapped into the project root's own (un-resolved) path space.
        var paths: Set<String> = []
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

    private var watcher: FSEventsFileSystemWatcher?
    private var watchTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pending = Batch()

    private static let coalescingDelay: Duration = .milliseconds(150)

    func start(root: URL) {
        stop()
        let rootPath = root.path
        let resolvedPath = root.resolvingSymlinksInPath().path
        let watcher = FSEventsFileSystemWatcher(root: root, latency: 0.5) { path in
            Self.isRelevant(path)
        }
        self.watcher = watcher
        watchTask = Task { [weak self] in
            await watcher.start()
            for await event in watcher.events {
                guard let self, !Task.isCancelled, self.watcher === watcher else { return }
                let url: URL
                switch event {
                case .fileAdded(let value), .fileRemoved(let value), .fileChanged(let value): url = value
                }
                self.record(path: Self.remap(url.path, from: resolvedPath, to: rootPath))
            }
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        flushTask?.cancel()
        flushTask = nil
        pending = Batch()
        let watcher = self.watcher
        self.watcher = nil
        if let watcher {
            Task { await watcher.stop() }
        }
    }

    private func record(path: String) {
        if let range = path.range(of: "/.git/") {
            let tail = path[range.upperBound...]
            pending.gitMetadataChanged = pending.gitMetadataChanged || tail == "index" || tail == "HEAD"
        } else {
            pending.paths.insert(path)
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalescingDelay)
            guard let self, !Task.isCancelled else { return }
            let batch = self.pending
            self.pending = Batch()
            self.flushTask = nil
            for handler in self.onBatch { handler(batch) }
        }
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

    nonisolated private static func remap(_ path: String, from resolved: String, to root: String) -> String {
        guard resolved != root, path == resolved || path.hasPrefix(resolved + "/") else { return path }
        return root + path.dropFirst(resolved.count)
    }
}
