import Darwin
import Foundation

/// Owns one PTY master fd and the shell living on its slave side.
///
/// This is the process half of Step 3: spawn with the slave as the
/// controlling terminal (so `isatty`, job control and `SIGWINCH` work —
/// plain pipes break `vim`, `less` and interactive shells), pump master
/// output to ``onOutput``, and report process end exactly once through
/// ``onExit``. Bytes flow into the parser half (`GhosttyVtTerminal`)
/// from `onOutput`.
///
/// Callbacks fire on a private serial queue, never the main thread.
/// Every public method is safe to call from any thread.
final class GhosttyPtyProcess: @unchecked Sendable {
    /// Raw master-side bytes. Fires on the internal I/O queue.
    var onOutput: (@Sendable (Data) -> Void)?
    /// Shell exit code, or `128 + signal` when killed by a signal.
    /// Fires exactly once per started process, on the I/O queue.
    var onExit: (@Sendable (Int32) -> Void)?

    private let lock = NSLock()
    private var masterFD: Int32 = -1
    private var childPid: pid_t = -1
    private var exitFired = false
    /// Size to apply on first output. macOS zeroes t_winsize when the
    /// session-leader child reopens the slave by path (which is also what
    /// acquires the controlling terminal), so the openpty-time size does not
    /// survive spawn. Re-applying on first output is race-free: the child
    /// must have opened the slave to produce output, and nothing reopens it
    /// afterwards.
    private var pendingSizeApply: (cols: Int, rows: Int)?
    /// Set by `terminate()`; makes the monitor tear down instead of reading.
    private var terminating = false
    /// Self-pipe: `terminate()` writes a byte so a monitor blocked in
    /// `poll()` wakes up. Both ends cloexec; owned by the monitor cycle.
    private var wakeupPipe: (read: Int32, write: Int32)?
    private let ioQueue = DispatchQueue(label: "com.umbra.GhosttyPtyProcess.io", qos: .userInitiated)

    deinit {
        // Backstop; callers should invoke terminate() explicitly so exit
        // reporting stays ordered. Safe from any thread: only sets a flag
        // and writes one byte to the pipe.
        initiateTermination()
    }

    /// The shell pid while running, `-1` otherwise. Used to SIGHUP the
    /// shell on close (interactive shells ignore SIGTERM).
    var shellPid: pid_t {
        lock.withLock { childPid }
    }

    var running: Bool {
        lock.withLock { childPid > 0 }
    }

    /// Starts the shell. Idempotent: returns `false` without doing anything
    /// when a process is already running.
    ///
    /// - Parameters:
    ///   - executable: Resolved shell path (e.g. `/bin/zsh`).
    ///   - execName: `argv[0]` (e.g. `-zsh`) so rc files load like Terminal.app.
    ///   - currentDirectory: The shell's starting directory.
    ///   - environment: Merged over the parent environment. `TERM` defaults
    ///     to `xterm-256color`, `COLORTERM` to `truecolor` when absent.
    @discardableResult
    func start(
        executable: String,
        execName: String,
        currentDirectory: String,
        environment: [String: String]? = nil,
        cols: Int = 80,
        rows: Int = 24
    ) -> Bool {
        lock.withLock {
            guard childPid <= 0 else { return false }
            guard let (master, pid) = Self.spawn(
                executable: executable,
                execName: execName,
                currentDirectory: currentDirectory,
                environment: environment,
                cols: cols,
                rows: rows
            ) else { return false }
            masterFD = master
            childPid = pid
            exitFired = false
            terminating = false
            pendingSizeApply = (cols, rows)
            var fds = [Int32](repeating: 0, count: 2)
            let piped = fds.withUnsafeMutableBufferPointer { ptr in
                Darwin.pipe(ptr.baseAddress!)
            }
            guard piped == 0 else {
                Darwin.close(master)
                masterFD = -1
                childPid = -1
                kill(pid, SIGKILL)
                return false
            }
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
            // Non-blocking read end so drainWakeup terminates.
            let flags = fcntl(fds[0], F_GETFL)
            _ = fcntl(fds[0], F_SETFL, flags | O_NONBLOCK)
            wakeupPipe = (fds[0], fds[1])
            startMonitor()
            return true
        }
    }

    /// Sends stdin bytes to the shell.
    func write(_ data: Data) {
        let fd = lock.withLock { masterFD }
        guard fd >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            var base = raw.bindMemory(to: UInt8.self).baseAddress
            var remaining = data.count
            while remaining > 0, let ptr = base {
                let written = Darwin.write(fd, ptr, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                remaining -= written
                base = ptr.advanced(by: written)
            }
        }
    }

