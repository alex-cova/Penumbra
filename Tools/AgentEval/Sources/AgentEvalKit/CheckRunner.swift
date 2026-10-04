import Darwin
import Foundation

public struct CheckResult: Codable, Sendable, Equatable {
    public var exitCode: Int32
    /// The end of the output: a test run's verdict is at the bottom.
    public var output: String
    public var timedOut: Bool
    public var seconds: Double

    public var passed: Bool { exitCode == 0 && !timedOut }
}

/// Runs a task's check command. This is the evaluator's own shell use (a development tool, not part
/// of the editor); the agent never gets a shell, only `run_tests`, which calls this with the task's
/// fixed command.
public enum CheckRunner {
    public static let maxOutputBytes = 12_000

    public static func run(_ command: String, in directory: URL, timeout: TimeInterval) async -> CheckResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: runBlocking(command, in: directory, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ command: String, in directory: URL, timeout: TimeInterval) -> CheckResult {
        let started = Date()
        var pipeEnds: [Int32] = [0, 0]
        guard pipe(&pipeEnds) == 0 else { return CheckResult(exitCode: -1, output: "pipe failed", timedOut: false, seconds: 0) }
        let readEnd = pipeEnds[0], writeEnd = pipeEnds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group, so a timeout kills the tests and anything they started.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        let arguments = ["/bin/sh", "-c", command]
        var pid: pid_t = 0
        let status = withCStrings(arguments) { argv in
            withCStrings(environment.map { "\($0.key)=\($0.value)" }) { envp in
                posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
            }
        }
        close(writeEnd)
        guard status == 0 else {
            close(readEnd)
            return CheckResult(exitCode: -1, output: "could not start the check: error \(status)", timedOut: false, seconds: 0)
        }

        let timedOut = Atomic(false)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if finished.wait(timeout: .now()) == .timedOut {
                timedOut.set(true)
                killpg(pid, SIGKILL)
            }
        }

        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = read(readEnd, &buffer, buffer.count)
            if count <= 0 { break }
            collected.append(contentsOf: buffer[0..<count])
            if collected.count > maxOutputBytes * 8 { collected = collected.suffix(maxOutputBytes * 4) }
        }
        close(readEnd)
        var waitStatus: Int32 = 0
        waitpid(pid, &waitStatus, 0)
        finished.signal()
        // Anything the check left running in its group goes with it.
        killpg(pid, SIGKILL)

        let exit: Int32
        if (waitStatus & 0x7f) == 0 { exit = (waitStatus >> 8) & 0xff } else { exit = 128 + (waitStatus & 0x7f) }
        var text = String(decoding: collected, as: UTF8.self)
        if text.utf8.count > maxOutputBytes { text = "[… earlier output not shown …]\n" + String(decoding: text.utf8.suffix(maxOutputBytes), as: UTF8.self) }
        return CheckResult(exitCode: timedOut.value ? 124 : exit, output: text, timedOut: timedOut.value, seconds: Date().timeIntervalSince(started))
    }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

final class Atomic<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ newValue: Value) { lock.lock(); stored = newValue; lock.unlock() }
    func update(_ body: (inout Value) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}

extension Atomic where Value == Int {
    func increment() { update { $0 += 1 } }
}
