import Foundation
import XCTest
@testable import SubprocessKit

final class InteractiveInputTests: XCTestCase {
    private func interactive(_ script: String) -> SubprocessRequest {
        var request = shell(script)
        request.standardInput = .interactive
        return request
    }

    private func waitFor(_ chunks: Chunks, containing text: String, seconds: Double = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if chunks.text(.stdout).contains(text) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return chunks.text(.stdout).contains(text)
    }

    func testLinesWrittenLaterReachTheChildWhileItRuns() async throws {
        let chunks = Chunks()
        let handle = try SubprocessRunner.start(interactive("while read line; do echo \"got:$line\"; done")) {
            chunks.append($0, $1)
        }
        handle.write(Data("one\n".utf8))
        let first = await waitFor(chunks, containing: "got:one")
        XCTAssertTrue(first)
        XCTAssertFalse(handle.isFinished, "the child waits for more input")

        handle.write(Data("two\n".utf8))
        let second = await waitFor(chunks, containing: "got:two")
        XCTAssertTrue(second)

        handle.closeInput()
        let result = await handle.result
        XCTAssertEqual(result.exit.exitCode, 0)
        XCTAssertEqual(chunks.text(.stdout), "got:one\ngot:two\n")
        XCTAssertTrue(handle.isFinished)
    }

    func testClosingInputGivesTheChildEndOfFile() async throws {
        let handle = try SubprocessRunner.start(interactive("cat; echo done"))
        handle.write(Data("hello\n".utf8))
        handle.closeInput()
        let result = await handle.result
        XCTAssertEqual(String(decoding: result.stdout.data, as: UTF8.self), "hello\ndone\n")
        XCTAssertEqual(result.exit.exitCode, 0)
    }

    func testEverythingWrittenBeforeCloseIsDeliveredEvenPastThePipeBuffer() async throws {
        let handle = try SubprocessRunner.start(interactive("wc -c"))
        let block = Data(repeating: UInt8(ascii: "x"), count: 200_000)
        handle.write(block)
        handle.write(block)
        handle.closeInput()
        let result = await handle.result
        XCTAssertEqual(String(decoding: result.stdout.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "400000")
    }

    func testWritingAfterTheChildExitedDoesNothing() async throws {
        let handle = try SubprocessRunner.start(interactive("exit 3"))
        let result = await handle.result
        XCTAssertEqual(result.exit.exitCode, 3)
        handle.write(Data("late\n".utf8))
        handle.closeInput()
        handle.terminate()
        XCTAssertTrue(handle.isFinished)
    }

    func testAChildThatStopsReadingDoesNotKillTheCaller() async throws {
        let handle = try SubprocessRunner.start(interactive("exec 0<&-; sleep 0.2; echo ok"))
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<50 { handle.write(Data(repeating: 65, count: 10_000)) }
        let result = await handle.result
        XCTAssertEqual(String(decoding: result.stdout.data, as: UTF8.self), "ok\n")
    }

    func testTerminateStopsAWaitingChild() async throws {
        let handle = try SubprocessRunner.start(interactive("cat"))
        handle.terminate()
        let result = await handle.result
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(isAlive(handle.processIdentifier))
    }

    func testResultCanBeAwaitedByTwoTasks() async throws {
        let handle = try SubprocessRunner.start(interactive("cat"))
        async let a = handle.result
        async let b = handle.result
        try await Task.sleep(for: .milliseconds(50))
        handle.closeInput()
        let (first, second) = await (a, b)
        XCTAssertEqual(first.exit.exitCode, 0)
        XCTAssertEqual(second.exit.exitCode, 0)
    }

    func testAnInteractiveRequestRunThroughRunSeesNoInputUntilItIsStopped() async throws {
        var request = interactive("cat; echo end")
        request.timeout = .milliseconds(200)
        let result = try await SubprocessRunner.run(request)
        XCTAssertTrue(result.timedOut)
    }
}