    /// Propagates a view resize to the foreground job (`stty size` reflects it).
    func setWindowSize(cols: Int, rows: Int) {
        lock.withLock { pendingSizeApply = (cols, rows) }
        let fd = lock.withLock { masterFD }
        guard fd >= 0 else { return }
        Self.applySize(fd: fd, cols: cols, rows: rows)
        let pgid = lock.withLock { childPid }
        if pgid > 0 { killpg(pgid, SIGWINCH) }
    }

    private static func applySize(fd: Int32, cols: Int, rows: Int) {
        var ws = winsize()
        ws.ws_col = UInt16(clamping: max(cols, 1))
        ws.ws_row = UInt16(clamping: max(rows, 1))
        _ = withUnsafeMutablePointer(to: &ws) { ptr in
            ioctl(fd, TIOCSWINSZ, ptr)
        }
    }

    /// Ends the shell and its foreground jobs. `terminate()` in SwiftTerm
    /// closes the terminal side and sends SIGTERM, which an interactive
    /// shell ignores — SIGHUP is what a closing terminal sends, so the
    /// monitor sends that and then closes the master (the kernel hangup
    /// SIGHUPs the foreground group directly, which is what actually kills
    /// jobs whose shell ignores the first SIGHUP). Safe to call when
    /// nothing is running.
    ///
    /// The monitor owns every fd operation: on Darwin, `close()` blocks
    /// while another thread is inside `read()` on the same fd (the tty
    /// layer serializes them), which deadlocks teardown. So this only
    /// flags and wakes the monitor; the exit callback still fires exactly
    /// once, from the monitor.
    func terminate() {
        initiateTermination()
    }

