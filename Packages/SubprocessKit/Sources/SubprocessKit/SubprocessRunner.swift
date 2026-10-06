import Foundation

/// Runs one child to completion and returns what it did.
public enum SubprocessRunner {
    /// Runs `request` and waits for it without blocking a thread. Cancelling the calling `Task`
    /// stops the child (SIGTERM, then SIGKILL after `terminationGrace`) and the result says
    /// `cancelled`. `onOutput` sees each chunk as it arrives, on a private queue: keep it quick.
    ///
    /// Throws only when the child could not be started.
    public static func run(
        _ request: SubprocessRequest,
        onOutput: (@Sendable (Data, SubprocessOutputSource) -> Void)? = nil
    ) async throws -> SubprocessResult {
        let box = CancellableJob()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let job = try SubprocessJob.launch(request, onOutput: onOutput) { continuation.resume(returning: $0) }
                    box.set(job)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// The same run for synchronous callers: blocks the calling thread until the child is done.
    /// Both output pipes are drained concurrently, so a child cannot deadlock by filling one while
    /// the other is read. A timeout still applies; there is no cancellation. Do not call it from a
    /// Swift-concurrency task that other work depends on.
    public static func runBlocking(_ request: SubprocessRequest) throws -> SubprocessResult {
        let semaphore = DispatchSemaphore(value: 0)
        let slot = ResultSlot()
        try SubprocessJob.launch(request, onOutput: nil) { result in
            slot.set(result)
            semaphore.signal()
        }
        semaphore.wait()
        return slot.value
    }
}

/// Holds the job so the cancellation handler, which can run before the job exists, still reaches it.
private final class CancellableJob: @unchecked Sendable {
    private let lock = NSLock()
    private var job: SubprocessJob?
    private var cancelled = false

    func set(_ job: SubprocessJob) {
        lock.lock()
        self.job = job
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { job.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let job = job
        lock.unlock()
        job?.cancel()
    }
}

private final class ResultSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var result: SubprocessResult?

    func set(_ result: SubprocessResult) { lock.withLock { self.result = result } }

    var value: SubprocessResult {
        lock.withLock { result! }
    }
}
