import AppKit
import JavaIntelligence
import XCTest
@testable import Umbra

/// `IDEGradleConsoleView` draws a log that drops its oldest lines once it holds `maxLines`. The
/// view must follow line numbers, not positions in the log, or it stops drawing when the log is full.
@MainActor
final class IDEGradleConsoleViewTests: XCTestCase {
    private var textView: NSTextView!
    private var coordinator: IDEGradleConsoleView.Coordinator!

    override func setUp() {
        textView = NSTextView()
        coordinator = IDEGradleConsoleView.Coordinator()
        coordinator.textView = textView
    }

    private func render(_ log: IDEGradleConsoleLog) {
        coordinator.render(log, fontName: "Menlo", fontSize: 12, fullReplace: coordinator.lastRunID != log.runID)
    }

    private func append(_ log: inout IDEGradleConsoleLog, _ range: Range<Int>) {
        for index in range { log.appendProcessLine(GradleOutputLine(stream: .stdout, text: "line \(index)")) }
    }

    /// The text's lines without the empty one after the final newline.
    private var shown: [String] {
        var lines = textView.string.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    func testRendersLinesInOrderAndAppendsOnlyTheNewOnes() {
        var log = IDEGradleConsoleLog()
        log.reset()
        append(&log, 0..<3)
        render(log)
        XCTAssertEqual(shown, ["line 0", "line 1", "line 2"])
        append(&log, 3..<5)
        render(log)
        XCTAssertEqual(shown, (0..<5).map { "line \($0)" })
    }

    func testNotesAndProcessLinesShareTheText() {
        var log = IDEGradleConsoleLog()
        log.reset()
        log.appendNote("Project: /tmp/app")
        append(&log, 0..<1)
        render(log)
        XCTAssertEqual(shown, ["Project: /tmp/app", "line 0"])
    }

    func testLinesKeepAppearingAfterTheLogIsFull() {
        var log = IDEGradleConsoleLog()
        log.reset()
        append(&log, 0..<IDEGradleConsoleLog.maxLines)
        render(log)
        XCTAssertEqual(shown.count, IDEGradleConsoleLog.maxLines)

        append(&log, IDEGradleConsoleLog.maxLines..<(IDEGradleConsoleLog.maxLines + 5))
        render(log)

        XCTAssertEqual(shown.first, "… 5 earlier lines not shown")
        XCTAssertEqual(shown.last, "line \(IDEGradleConsoleLog.maxLines + 4)", "The newest line is drawn: a position-based view stopped here")
        XCTAssertEqual(shown[1], "line 5", "The five oldest lines are gone from the text too")
        XCTAssertEqual(shown.count, IDEGradleConsoleLog.maxLines + 1, "The text stays bounded: the log's lines plus the notice")
    }

    func testEveryUpdateWhileFullDrawsExactlyTheNewLine() {
        var log = IDEGradleConsoleLog()
        log.reset()
        append(&log, 0..<IDEGradleConsoleLog.maxLines)
        render(log)
        for index in IDEGradleConsoleLog.maxLines..<(IDEGradleConsoleLog.maxLines + 30) {
            append(&log, index..<(index + 1))
            render(log)
            XCTAssertEqual(shown.last, "line \(index)")
        }
        XCTAssertEqual(shown.first, "… 30 earlier lines not shown")
        XCTAssertEqual(shown.filter { $0 == "line \(IDEGradleConsoleLog.maxLines + 10)" }.count, 1, "Nothing is drawn twice")
    }

    func testAViewThatFellFarBehindSkipsWhatWasDroppedUnseen() {
        var log = IDEGradleConsoleLog()
        log.reset()
        append(&log, 0..<100)
        render(log)

        // Far more than the log holds arrives before the next redraw.
        let total = 100 + IDEGradleConsoleLog.maxLines + 2_500
        append(&log, 100..<total)
        render(log)

        XCTAssertEqual(shown.first, "… \(total - IDEGradleConsoleLog.maxLines) earlier lines not shown")
        XCTAssertEqual(shown[1], "line \(total - IDEGradleConsoleLog.maxLines)", "Continues from the log's oldest line: none repeated, none out of order")
        XCTAssertEqual(shown.last, "line \(total - 1)")
        XCTAssertEqual(shown.count, IDEGradleConsoleLog.maxLines + 1)
        XCTAssertEqual(Set(shown).count, shown.count, "No line twice")
    }

    func testAResetStartsANewText() {
        var log = IDEGradleConsoleLog()
        log.reset()
        append(&log, 0..<(IDEGradleConsoleLog.maxLines + 10))
        render(log)
        log.reset()
        append(&log, 0..<2)
        render(log)
        XCTAssertEqual(shown, ["line 0", "line 1"], "No notice or lines from the last run")
    }

    func testAViewOpenedOnAnAlreadyLongRunShowsTheKeptLines() {
        var log = IDEGradleConsoleLog()
        log.reset()
        append(&log, 0..<(IDEGradleConsoleLog.maxLines + 40))
        render(log)
        XCTAssertEqual(shown.first, "… 40 earlier lines not shown")
        XCTAssertEqual(shown[1], "line 40")
        XCTAssertEqual(shown.last, "line \(IDEGradleConsoleLog.maxLines + 39)")
    }
}