    private func initiateTermination() {
        lock.withLock { terminating = true }
        let w = lock.withLock { wakeupPipe?.write ?? -1 }
        if w >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(w, &byte, 1)
        }
    }

    // MARK: - Private

    private func startMonitor() {
        ioQueue.async { [weak self] in
            self?.monitorLoop()
        }
    }

    private func monitorLoop() {
        let fd = lock.withLock { masterFD }
        let wake = lock.withLock { wakeupPipe?.read ?? -1 }
        guard fd >= 0, wake >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            var fds = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wake, events: Int16(POLLIN), revents: 0),
            ]
            let ready = fds.withUnsafeMutableBufferPointer { ptr in
                Darwin.poll(ptr.baseAddress, nfds_t(ptr.count), -1)
            }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if fds[1].revents & Int16(POLLIN) != 0 {
                drainWakeup(fd: wake)
                if lock.withLock({ terminating }) {
                    forceTeardown(master: fd)
                    return
                }
            }
            let masterEvents = fds[0].revents
            guard masterEvents & Int16(POLLIN) != 0 else {
                if masterEvents != 0 { break } // ERR/HUP/NVAL: slave side gone.
                continue
            }
            let count = buffer.withUnsafeMutableBufferPointer { ptr in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if count > 0 {
                let pending: (cols: Int, rows: Int)? = lock.withLock {
                    let current = pendingSizeApply
                    pendingSizeApply = nil
                    return current
                }
                if let pending {
                    Self.applySize(fd: fd, cols: pending.cols, rows: pending.rows)
                    let pgid = lock.withLock { childPid }
                    if pgid > 0 { killpg(pgid, SIGWINCH) }
                }
                onOutput?(Data(buffer.prefix(count)))
                continue
            }
            if count < 0, errno == EINTR { continue }
            break // EOF or EIO/EBADF: the slave side is gone.
        }
        naturalReap(master: fd)
    }

    private func drainWakeup(fd: Int32) {
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) > 0 {}
    }

    /// terminate() path: SIGHUP the shell, then close the master so the
    /// kernel hangs up the tty (SIGHUP to the whole foreground group —
    /// this kills jobs a shell-level SIGHUP alone leaves behind), then reap
    /// with SIGKILL escalation so window close never hangs. Runs on the
    /// monitor thread, which is the only thread ever touching these fds.
    private func forceTeardown(master fd: Int32) {
        let pid = lock.withLock { childPid }
        if pid > 0 { kill(pid, SIGHUP) }
        Darwin.close(fd)
        let code = Self.waitForExit(pid: pid)
        closeWakeup()
        finishExit(code: code)
    }

    /// Shell-exited-on-its-own path: reap, close, report.
    private func naturalReap(master fd: Int32) {
        let pid = lock.withLock { childPid }
        let code = Self.waitForExit(pid: pid)
        Darwin.close(fd)
        closeWakeup()
        finishExit(code: code)
    }

    private func closeWakeup() {
        let pipe = lock.withLock { () -> (read: Int32, write: Int32)? in
            defer { wakeupPipe = nil }
            return wakeupPipe
        }
        if let pipe {
            Darwin.close(pipe.read)
            Darwin.close(pipe.write)
        }
    }

    private func finishExit(code: Int32) {
        let shouldFire = lock.withLock { () -> Bool in
            masterFD = -1
            childPid = -1
            pendingSizeApply = nil
            guard !exitFired else { return false }
            exitFired = true
            return true
        }
        if shouldFire { onExit?(code) }
    }

    /// Bounded reap: the shell should die from SIGHUP/tty hangup (or have
    /// exited on its own); escalate to SIGKILL rather than hang teardown.
    private static func waitForExit(pid: pid_t) -> Int32 {
        if pid > 0 {
            var raw: Int32 = 0
            for _ in 0..<20 {
                var check = raw
                let done = waitpid(pid, &check, WNOHANG)
                if done == pid {
                    raw = check
                    break
                }
                if done < 0, errno != EINTR { break }
                usleep(100_000)
            }
            var reaped = raw
            if waitpid(pid, &reaped, WNOHANG) != pid {
                kill(pid, SIGKILL)
                while waitpid(pid, &reaped, 0) < 0, errno == EINTR {}
            }
            raw = reaped
            // waitpid status macros (WIFEXITED et al.) are C macros, not
            // visible to Swift: decode manually. Exited: low 7 bits zero,
            // code in the next 8. Signaled: low 7 bits hold the signal.
            let lowBits = raw & 0x7F
            if lowBits == 0 {
                return (raw >> 8) & 0xFF
            } else if lowBits != 0x7F {
                return 128 + lowBits
            }
        }
        return -1
    }

    private static func spawn(
        executable: String,
        execName: String,
        currentDirectory: String,
        environment: [String: String]?,
        cols: Int,
        rows: Int
    ) -> (master: Int32, pid: pid_t)? {
        var ws = winsize()
        ws.ws_col = UInt16(clamping: max(cols, 1))
        ws.ws_row = UInt16(clamping: max(rows, 1))
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, &ws) == 0 else { return nil }
        // The slave fd is only needed for its device path: the child opens
        // it *after* setsid, which is what makes it the controlling terminal.
        guard let slavePath = ptsname(master).map({ String(cString: $0) }) else {
            Darwin.close(master)
            Darwin.close(slave)
            return nil
        }
        Darwin.close(slave)

        var attrs = posix_spawnattr_t?(nil)
        var actions = posix_spawn_file_actions_t?(nil)
        posix_spawnattr_init(&attrs)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attrs)
            posix_spawn_file_actions_destroy(&actions)
        }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        // Order matters: open the slave while session leader (acquires the
        // controlling terminal), dup onto stdio, then drop the extra fd.
        posix_spawn_file_actions_addclose(&actions, master)
        posix_spawn_file_actions_addopen(&actions, 3, slavePath, O_RDWR, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 3, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, 3, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, 3, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, 3)
        posix_spawn_file_actions_addchdir(&actions, currentDirectory)

        var merged = ProcessInfo.processInfo.environment
        merged["TERM"] = environment?["TERM"] ?? merged["TERM"] ?? "xterm-256color"
        merged["COLORTERM"] = environment?["COLORTERM"] ?? merged["COLORTERM"] ?? "truecolor"
        if let environment {
            for (key, value) in environment { merged[key] = value }
        }
        let envStrings = merged.map { "\($0.key)=\($0.value)" }
        let argv: [String] = [execName]

        var pid = pid_t(-1)
        let spawned: Int32 = envStrings.withCStringArray { envp in
            argv.withCStringArray { argvp in
                posix_spawn(&pid, executable, &actions, &attrs, argvp, envp)
            }
        }
        guard spawned == 0 else {
            Darwin.close(master)
            return nil
        }
        return (master, pid)
    }
}

private extension Array where Element == String {
    /// Calls `body` with a NULL-terminated `char *` array of the elements.
    func withCStringArray<T>(_ body: ([UnsafeMutablePointer<CChar>?]) -> T) -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = map { strdup($0) }
        defer { pointers.forEach { if let p = $0 { free(p) } } }
        pointers.append(nil)
        return body(pointers)
    }
}
