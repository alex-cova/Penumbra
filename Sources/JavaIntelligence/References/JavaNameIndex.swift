import Foundation

/// The persistent identifier index behind semantic Find Usages and rename: for each source root,
/// which `.java` files mention which identifiers (`refs.idx`, see ``JavaNameIndexShardWriter``).
/// It answers "which files could possibly use `foo`?"; a resolver then parses just those files and
/// keeps the matches that bind to the target symbol. Because nothing resolved is stored, the index
/// only goes stale when a file itself changes, and each file carries its own ``JavaStamp`` so an
/// update re-tokenizes only what changed.
///
/// Open editor buffers are handled with an overlay (``setOverlay(_:text:)``): for those files the
/// live text wins over whatever is on disk.
public actor JavaNameIndex: JavaUsageCandidateSource {
    private struct RootState {
        let directory: URL
        let shardURL: URL
        var reader: JavaNameIndexShardReader?
    }

    private let paths: JavaIndexPaths
    private let maxConcurrency: Int
    /// Keyed by the root's standardized path.
    private var roots: [String: RootState] = [:]
    /// Standardized file path -> identifiers of the live buffer text.
    private var overlay: [String: Set<String>] = [:]

    public init(paths: JavaIndexPaths = .default(), maxConcurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)) {
        self.paths = paths
        self.maxConcurrency = maxConcurrency
    }

    // MARK: - Building

    /// Makes `roots` the set of indexed source roots (dropping any other) and brings each root's
    /// shard up to date, re-tokenizing only files whose stamp changed and writing the shard
    /// atomically. Roots already current yield `.rootSkipped`.
    public func build(roots requested: [URL]) -> AsyncStream<JavaIndexScheduler.Progress> {
        var next: [String: RootState] = [:]
        var targets: [(key: String, directory: URL, shardURL: URL)] = []
        for url in requested {
            let directory = url.standardizedFileURL
            let key = directory.path
            guard next[key] == nil else { continue }
            let shardURL = paths.projectNameIndexShard(for: directory)
            next[key] = roots[key] ?? RootState(directory: directory, shardURL: shardURL, reader: nil)
            targets.append((key, directory, shardURL))
        }
        roots = next
        paths.ensureDirectoryExists()
        let limit = maxConcurrency

        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: (JavaIndexScheduler.Progress, String, JavaNameIndexShardReader?).self) { group in
                    var iterator = targets.makeIterator()
                    var active = 0

                    func addNext() {
                        guard let target = iterator.next() else { return }
                        active += 1
                        let id = Self.rootID(target.directory)
                        continuation.yield(.rootStarted(id: id))
                        group.addTask {
                            let outcome = Self.sync(directory: target.directory, shardURL: target.shardURL, only: nil)
                            return (outcome.progress(id: id), target.key, outcome.reader)
                        }
                    }

                    for _ in 0..<limit { addNext() }
                    while active > 0 {
                        guard let (progress, key, reader) = await group.next() else { break }
                        active -= 1
                        if let reader { self.install(reader, forKey: key) }
                        continuation.yield(progress)
                        addNext()
                    }
                }
                continuation.yield(.allFinished)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func install(_ reader: JavaNameIndexShardReader, forKey key: String) {
        roots[key]?.reader = reader
    }

    /// Applies on-disk changes to the given files (created, edited or deleted `.java` files, or a
    /// changed/removed directory) and returns the root directories whose index actually changed, so
    /// the caller can refresh anything else derived from them (the stub shard).
    @discardableResult
    public func filesChanged(_ urls: [URL]) -> [URL] {
        var touched: [String: Set<String>] = [:]
        var fullRefresh = Set<String>()
        for url in urls {
            let standardized = url.standardizedFileURL
            let path = standardized.path
            for key in roots.keys {
                let prefix = key.hasSuffix("/") ? key : key + "/"
                guard path.hasPrefix(prefix) else { continue }
                let relative = String(path.dropFirst(prefix.count))
                if standardized.pathExtension == "java" {
                    touched[key, default: []].insert(relative)
                } else if standardized.pathExtension.isEmpty {
                    // A directory was added, removed or renamed: its files are unknown, rescan.
                    fullRefresh.insert(key)
                }
            }
        }
        var affected: [URL] = []
        for key in Set(touched.keys).union(fullRefresh) {
            guard var state = roots[key] else { continue }
            let only: Set<String>? = fullRefresh.contains(key) ? nil : touched[key]
            let outcome = Self.sync(directory: state.directory, shardURL: state.shardURL, only: only)
            if let reader = outcome.reader { state.reader = reader }
            roots[key] = state
            if outcome.reindexed > 0 { affected.append(state.directory) }
        }
        return affected
    }

    // MARK: - Overlay

    /// Uses `text` (an open, possibly unsaved buffer) instead of the file's indexed contents.
    public func setOverlay(_ url: URL, text: String) {
        overlay[url.standardizedFileURL.path] = JavaIdentifierScanner.identifiers(in: text)
    }

    public func removeOverlay(_ url: URL) {
        overlay[url.standardizedFileURL.path] = nil
    }

    public func removeAllOverlays() {
        overlay.removeAll()
    }

    // MARK: - Queries

    /// Files under `roots` that mention `identifier`, sorted by path. Shard results for files with
    /// an overlay are replaced by the overlay's answer.
    public func candidateFiles(containing identifier: String, in requestedRoots: [URL]) async -> [URL] {
        var result = Set<String>()
        var seenRoots = Set<String>()
        for url in requestedRoots {
            let directory = url.standardizedFileURL
            let key = directory.path
            guard seenRoots.insert(key).inserted else { continue }
            var state = roots[key] ?? RootState(directory: directory, shardURL: paths.projectNameIndexShard(for: directory), reader: nil)
            if state.reader == nil {
                state.reader = try? JavaNameIndexShardReader(url: state.shardURL)
                if roots[key] != nil { roots[key] = state }
            }
            let prefix = key.hasSuffix("/") ? key : key + "/"
            if let reader = state.reader {
                for relative in reader.relativePaths(containing: identifier) {
                    let path = prefix + relative
                    if overlay[path] != nil { continue }
                    if FileManager.default.fileExists(atPath: path) { result.insert(path) }
                }
            }
            for (path, identifiers) in overlay where path.hasPrefix(prefix) && identifiers.contains(identifier) {
                result.insert(path)
            }
        }
        return result.sorted().map { URL(fileURLWithPath: $0) }
    }

    /// Number of files in the loaded shard of `root`, or `nil` when it has none.
    public func indexedFileCount(in root: URL) -> Int? {
        roots[root.standardizedFileURL.path]?.reader?.files.count
    }

    // MARK: - Shard synchronization

    private struct SyncOutcome {
        var reader: JavaNameIndexShardReader?
        var reindexed: Int
        var fileCount: Int
        var failure: String?

        func progress(id: String) -> JavaIndexScheduler.Progress {
            if let failure { return .rootFailed(id: id, message: failure) }
            return reindexed == 0 ? .rootSkipped(id: id, reason: "up to date") : .rootFinished(id: id, classCount: fileCount)
        }
    }

    /// `realpath(3)`. Unlike `URL.resolvingSymlinksInPath`, it keeps `/private` in `/private/var/...`.
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func rootID(_ directory: URL) -> String { "names-\(directory.path)" }

    /// Brings `shardURL` in line with the files under `directory`. With `only == nil` every file's
    /// stamp is compared; otherwise just the listed relative paths are re-examined.
    private static func sync(directory: URL, shardURL: URL, only: Set<String>?) -> SyncOutcome {
        let existing = try? JavaNameIndexShardReader(url: shardURL)
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        var previous: [String: JavaNameIndexEntry] = [:]
        if let existing {
            for entry in existing.allEntries() { previous[entry.relativePath] = entry }
        }

        var next: [String: JavaNameIndexEntry] = [:]
        var reindexed = 0
        var changed = existing == nil

        func tokenize(_ relative: String) {
            let url = URL(fileURLWithPath: prefix + relative)
            guard let stamp = JavaStamp(url: url), let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            next[relative] = JavaNameIndexEntry(relativePath: relative, stamp: stamp, identifiers: JavaIdentifierScanner.identifiers(in: text))
            reindexed += 1
        }

        if let only {
            next = previous
            for relative in only {
                let old = previous[relative]
                let url = URL(fileURLWithPath: prefix + relative)
                if let stamp = JavaStamp(url: url) {
                    if old?.stamp != stamp { tokenize(relative) }
                } else if old != nil {
                    next[relative] = nil
                    changed = true
                }
            }
        } else {
            var seen = Set<String>()
            // The enumerator reports symlink-resolved URLs (`/private/var/...`), so measure the
            // relative path against the resolved root.
            let resolved = realPath(directory.path)
            let resolvedPrefix = resolved.hasSuffix("/") ? resolved : resolved + "/"
            for url in SourceRoot(directory: directory).javaFileURLs() {
                if Task.isCancelled { break }
                let path = url.path
                guard path.hasPrefix(resolvedPrefix) || path.hasPrefix(prefix) else { continue }
                let relative = String(path.dropFirst(path.hasPrefix(prefix) ? prefix.count : resolvedPrefix.count))
                seen.insert(relative)
                if let old = previous[relative], let stamp = JavaStamp(url: url), old.stamp == stamp {
                    next[relative] = old
                } else {
                    tokenize(relative)
                }
            }
            if Task.isCancelled { return SyncOutcome(reader: existing, reindexed: 0, fileCount: previous.count, failure: nil) }
            if seen.count != previous.count || !Set(previous.keys).isSubset(of: seen) { changed = true }
        }
        if reindexed > 0 { changed = true }

        guard changed else {
            return SyncOutcome(reader: existing, reindexed: 0, fileCount: previous.count, failure: nil)
        }
        do {
            let entries = next.values.sorted { $0.relativePath < $1.relativePath }
            try JavaNameIndexShardWriter().write(entries, to: shardURL)
            let reader = try JavaNameIndexShardReader(url: shardURL)
            // A removal-only change reindexes nothing but still rewrote the shard; report it as work.
            return SyncOutcome(reader: reader, reindexed: max(reindexed, 1), fileCount: entries.count, failure: nil)
        } catch {
            return SyncOutcome(reader: existing, reindexed: 0, fileCount: previous.count, failure: String(describing: error))
        }
    }
}
