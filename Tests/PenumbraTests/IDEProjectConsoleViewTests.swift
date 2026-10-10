import AppKit
import JavaIntelligence
import XCTest
@testable import Umbra

/// `IDEProjectConsoleView` draws a log that drops its oldest lines once it holds `maxLines`. The
/// view must follow line numbers, not positions in the log, or it stops drawing when the log is full.
@MainActor
final class IDEProjectConsoleViewTests: XCTestCase {
    private var textView: NSTextView!
    private var coordinator: IDEProjectConsoleView.Coordinator!

    override func setUp() {
        textView = NSTextView()
        coordinator = IDEProjectConsoleView.Coordinator()
        coordinator.textView = textView
    }

    private func render(_ log: IDEProjectConsoleLog) {
        coordinator.render(log, fontName: "Menlo", fontSize: 12, fullReplace: coordinator.lastRunID != log.runID)
    }

    private func append(_ log: inout IDEProjectConsoleLog, _ range: Range<Int>) {
        for index in range { log.appendProcessLine(GradleOutputLine(stream: .stdout, text: "line \(index)")) }
    }

    /// The text's lines without the empty one after the final newline.
    private var shown: [String] {
        var lines = textView.string.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    func testRendersLinesInOrderAndAppendsOnlyTheNewOnes() {
        var log = IDEProjectConsoleLog()
        log.reset()
        append(&log, 0..<3)
        render(log)
        XCTAssertEqual(shown, ["line 0", "line 1", "line 2"])
        append(&log, 3..<5)
        render(log)
        XCTAssertEqual(shown, (0..<5).map { "line \($0)" })
    }

    func testNotesAndProcessLinesShareTheText() {
        var log = IDEProjectConsoleLog()
        log.reset()
        log.appendNote("Project: /tmp/app")
        append(&log, 0..<1)
        render(log)
        XCTAssertEqual(shown, ["Project: /tmp/app", "line 0"])
    }

    func testLinesKeepAppearingAfterTheLogIsFull() {
        var log = IDEProjectConsoleLog()
        log.reset()
        append(&log, 0..<IDEProjectConsoleLog.maxLines)
        render(log)
        XCTAssertEqual(shown.count, IDEProjectConsoleLog.maxLines)

        append(&log, IDEProjectConsoleLog.maxLines..<(IDEProjectConsoleLog.maxLines + 5))
        render(log)

        XCTAssertEqual(shown.first, "… 5 earlier lines not shown")
        XCTAssertEqual(shown.last, "line \(IDEProjectConsoleLog.maxLines + 4)", "The newest line is drawn: a position-based view stopped here")
        XCTAssertEqual(shown[1], "line 5", "The five oldest lines are gone from the text too")
        XCTAssertEqual(shown.count, IDEProjectConsoleLog.maxLines + 1, "The text stays bounded: the log's lines plus the notice")
    }

    func testEveryUpdateWhileFullDrawsExactlyTheNewLine() {
        var log = IDEProjectConsoleLog()
        log.reset()
        append(&log, 0..<IDEProjectConsoleLog.maxLines)
        render(log)
        for index in IDEProjectConsoleLog.maxLines..<(IDEProjectConsoleLog.maxLines + 30) {
            append(&log, index..<(index + 1))
            render(log)
            XCTAssertEqual(shown.last, "line \(index)")
        }
        XCTAssertEqual(shown.first, "… 30 earlier lines not shown")
        XCTAssertEqual(shown.filter { $0 == "line \(IDEProjectConsoleLog.maxLines + 10)" }.count, 1, "Nothing is drawn twice")
    }

    func testAViewThatFellFarBehindSkipsWhatWasDroppedUnseen() {
        var log = IDEProjectConsoleLog()
        log.reset()
        append(&log, 0..<100)
        render(log)

        // Far more than the log holds arrives before the next redraw.
        let total = 100 + IDEProjectConsoleLog.maxLines + 2_500
        append(&log, 100..<total)
        render(log)

        XCTAssertEqual(shown.first, "… \(total - IDEProjectConsoleLog.maxLines) earlier lines not shown")
        XCTAssertEqual(shown[1], "line \(total - IDEProjectConsoleLog.maxLines)", "Continues from the log's oldest line: none repeated, none out of order")
        XCTAssertEqual(shown.last, "line \(total - 1)")
        XCTAssertEqual(shown.count, IDEProjectConsoleLog.maxLines + 1)
        XCTAssertEqual(Set(shown).count, shown.count, "No line twice")
    }

    func testAResetStartsANewText() {
        var log = IDEProjectConsoleLog()
        log.reset()
        append(&log, 0..<(IDEProjectConsoleLog.maxLines + 10))
        render(log)
        log.reset()
        append(&log, 0..<2)
        render(log)
        XCTAssertEqual(shown, ["line 0", "line 1"], "No notice or lines from the last run")
    }

    func testAViewOpenedOnAnAlreadyLongRunShowsTheKeptLines() {
        var log = IDEProjectConsoleLog()
        log.reset()
        append(&log, 0..<(IDEProjectConsoleLog.maxLines + 40))
        render(log)
        XCTAssertEqual(shown.first, "… 40 earlier lines not shown")
        XCTAssertEqual(shown[1], "line 40")
        XCTAssertEqual(shown.last, "line \(IDEProjectConsoleLog.maxLines + 39)")
    }

    func testCommandCCopiesTheSelectionAndCommandASelectsAll() {
        let view = IDEReadOnlyLogTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        view.string = "hello npm"
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 6, length: 3))

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }

        let copy = keyEvent(keyCode: 8, characters: "c", flags: .command)
        XCTAssertTrue(view.performKeyEquivalent(with: copy))
        XCTAssertEqual(pasteboard.string(forType: .string), "npm")

        let selectAll = keyEvent(keyCode: 0, characters: "a", flags: .command)
        XCTAssertTrue(view.performKeyEquivalent(with: selectAll))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: (view.string as NSString).length))

        window.makeFirstResponder(nil)
        pasteboard.clearContents()
        XCTAssertFalse(view.performKeyEquivalent(with: copy))
        XCTAssertNil(pasteboard.string(forType: .string))
    }
}
