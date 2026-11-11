import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

/// A failed or cancelled status refresh must not look like "this folder is not a repository."
@MainActor
final class IDEGitRefreshTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-refresh-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tester"],
                     ["config", "user.email", "t@example.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testAFailedStatusKeepsTheBranchAndRecovers() async throws {
        try "1\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "a.txt"], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", "add a"], in: directory)
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        try await waitUntil("the repository") { model.currentBranch == "main" }
        let changes = model.changes

        let index = directory.appendingPathComponent(".git/index")
        let saved = try Data(contentsOf: index)
        try Data("not-an-index".utf8).write(to: index)
        model.refresh()
        try await waitUntil("the failure") { model.refreshError != nil }
        XCTAssertEqual(model.currentBranch, "main")
        XCTAssertEqual(model.changes, changes)
        XCTAssertTrue(model.isRepository)
        guard case .failed = model.refreshState else {
            return XCTFail("expected a failed refresh, got \(model.refreshState)")
        }

        try saved.write(to: index)
        model.refresh()
        try await waitUntil("recovery") {
            if case .idle = model.refreshState { return true }
            return false
        }
        XCTAssertEqual(model.currentBranch, "main")
        XCTAssertNil(model.refreshError)
    }

    func testAMissingRepositoryStaysUnavailable() async throws {
        // A folder inside the temp repo would discover that repo. This one is not inside any work tree.
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        let model = IDEGitStatusModel()
        model.setRoot(plain)
        try await waitUntil("discovery to finish") {
            if case .unavailable = model.refreshState { return model.refreshError == nil }
            return false
        }
        XCTAssertFalse(model.isRepository)
        XCTAssertNil(model.currentBranch)
        XCTAssertFalse(IDEGitChrome.isVisible(model.refreshState))
    }

    func testAFirstStatusFailureShowsTheErrorWithoutARepository() async throws {
        let failing = StatusFailingRunner()
        let model = IDEGitStatusModel(runner: failing)
        model.setRoot(directory)
        try await waitUntil("the first failure") {
            if case .failed = model.refreshState { return true }
            return false
        }
        XCTAssertFalse(model.isRepository)
        XCTAssertEqual(model.refreshError, "index is corrupt")
        XCTAssertNil(model.workspaceSnapshot)
        XCTAssertTrue(IDEGitChrome.isVisible(model.refreshState))
        XCTAssertFalse(IDEGitChrome.showsCommitControls(model.refreshState))
        XCTAssertTrue(model.changes.isEmpty)
    }

    func testCancellingARefreshDoesNotPublishAFailure() async throws {
        try "1\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "a.txt"], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", "add a"], in: directory)
        let gate = GatedStatusRunner()
        let model = IDEGitStatusModel(runner: gate)
        model.setRoot(directory)
        try await waitUntil("the repository") { model.currentBranch == "main" }

        gate.setGate(true)
        model.refresh()
        try await waitUntil("status to block") { gate.statusEntries >= 1 }
        model.setRoot(nil)
        gate.setGate(false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(model.refreshError)
        guard case .unavailable = model.refreshState else {
            return XCTFail("closing the project must not become a failed refresh: \(model.refreshState)")
        }
        XCTAssertNil(model.currentBranch)
    }

    func testAStaleStatusDoesNotReplaceANewerEpoch() async throws {
        try "1\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "a.txt"], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", "add a"], in: directory)
        let gate = GatedStatusRunner()
        let model = IDEGitStatusModel(runner: gate)
        model.setRoot(directory)
        try await waitUntil("the repository") { model.currentBranch == "main" }

        gate.setGate(true)
        model.refresh()
        let captured = model.refreshEpoch
        try await waitUntil("the stale status to start") { gate.statusEntries >= 1 }
        model.invalidateForMutation()
        XCTAssertGreaterThan(model.refreshEpoch, captured)
        gate.setGate(false)
        try await waitUntil("the stale load to be dropped") { model.lastDroppedRefreshEpoch == captured }
        try await waitUntil("a current snapshot") {
            if case .idle(let snapshot) = model.refreshState { return snapshot.generation != captured }
            return false
        }
        XCTAssertEqual(model.currentBranch, "main")
        XCTAssertNil(model.refreshError)
    }

    func testTheHotStatusOmitsIgnoredFiles() async throws {
        try "1\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "ignored\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "skip\n".write(to: directory.appendingPathComponent("skip.log"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "a.txt", ".gitignore"], in: directory)
        _ = try await runner.run(["commit", "-q", "-m", "add"], in: directory)
        let recording = RecordingGitRunner()
        let model = IDEGitStatusModel(runner: recording)
        model.setRoot(directory)
        try await waitUntil("the repository") { model.currentBranch == "main" }
        let firstStatus = recording.commands.first { $0.contains("status") }
        XCTAssertNotNil(firstStatus)
        XCTAssertFalse(firstStatus?.contains("--ignored") ?? true, "hot status walked ignored files: \(firstStatus ?? [])")
    }
}

/// Discover succeeds. `git status` fails, so the model never opens a repository.
final class StatusFailingRunner: GitRunning, @unchecked Sendable {
    private let base = SystemGitRunner()

    func run(
        _ arguments: [String], in directory: URL, stdin: Data?, environment: [String: String]?,
        onProgress: GitProgressHandler?
    ) async throws -> GitOutput {
        if arguments.contains("status") {
            throw GitError.failed(status: 128, stderr: "index is corrupt", stdout: Data())
        }
        return try await base.run(arguments, in: directory, stdin: stdin, environment: environment, onProgress: onProgress)
    }
}

/// Blocks in `git status` until `setGate(false)`. Other commands pass through.
final class GatedStatusRunner: GitRunning, @unchecked Sendable {
    private let base = SystemGitRunner()
    private let lock = NSLock()
    private var gate = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entered = 0

    var statusEntries: Int { lock.withLock { entered } }

    func setGate(_ on: Bool) {
        lock.lock()
        gate = on
        let pending = on ? [] : waiters
        if !on { waiters = [] }
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func run(
        _ arguments: [String], in directory: URL, stdin: Data?, environment: [String: String]?,
        onProgress: GitProgressHandler?
    ) async throws -> GitOutput {
        // The slow ignored-file pass also runs `status`. Only the hot refresh (no `--ignored`) is gated.
        let blocked = lock.withLock { gate && arguments.contains("status") && !arguments.contains("--ignored") }
        if blocked {
            lock.withLock { entered += 1 }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = self.lock.withLock { () -> Bool in
                    if !self.gate { return true }
                    self.waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            try Task.checkCancellation()
        }
        return try await base.run(arguments, in: directory, stdin: stdin, environment: environment, onProgress: onProgress)
    }
}

final class RecordingGitRunner: GitRunning, @unchecked Sendable {
    private let base = SystemGitRunner()
    private let lock = NSLock()
    private var recorded: [[String]] = []

    var commands: [[String]] { lock.withLock { recorded } }

    func run(
        _ arguments: [String], in directory: URL, stdin: Data?, environment: [String: String]?,
        onProgress: GitProgressHandler?
    ) async throws -> GitOutput {
        lock.withLock { recorded.append(arguments) }
        return try await base.run(arguments, in: directory, stdin: stdin, environment: environment, onProgress: onProgress)
    }
}
