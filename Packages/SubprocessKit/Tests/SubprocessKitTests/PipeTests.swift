import Foundation
import XCTest
@testable import SubprocessKit

final class PipeTests: XCTestCase {
    func testLargeOutputOnBothStreamsDoesNotDeadlock() async throws {
        // 300 KB on each stream: more than a pipe holds, so the child blocks unless both are drained.
        let script = "head -c 300000 /dev/zero | tr '\\0' 'o'; head -c 300000 /dev/zero | tr '\\0' 'e' >&2; exit 3"
        var request = shell(script)
        request.timeout = .seconds(30)
        let result = try await SubprocessRunner.run(request)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exit.exitCode, 3)
        XCTAssertEqual(result.stdout.data.count, 300_000)
        XCTAssertEqual(result.stderr.data.count, 300_000)
    }

    /// `SystemProcessRunner` used to read stdout to the end and then stderr, which hangs a child
    /// that writes more than a pipe holds to stderr first.
    func testTheBlockingRunnerDrainsStderrWhileReadingStdout() throws {
        var request = shell("head -c 300000 /dev/zero | tr '\\0' 'e' >&2; echo done")
        request.timeout = .seconds(30)
        let result = try SubprocessRunner.runBlocking(request)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.text, "done\n")
        XCTAssertEqual(result.stderr.data.count, 300_000)
    }

    func testStandardInputDataReachesTheChild() async throws {
        var request = SubprocessRequest(executable: "/bin/cat")
        request.standardInput = .data(Data("hello stdin".utf8))
        let result = try await SubprocessRunner.run(request)
        XCTAssertEqual(result.stdout.text, "hello stdin")
    }

    func testStandardInputLargerThanAPipeIsWrittenWhileTheOutputIsRead() async throws {
        let input = Data(repeating: UInt8(ascii: "x"), count: 1_000_000)
        var request = SubprocessRequest(executable: "/bin/cat")
        request.standardInput = .data(input)
        request.timeout = .seconds(30)
        let result = try await SubprocessRunner.run(request)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.data, input)
    }

    func testAChildThatExitsWithoutReadingStandardInputIsNotAnError() async throws {
        // The write hits a closed pipe: that must neither crash the process (SIGPIPE) nor hang.
        for _ in 0..<20 {
            var request = shell("exit 0")
            request.standardInput = .data(Data(repeating: 0x41, count: 4_000_000))
            request.timeout = .seconds(20)
            let result = try await SubprocessRunner.run(request)
            XCTAssertEqual(result.exit.exitCode, 0)
            XCTAssertFalse(result.timedOut)
        }
    }

    func testEmptyStandardInputDataIsEndOfFile() async throws {
        var request = SubprocessRequest(executable: "/bin/cat")
        request.standardInput = .data(Data())
        request.timeout = .seconds(10)
        let result = try await SubprocessRunner.run(request)
        XCTAssertEqual(result.exit.exitCode, 0)
        XCTAssertTrue(result.stdout.isEmpty)
    }

    func testOutputAHandfulOfSpawnsAtOnceStaysSeparate() async throws {
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let result = try await SubprocessRunner.run(shell("sleep 0.05; echo run-\(index)"))
                    return result.stdout.text
                }
            }
            var seen = Set<String>()
            for try await text in group { seen.insert(text) }
            XCTAssertEqual(seen, Set((0..<16).map { "run-\($0)\n" }))
        }
    }

    func testBoundedCaptureKeepsTheHeadAndTheTail() async throws {
        var request = shell("seq 1 400000")
        request.stdoutCapture = .bounded(head: 64 * 1_024, tail: 192 * 1_024)
        let result = try await SubprocessRunner.run(request)
        XCTAssertEqual(result.exit.exitCode, 0)
        XCTAssertTrue(result.stdout.text.hasPrefix("1\n2\n3\n"))
        XCTAssertTrue(result.stdout.text.hasSuffix("399999\n400000\n"))
        XCTAssertGreaterThan(result.stdout.omittedBytes, 0)
        XCTAssertLessThan(result.stdout.data.count, 300_000)
    }

    func testDiscardedOutputStillReachesTheLiveCallback() async throws {
        var request = shell("echo seen")
        request.stdoutCapture = .discard
        let chunks = Chunks()
        let result = try await SubprocessRunner.run(request) { chunks.append($0, $1) }
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(chunks.text(.stdout), "seen\n")
    }
}
