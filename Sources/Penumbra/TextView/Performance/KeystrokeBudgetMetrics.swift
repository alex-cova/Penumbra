import Foundation

/// Metrics collected during `PerfHarness keystroke-budget` and related tests.
public enum KeystrokeBudgetMetrics: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _observerPending = false
    nonisolated(unsafe) private static var _nextDrawableBeforeObserver = 0

    public static var observerPending: Bool {
        get { lock.withLock { _observerPending } }
        set { lock.withLock { _observerPending = newValue } }
    }

    public static func recordNextDrawableBeforeObserver() {
        lock.withLock {
            guard _observerPending else { return }
            _nextDrawableBeforeObserver += 1
        }
    }

    public static func consumeNextDrawableBeforeObserverCount() -> Int {
        lock.withLock {
            defer { _nextDrawableBeforeObserver = 0 }
            return _nextDrawableBeforeObserver
        }
    }
}
