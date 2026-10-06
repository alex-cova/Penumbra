import Darwin
import Foundation
import SubprocessKit

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

/// Runs a command in its own process group, so a timeout or Stop ends its children too (killing
/// only the shell leaves them running), and nothing it started outlives it. The spawning, the
/// bounded capture and the kill live in SubprocessKit; this is the agent's policy on top.
nonisolated enum AgentCommandRunner {
    /// Keep the start and the end of the output. A build's verdict is at the bottom, so the tail
    /// gets the larger share.
    static let outputCapture = OutputCapture.bounded(head: 64 * 1_024, tail: 192 * 1_024)

    static func run(_ spec: AgentCommandSpec, onOutput: @escaping @Sendable (String) -> Void) async throws -> AgentCommandResult {
        var request = SubprocessRequest(executable: "/bin/zsh", arguments: ["-c", spec.command])
        request.workingDirectory = spec.workingDirectory
        request.environment = spec.environment
        request.output = .merged
        request.stdoutCapture = outputCapture
        request.processGroup = true
        request.killGroupOnExit = true
        request.timeout = .seconds(spec.timeout)
        request.terminationGrace = .seconds(2)

        let decoder = ChunkTextDecoder()
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(request) { data, _ in
                let text = decoder.feed(data)
                if !text.isEmpty { onOutput(text) }
            }
        } catch let error as SubprocessError {
            switch error {
            case .launchFailed(let code), .pipeFailed(let code):
                throw AgentCommandError.launchFailed(String(cString: strerror(code)))
            }
        }
        let rest = decoder.finish()
        if !rest.isEmpty { onOutput(rest) }

        return AgentCommandResult(
            exitCode: result.exit.exitCode, signal: result.exit.signal,
            output: result.stdout.text, omittedBytes: result.stdout.omittedBytes,
            timedOut: result.timedOut, cancelled: result.cancelled, duration: result.duration)
    }
}

/// `UTF8ChunkDecoder` for a `@Sendable` callback. SubprocessKit calls the output handler one chunk
/// at a time on a single queue, so the lock only makes the hand-over to the caller's thread safe.
private nonisolated final class ChunkTextDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = UTF8ChunkDecoder()

    func feed(_ data: Data) -> String { lock.withLock { decoder.feed(data) } }
    func finish() -> String { lock.withLock { decoder.finish() } }
}
