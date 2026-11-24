import Foundation
import os

/// Cuts a retry wait short ("Retry Now"). A session sets one as the task-local `current` around its call
/// to `LLMClient.stream`; the stream's task inherits it, and `HTTPStreamClient` waits through it between
/// attempts instead of a plain `Task.sleep`. A client that waits some other way, or not at all, ignores it.
public final class RetryWaker: Sendable {
    @TaskLocal public static var current: RetryWaker?

    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var timer: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Whether a wait is in progress right now.
    public var isWaiting: Bool { state.withLock { $0.continuation != nil } }

    /// Ends the wait in progress at once, so the next attempt starts now. Returns `false` when nothing was
    /// waiting (the request is already being sent, or no retry is due).
    @discardableResult
    public func wake() -> Bool { finishWait() }

    /// Waits `seconds`, or until `wake()` or cancellation, whichever comes first. Throws `CancellationError`
    /// when the task was cancelled, like `Task.sleep`.
    func sleep(for seconds: TimeInterval) async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    self?.finishWait()
                }
                let previous = state.withLock { state -> CheckedContinuation<Void, Never>? in
                    let previous = state.continuation
                    state.continuation = continuation
                    state.timer = timer
                    return previous
                }
                // One stream waits at a time; a stray earlier wait must not hang.
                previous?.resume()
                // A cancellation that landed before the wait was stored found nothing to end.
                if Task.isCancelled { finishWait() }
            }
        } onCancel: {
            finishWait()
        }
        try Task.checkCancellation()
    }

    @discardableResult
    private func finishWait() -> Bool {
        let (continuation, timer) = state.withLock { state in
            defer { state.continuation = nil; state.timer = nil }
            return (state.continuation, state.timer)
        }
        timer?.cancel()
        continuation?.resume()
        return continuation != nil
    }
}
