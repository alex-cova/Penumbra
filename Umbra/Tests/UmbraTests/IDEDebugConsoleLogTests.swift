import XCTest
@testable import Umbra

@MainActor
final class IDEDebugConsoleLogTests: XCTestCase {
    private func text(_ log: IDEDebugConsoleLog) -> String {
        log.chunks.map { $0.endsLine ? $0.text + "\n" : $0.text }.joined()
    }

    func testCompleteLinesEndTheirLine() {
        let log = IDEDebugConsoleLog()
        log.append(stream: .out, text: "one", partial: false)
        log.append(stream: .err, text: "two", partial: false)
        XCTAssertEqual(text(log), "one\ntwo\n")
        XCTAssertEqual(log.chunks.map(\.stream), [.out, .err])
    }

    func testAPartialLineIsContinuedByTheNextChunkOfTheSameStream() {
        let log = IDEDebugConsoleLog()
        log.append(stream: .out, text: "Enter name: ", partial: true)
        log.append(stream: .out, text: "Ada", partial: false)
        XCTAssertEqual(text(log), "Enter name: Ada\n")
    }

    func testAnotherStreamClosesAnOpenLineSoTheyNeverShareOne() {
        let log = IDEDebugConsoleLog()
        log.append(stream: .out, text: "Enter name: ", partial: true)
        log.append(stream: .err, text: "warning", partial: false)
        log.append(stream: .out, text: "done", partial: false)
        XCTAssertEqual(text(log), "Enter name: \nwarning\ndone\n")
        XCTAssertEqual(log.chunks.first?.stream, .out)
        XCTAssertEqual(log.chunks[1].stream, .out, "The closing break belongs to the line it closes")
    }

    func testANoteClosesAnOpenLine() {
        let log = IDEDebugConsoleLog()
        log.append(stream: .out, text: "prompt", partial: true)
        log.appendNote("Process finished with exit code 1")
        XCTAssertEqual(text(log), "prompt\nProcess finished with exit code 1\n")
    }

    func testAnEmptyLineIsALine() {
        let log = IDEDebugConsoleLog()
        log.append(stream: .out, text: "", partial: false)
        XCTAssertEqual(text(log), "\n")
    }

    func testSequencesFollowTheDroppedCountWhenOldChunksAreTrimmed() {
        let log = IDEDebugConsoleLog()
        let total = IDEDebugConsoleLog.maxChunks + IDEDebugConsoleLog.trimSlack + 10
        for index in 0..<total { log.append(stream: .out, text: "line \(index)", partial: false) }
        XCTAssertLessThanOrEqual(log.chunks.count, IDEDebugConsoleLog.maxChunks + IDEDebugConsoleLog.trimSlack)
        XCTAssertGreaterThan(log.droppedCount, 0)
        XCTAssertEqual(log.chunks.first?.sequence, log.droppedCount)
        XCTAssertEqual(log.chunks.last?.text, "line \(total - 1)")
        XCTAssertEqual(log.chunks.last?.sequence, total - 1)
    }

    func testResetStartsANewRun() {
        let log = IDEDebugConsoleLog()
        let run = log.runID
        log.append(stream: .out, text: "old", partial: true)
        log.reset()
        XCTAssertTrue(log.isEmpty)
        XCTAssertNotEqual(log.runID, run)
        log.append(stream: .out, text: "new", partial: false)
        XCTAssertEqual(text(log), "new\n", "An open line from the last run is not continued")
        XCTAssertEqual(log.chunks.first?.sequence, 0)
    }

    func testUnreadTracksNewOutputUntilItIsRead() {
        let log = IDEDebugConsoleLog()
        XCTAssertFalse(log.hasUnread)
        log.append(stream: .out, text: "x", partial: false)
        XCTAssertTrue(log.hasUnread)
        log.markRead()
        XCTAssertFalse(log.hasUnread)
        log.appendNote("y")
        XCTAssertTrue(log.hasUnread)
    }
}
