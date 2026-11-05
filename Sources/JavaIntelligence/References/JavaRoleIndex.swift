import Foundation

/// The persistent syntactic-role index behind usage narrowing: for each source root, which
/// `.java` files use which identifiers in which roles (`roles.idx`, see
/// ``JavaRoleIndexShardWriter``). It answers "which files could possibly call `foo`?"; the
/// resolver then parses just those files and keeps the matches that bind to the target symbol.
/// Because nothing resolved is stored, the index only goes stale when a file itself changes,
/// and each file carries its own ``JavaStamp`` so an update re-reads only what changed.
///
/// Open editor buffers are handled with an overlay (``setOverlay(_:text:)``): for those files
/// the live buffer wins over whatever is on disk, parsed at overlay time (the overlay hook is
/// debounced upstream, as with the name index).
public actor JavaRoleIndex: JavaUsageCandidateSource {
    private struct RootState {
        let directory: URL
        let shardURL: URL
        var reader: JavaRoleIndexShardReader?
    }

    private let paths: JavaIndexPaths
    private let maxConcurrency: Int
    /// Keyed by the root's standardized path.
    private var roots: [String: RootState] = [:]
    /// Standardized file path -> identifier -> role mask of the live buffer text.
    private var overlay: [String: [String: UInt8]] = [:]

    public init(paths: JavaIndexPaths = .default(), maxConcurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)) {
        self.paths = paths
        self.maxConcurrency = maxConcurrency
    }

    // MARK: - Building

    /// Makes `roots` the set of indexed source roots (dropping any other) and brings each root's
    /// shard up to date, re-reading only files whose stamp changed and writing the shard
    /// atomically. Roots already current yield `.rootSkipped`.
    public func build(roots requested: [URL]) -> AsyncStream<JavaIndexScheduler.Progress> {
        var next: [String: RootState] = [:]
        var targets: [(key: String, directory: URL, shardURL: URL)] = []
        for url in requested {
            let directory = url.standardizedFileURL
            let key = directory.path
            guard next[key] == nil else { continue }
            let shardURL = paths.projectRoleIndexShard(for: directory)
            next[key] = roots[key] ?? RootState(directory: directory, shardURL: shardURL, reader: nil)
            targets.append((key, directory, shardURL))
        }
        roots = next
        return sync(targets: targets)
    }

    /// Changes the root set by a delta: `removing` roots are unloaded (their shards stay on disk for
    /// a later return), `adding` roots are synced and loaded. Roots in neither list, and adding a
    /// root that is already loaded, keep their loaded shard and are not touched.
    public func updateRoots(adding: [URL], removing: [URL]) -> AsyncStream<JavaIndexScheduler.Progress> {
        for url in removing {
            let key = url.standardizedFileURL.path
            roots[key] = nil
            let prefix = key.hasSuffix("/") ? key : key + "/"
            overlay = overlay.filter { !$0.key.hasPrefix(prefix) }
        }
        var targets: [(key: String, directory: URL, shardURL: URL)] = []
        for url in adding {
            let directory = url.standardizedFileURL
            let key = directory.path
            guard roots[key] == nil else { continue }
            let shardURL = paths.projectRoleIndexShard(for: directory)
            roots[key] = RootState(directory: directory, shardURL: shardURL, reader: nil)
            targets.append((key, directory, shardURL))
        }
        return sync(targets: targets)
    }

    /// The standardized paths of the currently loaded roots.
    public func rootPaths() -> Set<String> { Set(roots.keys) }

    private func sync(targets: [(key: String, directory: URL, shardURL: URL)]) -> AsyncStream<JavaIndexScheduler.Progress> {
        paths.ensureDirectoryExists()
        let limit = maxConcurrency

        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: (JavaIndexScheduler.Progress, String, JavaRoleIndexShardReader?).self) { group in
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

    private func install(_ reader: JavaRoleIndexShardReader, forKey key: String) {
        roots[key]?.reader = reader
    }

    /// Applies on-disk changes to the given files (created, edited or deleted `.java` files, or a
    /// changed/removed directory) and returns the root directories whose index actually changed.
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

    /// Uses `text` (an open, possibly unsaved buffer) instead of the file's indexed roles. The
    /// buffer is parsed here; the caller debounces, as with the name index.
    public func setOverlay(_ url: URL, text: String) {
        if let tree = JavaSyntaxParser().parse(text) {
            overlay[url.standardizedFileURL.path] = JavaRoleExtractor.roles(in: tree).mapValues { $0.rawValue }
        } else {
            // Unparseable text keeps every name a candidate, as the name index does.
            var roles: [String: UInt8] = [:]
            for identifier in JavaIdentifierScanner.identifiers(in: text) {
                roles[identifier] = JavaIdentifierRoles.all.rawValue
            }
            overlay[url.standardizedFileURL.path] = roles
        }
    }

    public func removeOverlay(_ url: URL) {
        overlay[url.standardizedFileURL.path] = nil
    }

    public func removeAllOverlays() {
        overlay.removeAll()
    }

    // MARK: - Queries

    /// Files under `roots` (directories, or single files) that use `identifier` in one of `roles`,
    /// sorted by path. Shard results for files with an overlay are replaced by the overlay's
    /// answer. An empty `roles` matches nothing.
    public func candidateFiles(
        containing identifier: String, roles: JavaIdentifierRoles, in requestedRoots: [URL]
    ) async -> [URL] {
        guard !roles.isEmpty, !identifier.isEmpty else { return [] }
        var result = Set<String>()
        var seenRoots = Set<String>()
        for url in requestedRoots {
            let directory = url.standardizedFileURL
            let key = directory.path
            guard seenRoots.insert(key).inserted else { continue }
            var state = roots[key] ?? RootState(directory: directory, shardURL: paths.projectRoleIndexShard(for: directory), reader: nil)
            if state.reader == nil {
                state.reader = try? JavaRoleIndexShardReader(url: state.shardURL)
                if roots[key] != nil { roots[key] = state }
            }
            let prefix = key.hasSuffix("/") ? key : key + "/"
            if let reader = state.reader {
                for relative in reader.relativePaths(containing: identifier, roles: roles) {
                    let path = prefix + relative
                    if overlay[path] != nil { continue }
                    result.insert(path)
                }
            }
            for (path, masks) in overlay where path.hasPrefix(prefix) {
                if let mask = masks[identifier], mask & roles.rawValue != 0 {
                    result.insert(path)
                }
            }
        }
        return result.sorted().map { URL(fileURLWithPath: $0) }
    }

    /// `JavaUsageCandidateSource` conformance: the name-only query keeps every role.
    public func candidateFiles(containing identifier: String, in requestedRoots: [URL]) async -> [URL] {
        await candidateFiles(containing: identifier, roles: .all, in: requestedRoots)
    }

    /// Number of files in the loaded shard of `root`, or `nil` when it has none.
    public func indexedFileCount(in root: URL) -> Int? {
        roots[root.standardizedFileURL.path]?.reader?.files.count
    }

    // MARK: - Shard synchronization

    private struct SyncOutcome {
        var reader: JavaRoleIndexShardReader?
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

    private static func rootID(_ directory: URL) -> String { "roles-\(directory.path)" }

    /// Brings `shardURL` in line with the files under `directory`. With `only == nil` every file's
    /// stamp is compared; otherwise just the listed relative paths are re-examined.
    private static func sync(directory: URL, shardURL: URL, only: Set<String>?) -> SyncOutcome {
        let existing = try? JavaRoleIndexShardReader(url: shardURL)
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        if let existing {
            return syncExisting(existing, directory: directory, shardURL: shardURL, prefix: prefix, only: only)
        }
        return syncMissing(directory: directory, shardURL: shardURL, prefix: prefix, only: only)
    }

    private static func syncExisting(
        _ existing: JavaRoleIndexShardReader, directory: URL, shardURL: URL, prefix: String, only: Set<String>?
    ) -> SyncOutcome {
        var idByPath: [String: Int] = [:]
        idByPath.reserveCapacity(existing.files.count)
        for (id, file) in existing.files.enumerated() { idByPath[file.relativePath] = id }

        var removing = Set<Int>()
        var replacing: [JavaRoleIndexEntry] = []
        var reindexed = 0

        func read(_ relative: String, url: URL) {
            guard let stamp = JavaStamp(url: url), let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            if let old = idByPath[relative] { removing.insert(old) }
            replacing.append(JavaRoleIndexEntry(
                relativePath: relative, stamp: stamp, roles: roleMasks(in: text)
            ))
            reindexed += 1
        }

        if let only {
            for relative in only {
                let url = URL(fileURLWithPath: prefix + relative)
                if let stamp = JavaStamp(url: url) {
                    if let old = idByPath[relative] {
                        if existing.files[old].stamp != stamp { read(relative, url: url) }
                    } else {
                        read(relative, url: url)
                    }
                } else if let old = idByPath[relative] {
                    removing.insert(old)
                }
            }
        } else {
            var seen = Set<String>()
            let scanned = JavaSourceStampScan.javaFiles(in: directory)
            if Task.isCancelled {
                return SyncOutcome(reader: existing, reindexed: 0, fileCount: existing.files.count, failure: nil)
            }
            if let scanned {
                for file in scanned {
                    seen.insert(file.relativePath)
                    if let old = idByPath[file.relativePath], existing.files[old].stamp == file.stamp { continue }
                    read(file.relativePath, url: URL(fileURLWithPath: prefix + file.relativePath))
                }
            } else {
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
                    if let old = idByPath[relative], let stamp = JavaStamp(url: url), existing.files[old].stamp == stamp {
                        continue
                    }
                    read(relative, url: url)
                }
            }
            if Task.isCancelled {
                return SyncOutcome(reader: existing, reindexed: 0, fileCount: existing.files.count, failure: nil)
            }
            for (id, file) in existing.files.enumerated() where !seen.contains(file.relativePath) {
                removing.insert(id)
            }
        }

        guard reindexed > 0 || !removing.isEmpty else {
            return SyncOutcome(reader: existing, reindexed: 0, fileCount: existing.files.count, failure: nil)
        }
        do {
            let reader = try JavaRoleIndexShardWriter().rewrite(from: existing, removing: removing, replacing: replacing, to: shardURL)
            // A removal-only change reindexes nothing but still rewrote the shard; report it as work.
            return SyncOutcome(reader: reader, reindexed: max(reindexed, 1), fileCount: reader.files.count, failure: nil)
        } catch {
            return SyncOutcome(reader: existing, reindexed: 0, fileCount: existing.files.count, failure: nil)
        }
    }

    /// No readable shard yet: read what is asked for and write one from scratch.
    private static func syncMissing(directory: URL, shardURL: URL, prefix: String, only: Set<String>?) -> SyncOutcome {
        var next: [String: JavaRoleIndexEntry] = [:]
        var reindexed = 0

        func read(_ relative: String, url: URL) {
            guard let stamp = JavaStamp(url: url), let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            next[relative] = JavaRoleIndexEntry(relativePath: relative, stamp: stamp, roles: roleMasks(in: text))
            reindexed += 1
        }

        if let only {
            for relative in only {
                read(relative, url: URL(fileURLWithPath: prefix + relative))
            }
        } else {
            let resolved = realPath(directory.path)
            let resolvedPrefix = resolved.hasSuffix("/") ? resolved : resolved + "/"
            for url in SourceRoot(directory: directory).javaFileURLs() {
                if Task.isCancelled { break }
                let path = url.path
                guard path.hasPrefix(resolvedPrefix) || path.hasPrefix(prefix) else { continue }
                let relative = String(path.dropFirst(path.hasPrefix(prefix) ? prefix.count : resolvedPrefix.count))
                read(relative, url: url)
            }
            if Task.isCancelled { return SyncOutcome(reader: nil, reindexed: 0, fileCount: 0, failure: nil) }
        }
        guard reindexed > 0 else {
            return SyncOutcome(reader: nil, reindexed: 0, fileCount: 0, failure: nil)
        }
        do {
            let entries = next.values.sorted { $0.relativePath < $1.relativePath }
            try JavaRoleIndexShardWriter().write(entries, to: shardURL)
            let reader = try JavaRoleIndexShardReader(url: shardURL)
            return SyncOutcome(reader: reader, reindexed: reindexed, fileCount: entries.count, failure: nil)
        } catch {
            return SyncOutcome(reader: nil, reindexed: 0, fileCount: 0, failure: nil)
        }
    }

    /// Identifier text to role bitmask: the extractor's verdict, or every role for text that does
    /// not parse (an unparseable file is never narrowed out).
    private static func roleMasks(in text: String) -> [String: UInt8] {
        guard let tree = JavaSyntaxParser().parse(text) else {
            var roles: [String: UInt8] = [:]
            for identifier in JavaIdentifierScanner.identifiers(in: text) {
                roles[identifier] = JavaIdentifierRoles.all.rawValue
            }
            return roles
        }
        return JavaRoleExtractor.roles(in: tree).mapValues { $0.rawValue }
    }
}
