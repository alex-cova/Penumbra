import Foundation
import SubprocessKit

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
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"

        var request = SubprocessRequest(executable: "/bin/sh", arguments: ["-c", command])
        request.workingDirectory = directory
        request.environment = environment
        request.output = .merged
        // A test run's verdict is at the bottom: keep only the end.
        request.stdoutCapture = .bounded(head: 0, tail: maxOutputBytes)
        // Its own process group, so a timeout kills the tests and anything they started, and
        // anything a check left running goes when it ends. SIGKILL at once: nothing to clean up.
        request.processGroup = true
        request.killGroupOnExit = true
        request.timeout = .seconds(timeout)
        request.terminationGrace = .zero

        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(request)
        } catch {
            return CheckResult(exitCode: -1, output: "could not start the check: \(error.localizedDescription)", timedOut: false, seconds: 0)
        }

        var text = result.stdout.text
        if result.stdout.omittedBytes > 0 {
            // `text` already carries a marker line for the dropped part; the tail alone reads better.
            text = "[… earlier output not shown …]\n" + String(decoding: result.stdout.tail, as: UTF8.self)
        }
        let exit: Int32 = result.exit.exitCode ?? 128 + (result.exit.signal ?? 0)
        return CheckResult(exitCode: result.timedOut ? 124 : exit, output: text, timedOut: result.timedOut, seconds: result.duration)
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
