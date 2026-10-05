import Darwin
import Foundation

/// A shell command for the agent: run with `/bin/zsh -c` (not a login shell) in the project, with
/// stdin closed and a built environment rather than the app's own.
nonisolated struct AgentCommandSpec: Sendable {
    var command: String
    var workingDirectory: URL
    var environment: [String: String]
    var timeout: TimeInterval
}

nonisolated struct AgentCommandResult: Sendable, Equatable {
    /// `nil` when the process was killed by a signal.
    var exitCode: Int32?
    var signal: Int32?
    /// stdout and stderr interleaved as they arrived; the middle is dropped past the cap.
    var output: String
    var omittedBytes: Int
    var timedOut: Bool
    var cancelled: Bool
    var duration: TimeInterval
}

nonisolated enum AgentCommandError: Error, LocalizedError, Equatable {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): "The command could not be started: \(detail)"
        }
    }
}

/// What a command's environment holds. Built, not inherited: the app's own environment can carry
/// credentials the user never meant a model-driven command to see.
nonisolated enum AgentCommandEnvironment {
    static let basePath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]

    static func make(
        javaHome: URL?,
        extras: [String: String] = [:],
        home: String = NSHomeDirectory(),
        temporaryDirectory: String = NSTemporaryDirectory()
    ) -> [String: String] {
        var path = basePath
        if let javaHome { path.insert(javaHome.appendingPathComponent("bin").path, at: 0) }
        var environment: [String: String] = [
            "PATH": path.joined(separator: ":"),
            "HOME": home,
            "TMPDIR": temporaryDirectory,
            "LANG": "en_US.UTF-8",
            "TERM": "dumb",
            "NO_COLOR": "1",
        ]
        if let javaHome { environment["JAVA_HOME"] = javaHome.path }
        // Extras win, except that PATH entries are added in front rather than replacing the base.
        for (key, value) in extras {
            environment[key] = key == "PATH" ? value + ":" + (environment["PATH"] ?? "") : value
        }
        return environment
    }
}

/// Keeps the start and the end of what a process printed. A build's verdict is at the bottom, so
/// the tail gets the larger share.
nonisolated struct AgentBoundedOutput: Sendable {
    let headLimit: Int
    let tailLimit: Int
    private(set) var head = Data()
    private(set) var tail = Data()
    private(set) var omitted = 0

    init(headLimit: Int = 64 * 1_024, tailLimit: Int = 192 * 1_024) {
        self.headLimit = headLimit
        self.tailLimit = tailLimit
    }

    mutating func append(_ data: Data) {
        var rest = data[...]
        if head.count < headLimit {
            let room = headLimit - head.count
            head.append(rest.prefix(room))
            rest = rest.dropFirst(room)
        }
        guard !rest.isEmpty else { return }
        tail.append(rest)
        if tail.count > tailLimit {
            let drop = tail.count - tailLimit
            tail.removeFirst(drop)
            omitted += drop
        }
    }

    var text: String {
        let head = String(decoding: head, as: UTF8.self)
        guard omitted > 0 else { return head + String(decoding: tail, as: UTF8.self) }
        return head + "\n[… \(omitted) bytes omitted …]\n" + String(decoding: tail, as: UTF8.self)
    }
}

