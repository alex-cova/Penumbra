import Foundation

/// Actor-isolated hover engine that queries registered providers and optionally caches results.
///
/// Providers are run concurrently. The first non-nil result is returned and, when caching is
/// enabled, remembered. Results key on document + cursor, so a cache is only valid while the
/// document is unchanged — hosts leave it off (the default) unless they can tolerate that.
public actor HoverEngine {
    private let providers: [HoverProvider]
    private var resultCache: HoverResultCache?

    public init(
        providers: [HoverProvider],
        cacheMaxSize: Int? = nil
    ) {
        self.providers = providers
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
        var tasks: [Task<HoverResult?, Never>] = []
        for provider in providers {
            tasks.append(Task { await provider.provide(context: context) })
        }
        for (index, task) in tasks.enumerated() {
            if let result = await task.value {
                for remaining in tasks.suffix(from: index + 1) {
                    remaining.cancel()
                }
                resultCache?.set(result, for: key)
                return result
            }
        }
        return nil
    }
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
