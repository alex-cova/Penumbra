import Foundation
import SubprocessKit

public struct GitOutput: Sendable {
    public let stdout: Data
    public let stderr: String

    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

public enum GitError: Error, Sendable, LocalizedError {
    case gitNotFound
    case failed(status: Int32, stderr: String, stdout: Data)
    case notARepository
    case invalidBranchName
    /// A request the caller built wrongly (an empty name, a plan that starts with a squash…).
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .gitNotFound: return "git was not found at /usr/bin/git."
        case .notARepository: return "This folder is not a git repository."
        case .invalidBranchName: return "Enter a valid branch name."
        case .invalidRequest(let message): return message
        case .failed(let status, let stderr, let stdout):
            var message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // `merge` and `rebase` report their conflicts on stdout and leave stderr empty.
            if message.isEmpty { message = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            return message.isEmpty ? "git exited with status \(status)." : message
        }
    }
}

public protocol GitRunning: Sendable {
    /// `onProgress` receives the progress lines git writes to stderr while the command runs. It is
    /// called from a background context, in order.
    func run(
        _ arguments: [String], in directory: URL, stdin: Data?, environment: [String: String]?,
        onProgress: GitProgressHandler?
    ) async throws -> GitOutput
}

public extension GitRunning {
    func run(_ arguments: [String], in directory: URL, stdin: Data?, environment: [String: String]?) async throws -> GitOutput {
        try await run(arguments, in: directory, stdin: stdin, environment: environment, onProgress: nil)
    }

    func run(_ arguments: [String], in directory: URL) async throws -> GitOutput {
        try await run(arguments, in: directory, stdin: nil, environment: nil, onProgress: nil)
    }
}

/// Runs `/usr/bin/git` through SubprocessKit. Both output pipes are drained concurrently, so large
/// `log`/`blame` output cannot fill one while the other is being read, and a cancelled `Task` ends
/// the process.
public struct SystemGitRunner: GitRunning {
    public static let executablePath = "/usr/bin/git"

    private let observer: (any GitCommandObserving)?

    public init(observer: (any GitCommandObserving)? = nil) {
        self.observer = observer
    }

    public func run(
        _ arguments: [String], in directory: URL, stdin: Data?, environment: [String: String]?,
        onProgress: GitProgressHandler?
    ) async throws -> GitOutput {
        guard FileManager.default.isExecutableFile(atPath: Self.executablePath) else { throw GitError.gitNotFound }
        var request = SubprocessRequest(executable: Self.executablePath, arguments: ["-c", "core.quotepath=off"] + arguments)
        request.workingDirectory = directory
        if let environment {
            request.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let stdin { request.standardInput = .data(stdin) }

        var relay: ProgressRelay?
        var onOutput: (@Sendable (Data, SubprocessOutputSource) -> Void)?
        if let onProgress {
            let made = ProgressRelay(onProgress)
            relay = made
            onOutput = { data, source in
                if source == .stderr { made.feed(data) }
            }
        }
        let result = try await SubprocessRunner.run(request, onOutput: onOutput)
        relay?.finish()
        let err = String(decoding: result.stderr.data, as: UTF8.self)
        observer?.gitCommandFinished(GitCommandRecord(
            arguments: arguments, directory: directory, exitStatus: result.exit.status, stderr: err,
            output: String(decoding: result.stdout.data.prefix(4_096), as: UTF8.self),
            duration: result.duration
        ))
        guard result.exit.succeeded else {
            throw GitError.failed(status: result.exit.status, stderr: err, stdout: result.stdout.data)
        }
        return GitOutput(stdout: result.stdout.data, stderr: err)
    }
}

/// Feeds stderr chunks to a `GitProgressParser`. SubprocessKit calls `onOutput` from one serial
/// queue, so the lock only orders it against `finish()` on the caller's task.
private final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = GitProgressParser()
    private let handler: GitProgressHandler

    init(_ handler: @escaping GitProgressHandler) {
        self.handler = handler
    }

    func feed(_ data: Data) {
        let progress = lock.withLock { parser.feed(data) }
        progress.forEach(handler)
    }

    func finish() {
        let progress = lock.withLock { parser.finish() }
        progress.forEach(handler)
    }
}
