import Foundation

/// Thread-safe cache of prepared ``TreeSitterLanguage`` instances, keyed by a caller-supplied
/// identifier (e.g. an app's own language enum).
///
/// ``TreeSitterLanguage/prepare()`` compiles the language's highlight/injection queries and is
/// relatively expensive; it's also not safe to call concurrently on the same instance. Most apps
/// want exactly one prepared instance per language for the process lifetime — this cache provides
/// that without requiring every consumer to re-implement the locking.
///
/// ```swift
/// let cache = TreeSitterLanguageCache<MyLanguage>()
/// let language = cache.language(for: .swift) { .swift }
/// ```
public final class TreeSitterLanguageCache<Key: Hashable>: @unchecked Sendable {
    private let lock = NSLock()
    private var prepared: [Key: TreeSitterLanguage] = [:]

    public init() {}

    /// Returns the prepared language for `key`, creating and caching it via `make` on first
    /// access. `make` is only invoked when no cached instance exists; a `nil` result from `make`
    /// is not cached, so a later call will retry `make`.
    public func language(for key: Key, make: () -> TreeSitterLanguage?) -> TreeSitterLanguage? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = prepared[key] {
            return existing
        }
        guard let created = make() else {
            return nil
        }
        created.prepare()
        prepared[key] = created
        return created
    }

    /// Clears the cache. Useful in tests that want to measure prepare cost again.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        prepared.removeAll(keepingCapacity: false)
    }
}
