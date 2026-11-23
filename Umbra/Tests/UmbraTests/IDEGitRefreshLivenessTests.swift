import Foundation
import GitIntelligence
import XCTest
@testable import Umbra

/// Audit WP4: status must publish while refresh requests keep arriving, and a commit on the same
/// branch must count as HEAD moving.
@MainActor
final class IDEGitRefreshLivenessTests: XCTestCase {
    private var directory: URL!
    private let runner = SystemGitRunner()

    override func setUp() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: SystemGitRunner.executablePath))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-liveness-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "T"], ["config", "user.email", "t@e.com"], ["config", "commit.gpgsign", "false"]] {
            _ = try await runner.run(args, in: directory)
        }
        try "1\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", "a.txt"], in: directory)
        _ = try await runner.run(["commit", "-qm", "base"], in: directory)
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("Timed out waiting for \(description)") }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    // MARK: G-06

    func testStatusPublishesWhileRefreshRequestsKeepArriving() async throws {
        let slow = SlowStatusRunner(delay: .milliseconds(400))
        let model = IDEGitStatusModel(runner: slow)
        model.setRoot(directory)
        try await waitUntil("the first status") { model.workspaceSnapshot != nil }
        var refreshed = 0
        model.onRefreshed = { refreshed += 1 }
        try "new\n".write(to: directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        // A watcher batch every 150 ms for 3 s, each slower pass outlasts the gap between requests.
        var seenDuringBurst = false
        for _ in 0..<20 {
            model.refresh()
            try await Task.sleep(nanoseconds: 150_000_000)
            if model.changes.contains(where: { $0.relativePath == "b.txt" }) { seenDuringBurst = true }
        }
        XCTAssertGreaterThanOrEqual(refreshed, 1, "no status was published while refreshes kept arriving")
        XCTAssertTrue(seenDuringBurst, "the new file was not visible until the burst ended")
    }

    // MARK: G-12

    func testTheIgnoredPassNeverRunsStatusOverIgnoredFiles() async throws {
        try "*.log\nbuild/\n".write(to: directory.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["add", ".gitignore"], in: directory)
        _ = try await runner.run(["commit", "-qm", "ignore"], in: directory)
        try "x".write(to: directory.appendingPathComponent("debug.log"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("build"), withIntermediateDirectories: true)
        try "x".write(to: directory.appendingPathComponent("build/out.o"), atomically: true, encoding: .utf8)
        let recording = HeadRecordingRunner()
        let model = IDEGitStatusModel(runner: recording)
        model.setRoot(directory)
        try await waitUntil("the ignored files to show") {
            model.status(for: self.directory.appendingPathComponent("debug.log"), isDirectory: false) == .ignored
        }
        XCTAssertEqual(model.status(for: directory.appendingPathComponent("build/out.o"), isDirectory: false), .ignored)
        XCTAssertEqual(model.status(for: directory.appendingPathComponent("build"), isDirectory: true), .ignored)
        XCTAssertFalse(
            recording.commands.contains { $0.contains("status") && $0.contains("--ignored") },
            "the ignored pass ran status --ignored: \(recording.commands)"
        )
        XCTAssertTrue(recording.commands.contains { $0.contains("--ignored") && $0.contains("ls-files") })
    }

    // MARK: G-03 / G-23

    func testACommitOnTheSameBranchMovesHeadAndFlushesTheGutterCache() async throws {
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        try await waitUntil("the first status") { model.workspaceSnapshot != nil }
        let controller = IDEChangeMarkerController(defaults: UserDefaults(suiteName: "head-flush-\(UUID().uuidString)")!)
        // The wiring of IDEWorkspace.gitStatus.onRefreshed.
        model.onRefreshed = { if model.headMoved { controller.invalidateHeadCache() } }
        controller.cacheHead(relativePath: "a.txt", data: Data("1\n".utf8))
        XCTAssertEqual(controller.headCacheEntryCount, 1)

        // A refresh with no new commit does not count as HEAD moving.
        model.refresh()
        try await waitUntil("a quiet refresh") { !model.isBusy && model.refreshState.isIdle && !model.headMoved }
        XCTAssertFalse(model.headMoved)
        XCTAssertEqual(controller.headCacheEntryCount, 1)

        try "2\n".write(to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await runner.run(["commit", "-qam", "second on main"], in: directory)
        model.refresh()
        try await waitUntil("HEAD to be seen moving") { model.headMoved }
        XCTAssertEqual(model.currentBranch, "main", "the branch did not change; only its commit did")
        XCTAssertEqual(controller.headCacheEntryCount, 0, "the HEAD blobs must be dropped")

        model.refresh()
        try await waitUntil("headMoved to settle") { !model.headMoved && model.refreshState.isIdle }
    }

    func testARefreshAsksGitForHeadOnce() async throws {
        let recording = HeadRecordingRunner()
        let model = IDEGitStatusModel(runner: recording)
        model.setRoot(directory)
        try await waitUntil("the first status") { model.workspaceSnapshot != nil }
        try await waitUntil("idle") { model.refreshState.isIdle }
        recording.reset()
        model.refresh()
        try await waitUntil("the second status") { recording.commands.contains { $0.contains("status") } }
        try await waitUntil("idle again") { model.refreshState.isIdle }
        let commands = recording.commands
        XCTAssertFalse(commands.contains { $0.contains("symbolic-ref") }, "the branch name comes from .git/HEAD: \(commands)")
        XCTAssertEqual(commands.filter { $0.contains("rev-parse") && $0.contains("--verify") && $0.contains("HEAD") }.count, 1, "\(commands)")
        XCTAssertEqual(model.currentBranch, "main")
    }

    func testADetachedHeadStillShowsTheShortHashAndAnUnbornBranchItsName() async throws {
        let oid = try await runner.run(["rev-parse", "HEAD"], in: directory).text.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await runner.run(["checkout", "-q", "--detach"], in: directory)
        let model = IDEGitStatusModel()
        model.setRoot(directory)
        try await waitUntil("the first status") { model.workspaceSnapshot != nil }
        XCTAssertEqual(model.currentBranch, String(oid.prefix(7)))

        let unborn = FileManager.default.temporaryDirectory.appendingPathComponent("unborn-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unborn) }
        _ = try await runner.run(["init", "-q", "-b", "trunk"], in: unborn)
        let other = IDEGitStatusModel()
        other.setRoot(unborn)
        try await waitUntil("the unborn status") { other.workspaceSnapshot != nil }
        XCTAssertEqual(other.currentBranch, "trunk")
    }
}

private extension GitRefreshState {
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

/// Delays every `status` command, so one pass takes longer than the gap between refresh requests.
private struct SlowStatusRunner: GitRunning {
    let delay: Duration
    private let base = SystemGitRunner()

    func run(_ arguments: [String], in directory: URL, stdin: Data?, environment: [String: String]?, onProgress: GitProgressHandler?) async throws -> GitOutput {
        if arguments.contains("status") { try await Task.sleep(for: delay) }
        return try await base.run(arguments, in: directory, stdin: stdin, environment: environment, onProgress: onProgress)
    }
}

private final class HeadRecordingRunner: GitRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let base = SystemGitRunner()

    var commands: [[String]] { lock.withLock { recorded } }
    func reset() { lock.withLock { recorded = [] } }

    func run(_ arguments: [String], in directory: URL, stdin: Data?, environment: [String: String]?, onProgress: GitProgressHandler?) async throws -> GitOutput {
        lock.withLock { recorded.append(arguments) }
        return try await base.run(arguments, in: directory, stdin: stdin, environment: environment, onProgress: onProgress)
    }
}
