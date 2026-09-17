import Foundation

/// Retains one view-hosting instance per key (typically a document ID) across tab switches, so
/// switching between already-open documents doesn't tear down and rebuild the hosted view — losing
/// scroll position, undo history, and syntax-highlight state — every time.
///
/// This exists because `TextView` (and any coordinator/state a consumer wraps around it) is
/// expensive to recreate and stateful in ways that don't survive a rebuild. SwiftUI's
/// `NSViewRepresentable` has no built-in notion of "reuse this specific instance for this
/// document" — its `makeNSView`/`updateNSView` cycle, combined with structural identity churn
/// elsewhere in a view tree (e.g. a sidebar toggling on/off moving a pane to a different position),
/// can tear down and rebuild a hosted view far more often than a consumer wants. Pair with
/// ``EditorHostContainer`` to also survive that structural churn.
///
/// Generic over both the lookup key and the cached host type — a text-editor app might use
/// `EditorHostCache<UUID, MyPenumbraHostView>` keyed by document ID.
///
/// - Important: If a document's `id` gets reused for entirely different content — e.g. a
///   "temporary tab" slot being repointed at a different file while keeping the same identity —
///   call ``remove(_:)`` before the cache is asked for that key again, or a stale cached host will
///   keep showing the old content.
@MainActor
public final class EditorHostCache<Key: Hashable, Host: AnyObject> {
    private final class Entry {
        let host: Host
        /// Monotonic access sequence number — higher means more recently used. A counter
        /// rather than `Date()` so two accesses in the same clock tick still order correctly
        /// (an LRU tie-break on wall-clock time is otherwise non-deterministic).
        var lastAccess: UInt64

        init(host: Host, lastAccess: UInt64) {
            self.host = host
            self.lastAccess = lastAccess
        }
    }

    private var entries: [Key: Entry] = [:]
    private var maxEntries: Int
    private var accessCounter: UInt64 = 0

    public init(maxEntries: Int = 8) {
        self.maxEntries = max(maxEntries, 1)
    }

    private func nextAccessStamp() -> UInt64 {
        accessCounter += 1
        return accessCounter
    }

    /// Returns the cached host for `key`, creating it via `make` on a cache miss. `make` is not
    /// called on a hit.
    public func host(for key: Key, make: () -> Host) -> Host {
        if let entry = entries[key] {
            entry.lastAccess = nextAccessStamp()
            return entry.host
        }
        let host = make()
        entries[key] = Entry(host: host, lastAccess: nextAccessStamp())
        evictIfNeeded(keeping: key)
        return host
    }

    public func remove(_ key: Key) {
        entries.removeValue(forKey: key)
    }

    public func removeAll() {
        entries.removeAll()
    }

    public func contains(_ key: Key) -> Bool {
        entries[key] != nil
    }

    /// Re-clamps capacity, evicting the oldest-accessed entries first until back within the new
    /// limit. Unlike a "keep this one key safe" reconfigure, this has no protected key — there's
    /// no single "current" entry to pin when simply lowering the cap.
    public func reconfigure(maxEntries: Int) {
        self.maxEntries = max(maxEntries, 1)
        evictIfNeeded(keeping: nil)
    }

    private func evictIfNeeded(keeping protectedKey: Key?) {
        while entries.count > maxEntries {
            guard let victim = entries
                .filter({ $0.key != protectedKey })
                .min(by: { $0.value.lastAccess < $1.value.lastAccess })
            else { break }
            entries.removeValue(forKey: victim.key)
        }
    }
}
