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

    /// Starts `request` and returns at once with a handle to write to it, stop it, and wait for its
    /// result. Use it with `standardInput: .interactive`; otherwise it is `run` without the wait.
    ///
    /// Throws only when the child could not be started.
    public static func start(
        _ request: SubprocessRequest,
        onOutput: (@Sendable (Data, SubprocessOutputSource) -> Void)? = nil
    ) throws -> SubprocessHandle {
        let handle = SubprocessHandle()
        let job = try SubprocessJob.launch(request, onOutput: onOutput) { handle.finish($0) }
        handle.attach(job)
        return handle
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

/// A running child started with `SubprocessRunner.start`.
public final class SubprocessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var job: SubprocessJob?
    private var outcome: SubprocessResult?
    private var waiters: [CheckedContinuation<SubprocessResult, Never>] = []

    fileprivate init() {}

    fileprivate func attach(_ job: SubprocessJob) {
        lock.withLock { self.job = job }
    }

    fileprivate func finish(_ result: SubprocessResult) {
        let continuations: [CheckedContinuation<SubprocessResult, Never>] = lock.withLock {
            outcome = result
            let waiting = waiters
            waiters = []
            return waiting
        }
        continuations.forEach { $0.resume(returning: result) }
    }

    /// The child's process id.
    public var processIdentifier: Int32 {
        lock.withLock { job?.processIdentifier ?? 0 }
    }

    /// Sends `data` to the child's stdin. A no-op for a child that was not started with
    /// `.interactive`, that has exited, or that stopped reading.
    public func write(_ data: Data) {
        lock.withLock { job }?.write(data)
    }

    /// Closes the child's stdin once everything written is delivered.
    public func closeInput() {
        lock.withLock { job }?.closeInput()
    }

    /// Stops the child: SIGTERM, then SIGKILL after the request's `terminationGrace`. The result
    /// says `cancelled`. A no-op once it has exited.
    public func terminate() {
        lock.withLock { job }?.cancel()
    }

    /// Whether the child has exited and its result is known.
    public var isFinished: Bool {
        lock.withLock { outcome != nil }
    }

    /// Waits for the child to end.
    public var result: SubprocessResult {
        get async {
            await withCheckedContinuation { continuation in
                let known: SubprocessResult? = lock.withLock {
                    if let outcome { return outcome }
                    waiters.append(continuation)
                    return nil
                }
                if let known { continuation.resume(returning: known) }
            }
        }
    }
}
