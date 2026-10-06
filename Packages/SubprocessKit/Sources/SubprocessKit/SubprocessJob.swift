import Darwin
import Dispatch
import Foundation

/// One running child: its readers, its watchdog timer and its exit, resolved into exactly one
/// `SubprocessResult`. Callback-based so both the async and the blocking runner sit on it without
/// a `Task` in between.
///
/// Threads: pipes are read on the job's private serial `queue` (non-blocking, no explicit QoS), the
/// child is reaped on one dedicated `Thread`, and signals come from anywhere under `lock`. Nothing
/// blocks a Swift-concurrency thread.
final class SubprocessJob: @unchecked Sendable {
    private enum Reason { case timedOut, cancelled }

    private let request: SubprocessRequest
    private let pid: pid_t
    private let queue = DispatchQueue(label: "SubprocessKit.job")
    private let started = Date()
    private let onOutput: (@Sendable (Data, SubprocessOutputSource) -> Void)?
    private let grace: DispatchTimeInterval

    // Guarded by `lock`.
    private let lock = NSLock()
    private var reaped = false
    private var reason: Reason?

    // Confined to `queue`.
    private var stdoutReader: PipeReader?
    private var stderrReader: PipeReader?
    private var stdinWriter: PipeWriter?
    private var stdoutBuffer: OutputBuffer
    private var stderrBuffer: OutputBuffer
    private var timer: DispatchSourceTimer?

    // Set once in `begin`, before the waiter thread exists.
    private var completion: (@Sendable (SubprocessResult) -> Void)?
    private var exit = SubprocessExit(exitCode: nil, signal: nil)
    private let spawned: SpawnedProcess

    private init(
        request: SubprocessRequest, spawned: SpawnedProcess,
        onOutput: (@Sendable (Data, SubprocessOutputSource) -> Void)?
    ) {
        self.request = request
        self.spawned = spawned
        pid = spawned.pid
        self.onOutput = onOutput
        grace = .nanoseconds(Int(clamping: max(0, request.terminationGrace.nanoseconds)))
        stdoutBuffer = OutputBuffer(request.stdoutCapture)
        stderrBuffer = OutputBuffer(request.stderrCapture)
    }

    /// Starts the child. Throws only if it could not be started; `completion` runs once, on the
    /// job's queue, when the child is gone and its output has been collected.
    @discardableResult
    static func launch(
        _ request: SubprocessRequest,
        onOutput: (@Sendable (Data, SubprocessOutputSource) -> Void)?,
        completion: @escaping @Sendable (SubprocessResult) -> Void
    ) throws -> SubprocessJob {
        let spawned = try Subprocess.spawn(request)
        let job = SubprocessJob(request: request, spawned: spawned, onOutput: onOutput)
        job.begin(completion: completion)
        return job
    }

    private func begin(completion: @escaping @Sendable (SubprocessResult) -> Void) {
        self.completion = completion
        queue.sync {
            stdoutReader = PipeReader(fd: spawned.stdoutFD, queue: queue) { [self] data in
                stdoutBuffer.append(data)
                onOutput?(data, .stdout)
            }
            if let fd = spawned.stderrFD {
                stderrReader = PipeReader(fd: fd, queue: queue) { [self] data in
                    stderrBuffer.append(data)
                    onOutput?(data, .stderr)
                }
            }
            if let fd = spawned.stdinFD, case .data(let data) = request.standardInput {
                if data.isEmpty { close(fd) } else { stdinWriter = PipeWriter(fd: fd, data: data, queue: queue) }
            }
            if let timeout = request.timeout {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .nanoseconds(Int(clamping: max(0, timeout.nanoseconds))))
                timer.setEventHandler { [self] in terminate(.timedOut) }
                timer.resume()
                self.timer = timer
            }
        }
        let thread = Thread { [self] in waitForExit() }
        thread.name = "SubprocessKit.wait"
        thread.start()
    }

    /// Stops the child as a cancellation does. A no-op once it has exited.
    func cancel() { terminate(.cancelled) }

    // MARK: - Exit

    /// Waits for the child without reaping it, so its pid cannot be reused while a signal might
    /// still be sent to it; then marks it reaped under the lock and reaps it.
    private func waitForExit() {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
        lock.lock()
        reaped = true
        lock.unlock()

        var status: Int32 = 0
        var waited = waitpid(pid, &status, 0)
        while waited < 0, errno == EINTR { waited = waitpid(pid, &status, 0) }
        if waited >= 0 {
            // WIFEXITED / WEXITSTATUS / WTERMSIG written out: the macros are not imported.
            let signal = status & 0x7f
            exit = signal == 0
                ? SubprocessExit(exitCode: (status >> 8) & 0xff, signal: nil)
                : SubprocessExit(exitCode: nil, signal: signal)
        }
        if request.processGroup, request.killGroupOnExit { killGroupAfterExit() }
        queue.async { [self] in finish() }
    }

    /// On the queue, after the child exited: take what is left in the pipes, then report.
    private func finish() {
        stdoutReader?.finish()
        stderrReader?.finish()
        stdinWriter?.cancel()
        timer?.cancel()
        timer = nil
        let (timedOut, cancelled): (Bool, Bool) = lock.withLock { (reason == .timedOut, reason == .cancelled) }
        let result = SubprocessResult(
            exit: exit, stdout: stdoutBuffer.captured, stderr: stderrBuffer.captured,
            timedOut: timedOut, cancelled: cancelled, duration: Date().timeIntervalSince(started))
        let completion = completion
        self.completion = nil
        completion?(result)
    }

    // MARK: - Signals

    private func terminate(_ why: Reason) {
        lock.lock()
        defer { lock.unlock() }
        // Under the lock, so the child cannot be reaped (and its pid reused) between check and kill.
        guard !reaped else { return }
        if reason == nil { reason = why }
        if grace == .nanoseconds(0) {
            signal(SIGKILL)
        } else {
            signal(SIGTERM)
            queue.asyncAfter(deadline: .now() + grace) { [self] in
                lock.withLock {
                    // A group can outlive its leader; a lone leader that is gone needs nothing.
                    if request.processGroup || !reaped { signal(SIGKILL) }
                }
            }
        }
    }

    private func killGroupAfterExit() {
        if grace == .nanoseconds(0) {
            kill(-pid, SIGKILL)
        } else {
            kill(-pid, SIGTERM)
            queue.asyncAfter(deadline: .now() + grace) { [pid] in kill(-pid, SIGKILL) }
        }
    }

    /// To the whole group when the child leads one, else to the child alone. Call with `lock` held.
    private func signal(_ signal: Int32) {
        kill(request.processGroup ? -pid : pid, signal)
    }
}

extension Duration {
    /// Whole nanoseconds, saturating.
    fileprivate var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return seconds < 0 ? Int64.min : Int64.max }
        return scaled &+ attoseconds / 1_000_000_000
    }
}
