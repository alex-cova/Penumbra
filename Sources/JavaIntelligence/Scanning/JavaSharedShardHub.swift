import Foundation

/// Gives every window the same parsed shard for a root that more than one project needs, the JDK
/// being the case that matters: two windows on two Java projects use the same JDK's API stubs.
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

    public init(paths: JavaIndexPaths = .default()) {
        scheduler = JavaIndexScheduler(paths: paths)
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
