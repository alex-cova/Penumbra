import Foundation
import XCTest
@testable import SubprocessKit

final class SpawnTests: XCTestCase {
    func testCapturesStdoutAndStderrSeparately() async throws {
        let result = try await SubprocessRunner.run(shell("echo out; echo err 1>&2"))
        XCTAssertEqual(result.exit, SubprocessExit(exitCode: 0, signal: nil))
        XCTAssertEqual(result.stdout.text, "out\n")
        XCTAssertEqual(result.stderr.text, "err\n")
        XCTAssertFalse(result.timedOut || result.cancelled)
    }

    func testMergedOutputInterleavesBothStreamsInOrder() async throws {
        var request = shell("echo one; echo two 1>&2; echo three")
        request.output = .merged
        let result = try await SubprocessRunner.run(request)
        XCTAssertEqual(result.stdout.text, "one\ntwo\nthree\n")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testReportsExitCode() async throws {
        let result = try await SubprocessRunner.run(shell("exit 7"))
        XCTAssertEqual(result.exit, SubprocessExit(exitCode: 7, signal: nil))
        XCTAssertEqual(result.exit.status, 7)
    }

    func testReportsTheSignalAChildDiesFrom() async throws {
        let result = try await SubprocessRunner.run(shell("kill -9 $$"))
        XCTAssertNil(result.exit.exitCode)
        XCTAssertEqual(result.exit.signal, 9)
        XCTAssertEqual(result.exit.status, 9)
    }

    func testArgumentZeroIsTheExecutablePath() async throws {
        let result = try await SubprocessRunner.run(SubprocessRequest(executable: "/bin/sh", arguments: ["-c", "echo $0"]))
        XCTAssertEqual(result.stdout.text, "/bin/sh\n")
    }

    func testRunsInTheWorkingDirectory() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = shell("pwd -P")
        request.workingDirectory = directory
        let result = try await SubprocessRunner.run(request)
        let printed = URL(fileURLWithPath: result.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(printed.resolvingSymlinksInPath().path, directory.resolvingSymlinksInPath().path)
    }

    func testStandardInputIsClosedByDefault() async throws {
        // `cat` with no input only returns promptly if stdin is at EOF, not an open pipe or a terminal.
        var request = SubprocessRequest(executable: "/bin/cat")
        request.timeout = .seconds(10)
        let started = Date()
        let result = try await SubprocessRunner.run(request)
        XCTAssertEqual(result.exit.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(result.stdout.isEmpty)
    }

    func testEnvironmentIsInheritedWhenNil() async throws {
        setenv("SUBPROCESSKIT_TEST_VALUE", "inherited", 1)
        defer { unsetenv("SUBPROCESSKIT_TEST_VALUE") }
        let result = try await SubprocessRunner.run(shell("echo $SUBPROCESSKIT_TEST_VALUE"))
        XCTAssertEqual(result.stdout.text, "inherited\n")
    }

    func testACustomEnvironmentReplacesTheInheritedOne() async throws {
        setenv("SUBPROCESSKIT_TEST_VALUE", "inherited", 1)
        defer { unsetenv("SUBPROCESSKIT_TEST_VALUE") }
        var request = shell("echo [$SUBPROCESSKIT_TEST_VALUE] [$OTHER]")
        request.environment = ["OTHER": "custom"]
        let result = try await SubprocessRunner.run(request)
        XCTAssertEqual(result.stdout.text, "[] [custom]\n")
    }

    func testAMissingExecutableIsALaunchFailure() async {
        do {
            _ = try await SubprocessRunner.run(SubprocessRequest(executable: "/does/not/exist"))
            XCTFail("expected a launch failure")
        } catch {
            XCTAssertEqual(error as? SubprocessError, .launchFailed(errno: ENOENT))
        }
    }

    func testAMissingWorkingDirectoryIsALaunchFailureNotAHang() async {
        var request = shell("echo hi")
        request.workingDirectory = URL(fileURLWithPath: "/does/not/exist")
        do {
            _ = try await SubprocessRunner.run(request)
            XCTFail("expected a launch failure")
        } catch {
            XCTAssertTrue(error is SubprocessError, "\(error)")
        }
    }

    func testLiveOutputArrivesBeforeTheChildEnds() async throws {
        let chunks = Chunks()
        let result = try await SubprocessRunner.run(shell("echo one; sleep 0.3; echo two")) { data, source in
            chunks.append(data, source)
        }
        XCTAssertEqual(chunks.text(.stdout), "one\ntwo\n")
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        XCTAssertEqual(result.stdout.text, "one\ntwo\n")
    }

    func testTheBlockingRunnerReturnsTheSameResult() throws {
        let result = try SubprocessRunner.runBlocking(shell("echo out; echo err 1>&2; exit 3"))
        XCTAssertEqual(result.exit.exitCode, 3)
        XCTAssertEqual(result.stdout.text, "out\n")
        XCTAssertEqual(result.stderr.text, "err\n")
    }

    func testTheBlockingRunnerThrowsLaunchFailures() {
        XCTAssertThrowsError(try SubprocessRunner.runBlocking(SubprocessRequest(executable: "/does/not/exist"))) {
            XCTAssertEqual($0 as? SubprocessError, .launchFailed(errno: ENOENT))
        }
    }

    func testDescriptorsAreNotLeakedAcrossRuns() async throws {
        func openDescriptors() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
        }
        _ = try await SubprocessRunner.run(shell("true"))
        let before = openDescriptors()
        for _ in 0..<50 {
            var request = shell("cat")
            request.standardInput = .data(Data("x".utf8))
            _ = try await SubprocessRunner.run(request)
        }
        XCTAssertLessThanOrEqual(openDescriptors(), before + 2)
    }
}