/// Decodes a byte stream to text without splitting a multi-byte character across two reads.
nonisolated struct AgentUTF8ChunkDecoder {
    private var pending = Data()

    mutating func feed(_ data: Data) -> String {
        pending.append(data)
        // Hold back a trailing incomplete sequence (at most 3 bytes) for the next read.
        var keep = 0
        for back in 1...min(3, pending.count) {
            let byte = pending[pending.count - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue }  // continuation byte: look further back
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if needed > back { keep = back }
            break
        }
        let ready = pending.prefix(pending.count - keep)
        pending = Data(pending.suffix(keep))
        return String(decoding: ready, as: UTF8.self)
    }

    mutating func finish() -> String {
        defer { pending = Data() }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// Runs a command in its own process group, so a timeout or Stop ends its children too (killing
/// only the shell leaves them running), and nothing it started outlives it.
nonisolated enum AgentCommandRunner {
    static func run(_ spec: AgentCommandSpec, onOutput: @escaping @Sendable (String) -> Void) async throws -> AgentCommandResult {
        let process = try AgentProcess.spawn(spec)
        let started = Date()

        let reader = Task.detached {
            await process.drainOutput(onOutput: onOutput)
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(spec.timeout))
            guard !Task.isCancelled else { return }
            process.terminate(.timeout)
        }

        let status = await withTaskCancellationHandler {
            await process.waitForExit()
        } onCancel: {
            process.terminate(.cancelled)
        }
        watchdog.cancel()
        // The leader is gone; whatever it left running goes too, which also closes the pipe.
        process.killGroupAfterExit()
        let (output, omitted) = await reader.value

        let reason = process.terminationReason
        return AgentCommandResult(
            exitCode: status.exitCode, signal: status.signal, output: output, omittedBytes: omitted,
            timedOut: reason == .timeout, cancelled: reason == .cancelled, duration: Date().timeIntervalSince(started))
    }
}

nonisolated final class AgentProcess: @unchecked Sendable {
    enum Reason { case timeout, cancelled }
    struct ExitStatus { var exitCode: Int32?; var signal: Int32? }

    private let pid: pid_t
    private let readFD: Int32
    private let lock = NSLock()
    private var exited = false
    private var reason: Reason?

    private init(pid: pid_t, readFD: Int32) {
        self.pid = pid
        self.readFD = readFD
    }

    var terminationReason: Reason? { lock.withLock { reason } }

    static func spawn(_ spec: AgentCommandSpec) throws -> AgentProcess {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw AgentCommandError.launchFailed(String(cString: strerror(errno))) }

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group (pgid == pid); only the descriptors set up below survive the exec.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addchdir(&actions, spec.workingDirectory.path)

        let arguments = ["/bin/zsh", "-c", spec.command]
        let environment = spec.environment.map { "\($0.key)=\($0.value)" }
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv, envp)
        close(fds[1])
        guard result == 0 else {
            close(fds[0])
            throw AgentCommandError.launchFailed(String(cString: strerror(result)))
        }
        return AgentProcess(pid: pid, readFD: fds[0])
    }

    /// Reads until every writer has closed the pipe. Blocking, so it runs on its own thread.
    func drainOutput(onOutput: @escaping @Sendable (String) -> Void) async -> (String, Int) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [readFD] in
                var bounded = AgentBoundedOutput()
                var decoder = AgentUTF8ChunkDecoder()
                var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
                while true {
                    let count = read(readFD, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    let data = Data(buffer[0..<count])
                    bounded.append(data)
                    let text = decoder.feed(data)
                    if !text.isEmpty { onOutput(text) }
                }
                let rest = decoder.finish()
                if !rest.isEmpty { onOutput(rest) }
                close(readFD)
                continuation.resume(returning: (bounded.text, bounded.omitted))
            }
        }
    }

    func waitForExit() async -> ExitStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                lock.withLock { exited = true }
                // WIFEXITED / WEXITSTATUS / WIFSIGNALED written out: the macros aren't imported.
                let signal = status & 0x7f
                if signal == 0 {
                    continuation.resume(returning: ExitStatus(exitCode: (status >> 8) & 0xff, signal: nil))
                } else {
                    continuation.resume(returning: ExitStatus(exitCode: nil, signal: signal))
                }
            }
        }
    }

    /// SIGTERM to the whole group, SIGKILL two seconds later if anything is still there.
    func terminate(_ why: Reason) {
        lock.lock()
        if reason == nil { reason = why }
        let alreadyGone = exited
        lock.unlock()
        guard !alreadyGone else { return }
        killGroup()
    }

    /// After the leader exits: end whatever it left behind.
    func killGroupAfterExit() { killGroup() }

    private func killGroup() {
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [pid] in kill(-pid, SIGKILL) }
    }
}
