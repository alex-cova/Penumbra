import Foundation
import XCTest
@testable import GitIntelligence

/// `SystemGitRunner` itself, against the real `/usr/bin/git`: the integration suites test it only
/// through `GitRepository`.
final class SystemGitRunnerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // Not inside any repository, so `git` has no work tree to find.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStandardInputReachesGit() async throws {
        // `git hash-object --stdin` hashes what it is given: the blob id of "hello\n" is fixed.
        let output = try await SystemGitRunner().run(
            ["hash-object", "--stdin"], in: directory, stdin: Data("hello\n".utf8), environment: nil)
        XCTAssertEqual(output.text.trimmingCharacters(in: .whitespacesAndNewlines), "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    func testANonZeroExitIsGitErrorFailedWithItsStderrAndStatus() async throws {
        do {
            _ = try await SystemGitRunner().run(["rev-parse", "--git-dir"], in: directory)
            XCTFail("expected a failure outside a repository")
        } catch GitError.failed(let status, let stderr, _) {
            XCTAssertEqual(status, 128)
            XCTAssertTrue(stderr.contains("not a git repository"), stderr)
        }
    }

    func testTheEnvironmentIsMergedOverTheInheritedOne() async throws {
        // PATH must survive (git is found and runs its helpers), while the override is seen by git.
        let output = try await SystemGitRunner().run(
            ["var", "GIT_AUTHOR_IDENT"], in: directory, stdin: nil,
            environment: ["GIT_AUTHOR_NAME": "Runner Test", "GIT_AUTHOR_EMAIL": "runner@example.com"])
        XCTAssertTrue(output.text.hasPrefix("Runner Test <runner@example.com>"), output.text)
    }

    func testQuotePathIsOffSoNonASCIINamesAreNotEscaped() async throws {
        let run = SystemGitRunner()
        _ = try await run.run(["init", "-q"], in: directory)
        try "x".write(to: directory.appendingPathComponent("café.txt"), atomically: true, encoding: .utf8)
        let output = try await run.run(["status", "--porcelain"], in: directory)
        XCTAssertTrue(output.text.contains("café.txt"), output.text)
    }

    func testALargeResultIsReadWhileStderrIsAlsoOpen() async throws {
        let run = SystemGitRunner()
        _ = try await run.run(["init", "-q"], in: directory)
        let names = (0..<4_000).map { "file-with-a-fairly-long-name-\($0).txt" }
        for name in names { FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil) }
        let output = try await run.run(["status", "--porcelain", "-uall"], in: directory)
        XCTAssertGreaterThan(output.stdout.count, 64 * 1_024, "more than a pipe holds")
        XCTAssertEqual(output.text.split(separator: "\n").count, names.count)
    }

    func testCancellingTheTaskEndsTheRunInsteadOfWaitingForGit() async throws {
        // A hook-free way to make git wait: read a blob from a FIFO nobody writes to.
        let fifo = directory.appendingPathComponent("blocked")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let workDirectory = directory!
        let task = Task { try await SystemGitRunner().run(["hash-object", fifo.path], in: workDirectory) }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run must not report success")
        } catch GitError.failed {
            // The process was terminated: git exits through a signal, which is a failed status.
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // MARK: - Observer and progress

    private final class Recorder: GitCommandObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [GitCommandRecord] = []
        var records: [GitCommandRecord] { lock.withLock { stored } }
        func gitCommandFinished(_ record: GitCommandRecord) { lock.withLock { stored.append(record) } }
    }

    func testTheObserverSeesSuccessAndFailure() async throws {
        let recorder = Recorder()
        let run = SystemGitRunner(observer: recorder)
        _ = try await run.run(["init", "-q"], in: directory)
        _ = try? await run.run(["rev-parse", "--verify", "refs/heads/nope"], in: directory)

        let records = recorder.records
        XCTAssertEqual(records.map { $0.arguments.first }, ["init", "rev-parse"])
        XCTAssertTrue(records[0].succeeded)
        XCTAssertFalse(records[1].succeeded)
        XCTAssertEqual(records[1].directory, directory)
        XCTAssertGreaterThanOrEqual(records[1].duration, 0)
    }

    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [GitProgress] = []
        var values: [GitProgress] { lock.withLock { stored } }
        func add(_ value: GitProgress) { lock.withLock { stored.append(value) } }
    }

    func testProgressLinesFromStderrReachTheHandler() async throws {
        let run = SystemGitRunner()
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try await run.run(["init", "-q", "-b", "main"], in: source)
        for (key, value) in [("user.name", "T"), ("user.email", "t@example.com"), ("commit.gpgsign", "false")] {
            _ = try await run.run(["config", key, value], in: source)
        }
        try "x\n".write(to: source.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await run.run(["add", "a.txt"], in: source)
        _ = try await run.run(["commit", "-q", "-m", "x"], in: source)

        let box = ProgressBox()
        // `--progress` forces the lines that git hides when stderr is not a terminal.
        _ = try await run.run(
            ["clone", "--progress", "--no-local", source.path, directory.appendingPathComponent("copy").path],
            in: directory, stdin: nil, environment: nil, onProgress: { box.add($0) })

        XCTAssertFalse(box.values.isEmpty, "clone --progress writes to stderr")
        XCTAssertTrue(box.values.contains { $0.text.contains("Cloning into") })
    }
}
