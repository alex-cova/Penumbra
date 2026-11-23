import Foundation
import GitIntelligence
import JavaIntelligence
import XCTest
@testable import Umbra

/// Audit WP7: closing a window must not kill a commit that is running, and a fetch or push must not
/// hold Stage and Commit behind it.
@MainActor
final class IDEGitMutationLifetimeTests: XCTestCase {
    private var base: URL!
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-lifetime-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        directory = base.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@e.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
        try "1\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "a.txt"], in: directory)
        _ = try await runner.run(["commit", "-qm", "base"], in: directory)
        try "2\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    // MARK: G-14

    func testClosingTheWindowDoesNotKillARunningCommit() async throws {
        let hooks = directory.appendingPathComponent(".git/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-commit")
        let started = base.appendingPathComponent("hook-started")
        try "#!/bin/sh\ntouch '\(started.path)'\nsleep 2\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        _ = try await runner.run(["add", "a.txt"], in: directory)

        // The hook is the repository's own: it was trusted, so the gate has nothing to ask.
        let trust = ProjectTrustStore(storeURL: base.appendingPathComponent("trust.json"))
        trust.setTrusted(true, for: directory)
        let model = IDEGitStatusModel(trust: trust)
        model.setRoot(directory)
        try await waitUntil("the first status") { model.workspaceSnapshot != nil }

        model.performCommit(message: "closed while running", options: IDEGitCommitOptions())
        try await waitUntil("the hook to start") { FileManager.default.fileExists(atPath: started.path) }
        model.setRoot(nil)   // what closing the window does
        try await Task.sleep(nanoseconds: 4_000_000_000)

        let subject = try await runner.run(["log", "-1", "--format=%s"], in: directory).text
        XCTAssertEqual(subject.trimmingCharacters(in: .whitespacesAndNewlines), "closed while running")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git/index.lock").path))
    }

    // MARK: G-19

    func testAStageFinishesWhileAFetchIsStillRunning() async throws {
        let blocking = BlockingFetchRunner()
        let model = IDEGitStatusModel(runner: blocking)
        model.setRoot(directory)
        try await waitUntil("the first status") { model.workspaceSnapshot != nil }

        model.fetch()
        try await waitUntil("the fetch to start") { blocking.fetchStarted }
        XCTAssertTrue(model.isNetworkBusy)

        model.stage(paths: [directory.appendingPathComponent("a.txt").path])
        try await waitUntil("the stage", timeout: 5) { model.changes.first?.staged != nil }
        XCTAssertTrue(blocking.fetchStillBlocked, "the stage finished only because the fetch was released")
        XCTAssertTrue(model.isNetworkBusy)
        blocking.release()
        try await waitUntil("the fetch to end") { !model.isNetworkBusy }
    }

    func testCancellingTheNetworkActionStopsItAndNothingElse() async throws {
        let blocking = BlockingFetchRunner()
        let model = IDEGitStatusModel(runner: blocking)
        model.setRoot(directory)
        try await waitUntil("the first status") { model.workspaceSnapshot != nil }
        model.fetch()
        try await waitUntil("the fetch to start") { blocking.fetchStarted }

        model.cancelNetworkActions()
        try await waitUntil("the fetch to stop") { !model.isNetworkBusy }
        XCTAssertTrue(blocking.fetchWasCancelled)
        XCTAssertFalse(model.actionFailed, "a cancelled fetch is not a failure")
    }
}

/// Blocks `fetch` until released or cancelled; everything else runs through real git.
private final class BlockingFetchRunner: GitRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var released = false
    private var cancelled = false
    private let base = SystemGitRunner()

    var fetchStarted: Bool { lock.withLock { started } }
    var fetchStillBlocked: Bool { lock.withLock { started && !released && !cancelled } }
    var fetchWasCancelled: Bool { lock.withLock { cancelled } }
    func release() { lock.withLock { released = true } }

    func run(_ arguments: [String], in directory: URL, stdin: Data?, environment: [String: String]?, onProgress: GitProgressHandler?) async throws -> GitOutput {
        if arguments.contains("fetch") {
            lock.withLock { started = true }
            while !lock.withLock({ released }) {
                if Task.isCancelled {
                    lock.withLock { cancelled = true }
                    throw CancellationError()
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return GitOutput(stdout: Data(), stderr: "")
        }
        return try await base.run(arguments, in: directory, stdin: stdin, environment: environment, onProgress: onProgress)
    }
}
