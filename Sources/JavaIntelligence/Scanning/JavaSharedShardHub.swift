import Foundation

/// Gives every window the same parsed shard for a root that more than one project needs: the JDK
/// (two windows on two Java projects use the same JDK's API stubs) and the dependency jars
/// (``indexJars(_:)``, ``readers(for:)``).
///
/// Without it each window indexes the JDK on its own (two runs writing one shard file at once) and
/// parses the shard's name table into its own heap. Here one run serves every caller waiting for
/// the same shard, and the parsed ``JavaIndexShardReader`` (immutable, so safe to share) is handed
/// to all of them. The file itself is written atomically by ``JavaIndexShardWriter``, so a reader in
/// another process never sees a half-written shard.
public actor JavaSharedShardHub {
    /// How many parsed shards are kept. A reader costs heap for its name table, and people switch
    /// between a few JDKs at most.
    public static let maxCachedReaders = 4

    private let scheduler: JavaIndexScheduler
    /// Most recently used last.
    private var cachedOrder: [URL] = []
    private var readers: [URL: JavaIndexShardReader] = [:]
    private var runs: [URL: Task<JavaIndexShardReader?, Never>] = [:]
    /// How many indexing runs were started, for tests: waiting callers must not add to it.
    public private(set) var indexRunCount = 0

    /// How many class names the jar readers kept after their last user are allowed to hold. A
    /// reader's heap is its name and string tables: 0.5 to 0.7 KB per class name measured on a
    /// 700-jar project (216k names, 107 MB), so this keeps about 25 MB for jars nobody is using.
    /// Kept small because re-parsing is cheap: all 700 shards parse in parallel in about 0.12 s,
    /// so a large retained set would save little time for a lot of memory.
    public static let maxRetainedNames = 40_000

    private struct WeakReader {
        weak var reader: JavaIndexShardReader?
    }

    /// Every jar reader handed out that is still alive somewhere (a window's sources hold it).
    private var liveReaders: [URL: WeakReader] = [:]
    private var liveInsertsSincePrune = 0
    /// Readers of immutable jars (``JavaJarCachePolicy``) kept after their last user, least recently
    /// used first, within ``maxRetainedNames``.
    private var retainedReaders: [URL: JavaIndexShardReader] = [:]
    private var retainedOrder: [URL] = []
    private var retainedNames = 0
    /// Jar shards some caller is indexing now, with the callers waiting for each.
    private var jarRuns: [URL: [CheckedContinuation<Void, Never>]] = [:]

    private let retainedNameBudget: Int

    public init(paths: JavaIndexPaths = .default(), retainedNameBudget: Int = JavaSharedShardHub.maxRetainedNames) {
        scheduler = JavaIndexScheduler(paths: paths)
        self.retainedNameBudget = retainedNameBudget
    }

    /// The up-to-date shard for `root` at `shardURL`, indexing it first when it is missing or
    /// stale. Callers asking for the same shard while it is being indexed wait for that one run.
    /// `onProgress` reports the run and is only called for the caller that started it. Nil when
    /// the shard could not be built.
    public func shard(
        for root: any JavaIndexableRoot,
        at shardURL: URL,
        onProgress: (@MainActor @Sendable (JavaIndexScheduler.Progress) -> Void)? = nil
    ) async -> JavaIndexShardReader? {
        if let reader = readers[shardURL], reader.stamp == root.stamp {
            touch(shardURL)
            return reader
        }
        if let run = runs[shardURL] {
            return await run.value
        }
        indexRunCount += 1
        let scheduler = scheduler
        let run = Task<JavaIndexShardReader?, Never> {
            for await progress in await scheduler.index([(root: root, shardURL: shardURL)]) {
                if let onProgress {
                    await onProgress(progress)
                }
            }
            return try? JavaIndexShardReader(url: shardURL)
        }
        runs[shardURL] = run
        let reader = await run.value
        runs[shardURL] = nil
        if let reader {
            readers[shardURL] = reader
            touch(shardURL)
            evictLeastRecentlyUsed()
        }
        return reader
    }

    /// Forgets every parsed shard (the files stay). Memory pressure, or a test.
    public func dropCachedReaders() {
        readers.removeAll()
        cachedOrder.removeAll()
    }

    /// Forgets the parsed shard at `shardURL`, for a shard about to be deleted or rebuilt. A window
    /// that already holds the reader keeps using it; the next request parses the new file.
    public func invalidate(_ shardURL: URL) {
        readers[shardURL] = nil
        cachedOrder.removeAll { $0 == shardURL }
        liveReaders[shardURL] = nil
        removeRetained(shardURL)
    }

    /// Gives back what can be rebuilt from disk: the JDK readers and the jar readers nobody is
    /// using. Readers a window holds stay with it. Called by the host on memory pressure.
    public func trimMemory() {
        dropCachedReaders()
        for url in retainedOrder { retainedReaders[url] = nil }
        retainedOrder.removeAll()
        retainedNames = 0
    }

    // MARK: - Jars

    /// Indexes the jar shards that are missing or stale, once across every caller. A shard another
    /// caller is already indexing is waited for instead of indexed again, and a shard whose reader
    /// is still cached costs nothing. The stream reports one event per target, so a caller's
    /// "n of N" counter reaches N whoever did the work: `rootStarted` and `rootFinished` for what
    /// this caller indexed, `rootSkipped` for the rest.
    ///
    /// The runs belong to the hub: a caller that stops listening (its window switched project)
    /// does not cancel work other callers wait for.
    public func indexJars(_ targets: [(root: any JavaIndexableRoot, shardURL: URL)]) -> AsyncStream<JavaIndexScheduler.Progress> {
        AsyncStream { continuation in
            Task { await self.runJars(targets, continuation: continuation) }
        }
    }

    /// The parsed shards for `targets`, from memory when a cached or live reader still matches the
    /// file on disk and parsed now otherwise. Targets whose shard is missing or unreadable are
    /// absent from the result. Call after ``indexJars(_:)`` has finished.
    public func readers(for targets: [(root: any JavaIndexableRoot, shardURL: URL)]) async -> [URL: JavaIndexShardReader] {
        var result: [URL: JavaIndexShardReader] = [:]
        var missing: [(root: any JavaIndexableRoot, shardURL: URL)] = []
        for target in targets {
            let url = target.shardURL
            if let cached = cachedReader(for: url), cached.stamp == JavaIndexShardReader.readStamp(at: url) {
                result[url] = cached
                remember(cached, at: url, root: target.root)
            } else {
                missing.append(target)
            }
        }
        guard !missing.isEmpty else { return result }

        // Parsing decodes the shard's name tables: CPU work, so it runs off the actor, in parallel.
        let urls = missing.map(\.shardURL)
        let parsed = await withTaskGroup(of: (Int, JavaIndexShardReader?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { (index, try? JavaIndexShardReader(url: url)) }
            }
            var collected: [(Int, JavaIndexShardReader?)] = []
            for await item in group { collected.append(item) }
            return collected
        }
        for (index, reader) in parsed {
            guard let reader else { continue }
            let target = missing[index]
            result[target.shardURL] = reader
            remember(reader, at: target.shardURL, root: target.root)
        }
        return result
    }

    /// Jar readers kept for reuse after their last user, for tests and diagnostics.
    public var retainedReaderCount: Int { retainedReaders.count }
    public func isRetained(_ shardURL: URL) -> Bool { retainedReaders[shardURL] != nil }

    private func runJars(
        _ targets: [(root: any JavaIndexableRoot, shardURL: URL)],
        continuation: AsyncStream<JavaIndexScheduler.Progress>.Continuation
    ) async {
        var mine: [(root: any JavaIndexableRoot, shardURL: URL)] = []
        var waiting: [(root: any JavaIndexableRoot, shardURL: URL)] = []
        // Claiming is one synchronous pass, so two callers can never both take the same shard.
        for target in targets {
            if let cached = cachedReader(for: target.shardURL), cached.stamp == target.root.stamp {
                touchRetained(target.shardURL)
                continuation.yield(.rootSkipped(id: target.root.id, reason: "up to date"))
            } else if jarRuns[target.shardURL] != nil {
                waiting.append(target)
            } else {
                jarRuns[target.shardURL] = []
                mine.append(target)
            }
        }

        if !mine.isEmpty {
            indexRunCount += mine.count
            var shardByRoot: [String: URL] = [:]
            for target in mine { shardByRoot[target.root.id] = target.shardURL }
            for await progress in await scheduler.index(mine) {
                switch progress {
                case .allFinished:
                    break
                case .rootStarted:
                    continuation.yield(progress)
                case .rootFinished(let id, _), .rootSkipped(let id, _), .rootFailed(let id, _):
                    continuation.yield(progress)
                    if let url = shardByRoot[id] { finishJarRun(url) }
                }
            }
            // A run that ended early must not leave its waiters hanging.
            for target in mine { finishJarRun(target.shardURL) }
        }

        for target in waiting {
            await waitForJarRun(target.shardURL)
            continuation.yield(.rootSkipped(id: target.root.id, reason: "indexed by another window"))
        }
        continuation.yield(.allFinished)
        continuation.finish()
    }

    private func finishJarRun(_ shardURL: URL) {
        guard let waiters = jarRuns.removeValue(forKey: shardURL) else { return }
        for waiter in waiters { waiter.resume() }
    }

    private func waitForJarRun(_ shardURL: URL) async {
        guard jarRuns[shardURL] != nil else { return }
        await withCheckedContinuation { continuation in
            jarRuns[shardURL]?.append(continuation)
        }
    }

    private func cachedReader(for shardURL: URL) -> JavaIndexShardReader? {
        retainedReaders[shardURL] ?? liveReaders[shardURL]?.reader
    }

    /// Records a reader as live, and keeps it after its last user when its jar is immutable.
    private func remember(_ reader: JavaIndexShardReader, at shardURL: URL, root: any JavaIndexableRoot) {
        liveReaders[shardURL] = WeakReader(reader: reader)
        liveInsertsSincePrune += 1
        if liveInsertsSincePrune >= 512 {
            liveInsertsSincePrune = 0
            liveReaders = liveReaders.filter { $0.value.reader != nil }
        }
        guard let jar = root as? JarRoot, JavaJarCachePolicy.isImmutableArtifact(jar.jarURL) else { return }
        retain(reader, at: shardURL)
    }

    private func retain(_ reader: JavaIndexShardReader, at shardURL: URL) {
        removeRetained(shardURL)
        let names = reader.allQualifiedNames.count
        // A single huge jar is not worth evicting everything else for.
        guard names <= retainedNameBudget else { return }
        retainedReaders[shardURL] = reader
        retainedOrder.append(shardURL)
        retainedNames += names
        while retainedNames > retainedNameBudget, let oldest = retainedOrder.first {
            removeRetained(oldest)
        }
    }

    private func removeRetained(_ shardURL: URL) {
        guard let reader = retainedReaders.removeValue(forKey: shardURL) else { return }
        retainedNames -= reader.allQualifiedNames.count
        retainedOrder.removeAll { $0 == shardURL }
    }

    private func touchRetained(_ shardURL: URL) {
        guard retainedReaders[shardURL] != nil else { return }
        retainedOrder.removeAll { $0 == shardURL }
        retainedOrder.append(shardURL)
    }

    public var cachedReaderCount: Int { readers.count }

    private func touch(_ url: URL) {
        cachedOrder.removeAll { $0 == url }
        cachedOrder.append(url)
    }

    private func evictLeastRecentlyUsed() {
        while cachedOrder.count > Self.maxCachedReaders {
            readers[cachedOrder.removeFirst()] = nil
        }
    }
}
