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

    public var errorDescription: String? {
        switch self {
        case .gitNotFound: return "git was not found at /usr/bin/git."
        case .notARepository: return "This folder is not a git repository."
        case .invalidBranchName: return "Enter a valid branch name."
        case .failed(let status, let stderr, _):
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "git exited with status \(status)." : message
        }
    }
}

public protocol GitRunning: Sendable {
    func run(_ arguments: [String], in directory: URL, stdin: Data?, environment: [String: String]?) async throws -> GitOutput
}

public extension GitRunning {
    func run(_ arguments: [String], in directory: URL) async throws -> GitOutput {
        try await run(arguments, in: directory, stdin: nil, environment: nil)
    }
}

/// Runs `/usr/bin/git` through SubprocessKit. Both output pipes are drained concurrently, so large
/// `log`/`blame` output cannot fill one while the other is being read, and a cancelled `Task` ends
/// the process.
public struct SystemGitRunner: GitRunning {
    public static let executablePath = "/usr/bin/git"

    public init() {}

    public func run(_ arguments: [String], in directory: URL, stdin: Data?, environment: [String: String]?) async throws -> GitOutput {
        guard FileManager.default.isExecutableFile(atPath: Self.executablePath) else { throw GitError.gitNotFound }
        var request = SubprocessRequest(executable: Self.executablePath, arguments: ["-c", "core.quotepath=off"] + arguments)
        request.workingDirectory = directory
        if let environment {
            request.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let stdin { request.standardInput = .data(stdin) }

        let result = try await SubprocessRunner.run(request)
        let err = String(decoding: result.stderr.data, as: UTF8.self)
        guard result.exit.succeeded else {
            throw GitError.failed(status: result.exit.status, stderr: err, stdout: result.stdout.data)
        }
        return GitOutput(stdout: result.stdout.data, stderr: err)
    }
}
