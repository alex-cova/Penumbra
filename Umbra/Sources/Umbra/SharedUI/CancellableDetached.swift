import Foundation
import Penumbra
import os

/// Runs `operation` on a detached task and returns its result, passing the caller's cancellation on.
///
/// `await Task.detached { … }.value` does not do this: cancelling the awaiting task leaves the
/// detached child running to completion, so a superseded request (the previous keystroke's parse,
/// the previous pause's semantic pass) still spends its cores and only its result is dropped.
/// Here the child is cancelled with the caller, and `operation` starts with `Task.isCancelled`
/// already set when the caller was cancelled while the child waited for a thread, so work that
/// begins with `guard !Task.isCancelled` costs nothing once it has been superseded.
///
/// A synchronous stretch inside `operation` (a tree-sitter parse) is not interrupted; cancellation
/// only lands at the next check. Keep the checks at the boundaries between stages.
func runDetached<T: Sendable>(
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

/// What ``runDetached(priority:_:)`` has done since the process started, for tests that hold the
/// window's background work to a bound: how much was started, how much was superseded, and the
/// most that was ever waiting or running at once.
enum DetachedWorkStatistics {
    struct Counts: Equatable {
        var started = 0
        var cancelled = 0
        var inFlight = 0
        var peakInFlight = 0

        static func - (lhs: Counts, rhs: Counts) -> Counts {
            Counts(started: lhs.started - rhs.started, cancelled: lhs.cancelled - rhs.cancelled,
                   inFlight: lhs.inFlight, peakInFlight: lhs.peakInFlight)
        }
    }

    private static let state = OSAllocatedUnfairLock(initialState: Counts())

    static var counts: Counts { state.withLock { $0 } }

    /// Starts a new peak measurement from what is in flight now.
    static func resetPeak() {
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

extension TextView {
    /// The buffer's text, built off the main actor from a snapshot taken now, with the content
    /// generation it describes; `nil` when the caller was cancelled first.
    ///
    /// `text` copies a whole piece-tree document on the main actor (`Sources/Penumbra/CLAUDE.md`,
    /// "Reading a piece-tree buffer"). Work that runs once typing pauses reads through this and
    /// compares `contentGeneration` afterwards instead of comparing strings.
    @MainActor
    func snapshotText(priority: TaskPriority = .utility) async -> (text: String, generation: UInt64)? {
        let generation = contentGeneration
        let export = exportDocumentText()
        let text = await runDetached(priority: priority) { () -> String? in
            guard !Task.isCancelled else { return nil }
            return export.materializeUTF16Text()
        }
        guard let text, !Task.isCancelled else { return nil }
        return (text, generation)
    }
}
