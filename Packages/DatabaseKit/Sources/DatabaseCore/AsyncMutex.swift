import Foundation

/// A first-in, first-out lock for async code. Used where several callers must share one database
/// connection one statement at a time (a connection runs a single statement at once; queueing
/// keeps order and never interleaves).
///
/// Waiting is not cancellation-aware: a waiter that is cancelled still gets its turn and should
/// check `Task.isCancelled` itself. Callers pair `lock()` with `unlock()` in a `do/catch`.
public actor AsyncMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func lock() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func unlock() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            // Ownership passes straight to the next waiter; the lock never appears free in between.
            waiters.removeFirst().resume()
        }
    }

    /// Runs `body` while holding the lock.
    public func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await lock()
        do {
            let value = try await body()
            unlock()
            return value
        } catch {
            unlock()
            throw error
        }
    }
}
