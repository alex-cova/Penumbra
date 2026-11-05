import Foundation
import os

/// Runs `operation` on a detached task and returns its result, passing the caller's cancellation on.
///
/// `await Task.detached { … }.value` does not do this: cancelling the awaiting task leaves the
/// detached child running to completion, so a superseded request (the previous keystroke's search,
/// the previous pause's parse) still spends its cores and only its result is dropped. Worse, work
/// that is written to stop (a loop that checks `Task.isCancelled`, as `FindSearchEngine`'s scans
/// do) never sees the flag, because nothing ever sets it on the child.
///
/// Here the child is cancelled with the caller, and `operation` starts with `Task.isCancelled`
/// already set when the caller was cancelled while the child waited for a thread, so work that
/// begins with `guard !Task.isCancelled` costs nothing once it has been superseded.
///
/// A synchronous stretch inside `operation` (a tree-sitter parse) is not interrupted; cancellation
/// only lands at the next check. Keep the checks at the boundaries between stages.
///
/// Use it where a newer request replaces the one awaiting. A save, a one-shot read or a task the
/// owner stores and cancels itself gains nothing from it.
public func runDetached<T: Sendable>(
    priority: TaskPriority? = nil,
    _ operation: @escaping @Sendable () async -> T
) async -> T {
    DetachedWorkStatistics.begin()
    defer { DetachedWorkStatistics.end() }
    let task = Task.detached(priority: priority, operation: operation)
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        DetachedWorkStatistics.noteCancelled()
        task.cancel()
    }
}

/// ``runDetached(priority:_:)`` for work that throws; the error reaches the caller as before.
public func runDetached<T: Sendable>(
    priority: TaskPriority? = nil,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    DetachedWorkStatistics.begin()
    defer { DetachedWorkStatistics.end() }
    let task = Task.detached(priority: priority, operation: operation)
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        DetachedWorkStatistics.noteCancelled()
        task.cancel()
    }
}

/// What ``runDetached(priority:_:)`` has done since the process started, for tests that hold a
/// window's background work to a bound: how much was started, how much was superseded, and the
/// most that was ever waiting or running at once.
public enum DetachedWorkStatistics {
    public struct Counts: Sendable, Equatable {
        public var started = 0
        public var cancelled = 0
        public var inFlight = 0
        public var peakInFlight = 0

        public static func - (lhs: Counts, rhs: Counts) -> Counts {
            Counts(started: lhs.started - rhs.started, cancelled: lhs.cancelled - rhs.cancelled,
                   inFlight: lhs.inFlight, peakInFlight: lhs.peakInFlight)
        }
    }

    private static let state = OSAllocatedUnfairLock(initialState: Counts())

    public static var counts: Counts { state.withLock { $0 } }

    /// Starts a new peak measurement from what is in flight now.
    public static func resetPeak() {
        state.withLock { $0.peakInFlight = $0.inFlight }
    }

    fileprivate static func begin() {
        state.withLock {
            $0.started += 1
            $0.inFlight += 1
            $0.peakInFlight = max($0.peakInFlight, $0.inFlight)
        }
    }

    fileprivate static func end() {
        state.withLock { $0.inFlight -= 1 }
    }

    fileprivate static func noteCancelled() {
        state.withLock { $0.cancelled += 1 }
    }
}
