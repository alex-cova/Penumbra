import XCTest
@testable import Umbra

/// Headless tests for selection text and mode queries (plan Step 4):
/// copy joins soft wraps, keeps hard breaks, trims; modes reflect the app.
final class GhosttySelectionTests: XCTestCase {
    private func snapshot(writing bytes: Data, cols: Int = 80, rows: Int = 24) -> GhosttyRenderSnapshot {
        let term = GhosttyVtTerminal(cols: cols, rows: rows)!
        term.write(bytes)
        return term.renderSnapshot()!
    }

    func testSingleLineSelection() {
        let snap = snapshot(writing: Data("hello world\r\n".utf8))
        XCTAssertEqual(
            GhosttySelectionText.text(in: snap, from: (0, 0), to: (4, 0)),
            "hello")
    }

    func testReversedEndsOrdered() {
        let snap = snapshot(writing: Data("hello\r\n".utf8))
        XCTAssertEqual(
            GhosttySelectionText.text(in: snap, from: (4, 0), to: (0, 0)),
            "hello")
    }

    func testMultilineKeepsBreaks() {
        let snap = snapshot(writing: Data("one\r\ntwo\r\n".utf8))
        XCTAssertEqual(
            GhosttySelectionText.text(in: snap, from: (0, 0), to: (2, 1)),
            "one\ntwo")
    }

    func testSoftWrapJoinsWithoutNewline() {
        let snap = snapshot(
            writing: Data((String(repeating: "w", count: 90)).utf8),
            cols: 80, rows: 24)
        XCTAssertEqual(
            GhosttySelectionText.text(in: snap, from: (0, 0), to: (9, 1)),
            String(repeating: "w", count: 90))
    }

    func testTrailingSpacesTrimmed() {
        let snap = snapshot(writing: Data("ab  \r\n".utf8))
        XCTAssertEqual(
            GhosttySelectionText.text(in: snap, from: (0, 0), to: (10, 0)),
            "ab")
    }

    func testEmptySelectionIsNil() {
        let snap = snapshot(writing: Data("ab\r\n".utf8))
        XCTAssertNil(GhosttySelectionText.text(in: snap, from: (10, 5), to: (20, 5)))
    }

    func testBracketedPasteModeQuery() {
        let term = GhosttyVtTerminal(cols: 80, rows: 24)!
        XCTAssertFalse(term.isModeSet(GhosttyTerminalModes.bracketedPaste))
        term.write(Data("\u{1B}[?2004h".utf8))
        XCTAssertTrue(term.isModeSet(GhosttyTerminalModes.bracketedPaste))
        term.write(Data("\u{1B}[?2004l".utf8))
        XCTAssertFalse(term.isModeSet(GhosttyTerminalModes.bracketedPaste))
    }

    func testMouseModeQuery() {
        let term = GhosttyVtTerminal(cols: 80, rows: 24)!
        XCTAssertFalse(term.isModeSet(GhosttyTerminalModes.normalMouse))
        term.write(Data("\u{1B}[?1000h".utf8))
        XCTAssertTrue(term.isModeSet(GhosttyTerminalModes.normalMouse))
        XCTAssertFalse(term.isModeSet(GhosttyTerminalModes.anyMouse))
    }
}
