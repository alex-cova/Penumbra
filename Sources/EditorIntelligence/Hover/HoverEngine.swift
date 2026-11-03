import Foundation

/// Actor-isolated hover engine that queries registered providers and optionally caches results.
///
/// Providers are run concurrently and listed in priority order. The highest-priority non-nil result is returned once every provider ahead of it has answered, or the best answer available after ``priorityGrace`` and, when caching is
/// enabled, remembered. Results key on document + cursor, so a cache is only valid while the
/// document is unchanged — hosts leave it off (the default) unless they can tolerate that.
public actor HoverEngine {
    private let providers: [HoverProvider]
    /// How long a lower-priority answer waits for higher-priority providers that have not
    /// answered yet. Hover is a rest-the-caret interaction; a stalled server must not hold it.
    private let priorityGrace: Duration
    private var resultCache: HoverResultCache?

    public init(
        providers: [HoverProvider],
        cacheMaxSize: Int? = nil,
        priorityGrace: Duration = .milliseconds(250)
    ) {
        self.providers = providers
        self.priorityGrace = priorityGrace
        self.resultCache = cacheMaxSize.map(HoverResultCache.init(maxSize:))
    }

    /// Request hover information for the given context.
    ///
    /// Returns the first non-nil result produced by the registered providers, or `nil` if no
    /// provider can resolve hover information for the context.
    public func hover(context: HoverContext) async -> HoverResult? {
        let key = HoverCacheKey(documentID: context.document.id, cursor: context.cursor)
        if let cached = resultCache?.get(key) {
            return cached
        }
        let providers = self.providers
        guard !providers.isEmpty else { return nil }
        let grace = priorityGrace
        // Unstructured tasks, not a task group: a group waits for every child before it returns,
        // so a provider that ignores cancellation (a stalled server request) would still hold the
        // tooltip back after the answer was chosen.
        let (arrivals, continuation) = AsyncStream.makeStream(of: HoverArrival.self)
        var tasks: [Task<Void, Never>] = providers.enumerated().map { index, provider in
            Task { continuation.yield(.provider(index, await provider.provide(context: context))) }
        }
        tasks.append(Task {
            try? await Task.sleep(for: grace)
            continuation.yield(.graceElapsed)
        })
        defer {
            for task in tasks { task.cancel() }
            continuation.finish()
        }
        var result: HoverResult?
        var finished = Set<Int>()
        var answers: [Int: HoverResult] = [:]
        var graceElapsed = false
        for await arrival in arrivals {
            switch arrival {
            case .graceElapsed:
                graceElapsed = true
            case .provider(let index, let answer):
                finished.insert(index)
                if let answer { answers[index] = answer }
            }
            // Provider order is priority (specific language services first, the generic symbol
            // provider last). The best answer so far wins once every provider ahead of it has
            // finished; after the grace period the best answer in hand wins, so one stalled
            // high-priority provider cannot hold the tooltip back indefinitely.
            if let best = answers.keys.min(),
               graceElapsed || (0..<best).allSatisfy(finished.contains) {
                result = answers[best]
                break
            }
            if finished.count == providers.count { break }
        }
        if let result {
            resultCache?.set(result, for: key)
            return result
        }
        return nil
    }
}

private enum HoverArrival: Sendable {
    case provider(Int, HoverResult?)
    case graceElapsed
}

/// Bounded least-recently-used store for hover results. It lives inside `HoverEngine` —
/// itself an actor — so it needs no isolation of its own, and no `await` hop on the
/// caret-rest hover path. `Cache` (the former generic actor wrapper) had no other users.
private struct HoverResultCache {
    private let maxSize: Int
    private var storage: [HoverCacheKey: HoverResult] = [:]
    private var accessOrder: [HoverCacheKey] = []

    init(maxSize: Int = 100) {
        self.maxSize = maxSize
    }

    mutating func get(_ key: HoverCacheKey) -> HoverResult? {
        guard let value = storage[key] else { return nil }
        recordAccess(key)
        return value
    }

    mutating func set(_ value: HoverResult, for key: HoverCacheKey) {
        if storage[key] == nil, storage.count >= maxSize, let oldest = accessOrder.first {
            storage.removeValue(forKey: oldest)
            accessOrder.removeAll { $0 == oldest }
        }
        storage[key] = value
        recordAccess(key)
    }

    private mutating func recordAccess(_ key: HoverCacheKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}

/// Cache key for hover results.
public struct HoverCacheKey: Hashable, Sendable {
    public let documentID: DocumentID
    public let cursor: Cursor

    public init(documentID: DocumentID, cursor: Cursor) {
        self.documentID = documentID
        self.cursor = cursor
    }
}
