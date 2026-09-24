import Foundation

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

/// Runs `/usr/bin/git`. Reads stdout and stderr concurrently so large `log`/`blame` output cannot
/// fill a pipe while the other one is being drained, and terminates the process on cancellation.
public struct SystemGitRunner: GitRunning {
    public static let executablePath = "/usr/bin/git"

    public init() {}

    public func run(_ arguments: [String], in directory: URL, stdin: Data?, environment: [String: String]?) async throws -> GitOutput {
        guard FileManager.default.isExecutableFile(atPath: Self.executablePath) else { throw GitError.gitNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executablePath)
        process.arguments = ["-c", "core.quotepath=off"] + arguments
        process.currentDirectoryURL = directory
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = stdin == nil ? nil : Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe ?? FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = OutputBox()
                let group = DispatchGroup()
                let queue = DispatchQueue.global(qos: .utility)

                // `waitUntilExit` spins a run loop that can miss the exit of a process that finishes
                // almost immediately (a fast-failing git command), blocking forever; the
                // termination handler is registered before launch, so it cannot be missed.
                let exited = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in exited.signal() }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                group.enter()
                queue.async {
                    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    box.setOut(data)
                    group.leave()
                }
                group.enter()
                queue.async {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    box.setErr(data)
                    group.leave()
                }
                if let stdin, let stdinPipe {
                    queue.async {
                        try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                        try? stdinPipe.fileHandleForWriting.close()
                    }
                }
                queue.async {
                    exited.wait()
                    group.wait()
                    let (out, errData) = box.snapshot()
                    let err = String(decoding: errData, as: UTF8.self)
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: GitOutput(stdout: out, stderr: err))
                    } else {
                        continuation.resume(throwing: GitError.failed(status: process.terminationStatus, stderr: err, stdout: out))
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func setOut(_ data: Data) { lock.lock(); out = data; lock.unlock() }
    func setErr(_ data: Data) { lock.lock(); err = data; lock.unlock() }
    func snapshot() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
}
