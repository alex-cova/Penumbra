import Foundation

/// Indexes a set of ``JavaIndexableRoot``s to disk, skipping any whose on-disk shard already
/// matches its current ``JavaStamp`` -- the equivalent of `UnindexedFilesScanner` deciding which
/// roots/files actually need (re)scanning. Root reads run with bounded concurrency (capped at the
/// number of active processors) via a `TaskGroup`, matching `UnindexedFilesScannerExecutorImpl`'s
/// worker-pool approach without a dedicated thread pool of our own.
public actor JavaIndexScheduler {
    public enum Progress: Sendable, Equatable {
        case rootStarted(id: String)
        case rootSkipped(id: String, reason: String)
        case rootFinished(id: String, classCount: Int)
        case rootFailed(id: String, message: String)
        case allFinished
    }

    private let paths: JavaIndexPaths
    private let maxConcurrency: Int

    public init(paths: JavaIndexPaths = .default(), maxConcurrency: Int = max(1, ProcessInfo.processInfo.activeProcessorCount)) {
        self.paths = paths
        self.maxConcurrency = maxConcurrency
    }

    /// Indexes every root whose shard (at `shardURL(for:)`) is missing or stale, writing results as
    /// they complete and yielding progress. Callers that just want the finished shard set can drain
    /// the stream and ignore the events.
    public func index(_ roots: [(root: any JavaIndexableRoot, shardURL: URL)]) -> AsyncStream<Progress> {
        paths.ensureDirectoryExists()
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Progress.self) { group in
                    var iterator = roots.makeIterator()
                    var active = 0

                    func addNext() {
                        guard let next = iterator.next() else { return }
                        active += 1
                        group.addTask {
                            await Self.indexOne(root: next.root, shardURL: next.shardURL)
                        }
                    }

                    for _ in 0..<maxConcurrency { addNext() }
                    while active > 0 {
                        guard let progress = await group.next() else { break }
                        active -= 1
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

    private static func indexOne(root: any JavaIndexableRoot, shardURL: URL) async -> Progress {
        let currentStamp = root.stamp
        if let existing = try? JavaIndexShardReader(url: shardURL), existing.stamp == currentStamp {
            return .rootSkipped(id: root.id, reason: "up to date")
        }
        do {
            let stubs = try root.readStubs()
            // Project-scoped shards nest under a per-root subdirectory (JavaIndexPaths.
            // projectSourcesShard); JDK/JAR shards sit directly under the (already-created) cache
            // root, so this is a no-op for those.
            try FileManager.default.createDirectory(at: shardURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JavaIndexShardWriter().write(stubs, stamp: currentStamp, to: shardURL)
            return .rootFinished(id: root.id, classCount: stubs.count)
        } catch {
            return .rootFailed(id: root.id, message: String(describing: error))
        }
    }
}
