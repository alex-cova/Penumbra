import Foundation
import XCTest
@testable import SubprocessKit

final class TerminationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var pidFile: URL { directory.appendingPathComponent("child.pid") }

    func testATimeoutKillsTheChildAndSaysSo() async throws {
        var request = SubprocessRequest(executable: "/bin/sleep", arguments: ["30"])
        request.timeout = .milliseconds(300)
        let started = Date()
        let result = try await SubprocessRunner.run(request)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.exit.signal, SIGTERM)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testTheTimeoutKeepsWhatWasPrintedBeforeIt() async throws {
        var request = shell("echo before; sleep 30")
        request.timeout = .milliseconds(500)
        let result = try await SubprocessRunner.run(request)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.stdout.text, "before\n")
    }

    func testCancellingTheTaskStopsTheChildAndSaysSo() async throws {
        let request = SubprocessRequest(executable: "/bin/sleep", arguments: ["30"])
        let started = Date()
        let task = Task { try await SubprocessRunner.run(request) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testATaskCancelledBeforeItStartsStillEndsTheChild() async throws {
        let request = SubprocessRequest(executable: "/bin/sleep", arguments: ["30"])
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await SubprocessRunner.run(request)
        }
        task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.cancelled)
    }

    func testAChildThatIgnoresSIGTERMIsKilledAfterTheGracePeriod() async throws {
        var request = shell("trap '' TERM; while :; do sleep 0.1; done")
        request.timeout = .milliseconds(300)
        request.terminationGrace = .milliseconds(500)
        let started = Date()
        let result = try await SubprocessRunner.run(request)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exit.signal, SIGKILL)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.7)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testAZeroGraceSendsSIGKILLAtOnce() async throws {
        var request = shell("trap '' TERM; while :; do sleep 0.1; done")
        request.timeout = .milliseconds(300)
        request.terminationGrace = .zero
        let result = try await SubprocessRunner.run(request)
        XCTAssertEqual(result.exit.signal, SIGKILL)
    }

    func testAProcessGroupTimeoutKillsTheWholeTree() async throws {
        var request = shell("sleep 300 & echo $! > '\(pidFile.path)'; wait")
        request.processGroup = true
        request.timeout = .seconds(1)
        let result = try await SubprocessRunner.run(request)
        XCTAssertTrue(result.timedOut)
        let child = try await readPID(pidFile)
        let gone = await waitUntilGone(child)
        XCTAssertTrue(gone, "the grandchild must die with the group")
    }

    func testCancellingAProcessGroupStopsTheWholeTree() async throws {
        var request = shell("sleep 300 & echo $! > '\(pidFile.path)'; wait")
        request.processGroup = true
        let task = Task { [request] in try await SubprocessRunner.run(request) }
        let child = try await readPID(pidFile)
        task.cancel()
        let result = try await task.value
        XCTAssertTrue(result.cancelled)
        let gone = await waitUntilGone(child)
        XCTAssertTrue(gone)
    }

    func testWithoutAProcessGroupOnlyTheLeaderIsSignalled() async throws {
        // `sh -c 'sleep 300 & wait'`: the leader dies on SIGTERM, its background child does not.
        var request = shell("sleep 300 & echo $! > '\(pidFile.path)'; wait")
        request.timeout = .seconds(1)
        let result = try await SubprocessRunner.run(request)
        XCTAssertTrue(result.timedOut)
        let child = try await readPID(pidFile)
        defer { kill(child, SIGKILL) }
        XCTAssertTrue(isAlive(child), "a leader-only kill must leave the grandchild alone")
    }

    func testResultsDoNotWaitForAGrandchildThatKeepsThePipeOpen() async throws {
        var request = shell("(sleep 30 &) ; echo done")
        request.timeout = .seconds(20)
        let started = Date()
        let result = try await SubprocessRunner.run(request)
        XCTAssertEqual(result.stdout.text, "done\n")
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        // Not in a group, so nothing ended it: clean up the straggler.
        _ = try? await SubprocessRunner.run(shell("pkill -f 'sleep 30' || true"))
    }

    func testKillGroupOnExitEndsWhatTheLeaderLeftBehind() async throws {
        var request = shell("(sleep 300 &) ; sleep 0.2; pgrep -n -x sleep > '\(pidFile.path)'; echo done")
        request.processGroup = true
        request.killGroupOnExit = true
        request.terminationGrace = .milliseconds(500)
        let result = try await SubprocessRunner.run(request)
        XCTAssertEqual(result.exit.exitCode, 0)
        let child = try await readPID(pidFile)
        let gone = await waitUntilGone(child)
        XCTAssertTrue(gone, "a background process must not outlive the command")
    }

    func testTheBlockingRunnerHonoursTheTimeout() throws {
        var request = SubprocessRequest(executable: "/bin/sleep", arguments: ["30"])
        request.timeout = .milliseconds(300)
        let result = try SubprocessRunner.runBlocking(request)
        XCTAssertTrue(result.timedOut)
    }
}
