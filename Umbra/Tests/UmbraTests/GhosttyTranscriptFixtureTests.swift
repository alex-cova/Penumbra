import XCTest
@testable import Umbra

/// Transcript fixtures (plan Tests section, converted at Step 6): recorded
/// escape-sequence transcripts fed through `GhosttyVtTerminal`, asserting the
/// plain-text snapshot. Expected values were captured from the SwiftTerm
/// reference model while parity was green (GhosttyParityTests, deleted at
/// Step 6 with the SwiftTerm dependency); they encode verified cell-grid
/// truth — e.g. CUP 2;5 parks at column 4, tabs expand to the next multiple
/// of 8. Scrollback is out of scope; screen content is what must match.
final class GhosttyTranscriptFixtureTests: XCTestCase {
    /// Screen lines from the Ghostty snapshot grid, right-trimmed.
    private func snapshotText(_ transcript: String, cols: Int = 80, rows: Int = 24) -> String {
        let terminal = GhosttyVtTerminal(cols: cols, rows: rows)!
        terminal.write(Data(transcript.utf8))
        guard let snapshot = terminal.renderSnapshot() else { return "" }
        let lines = snapshot.grid.map { row in
            // Cells are 1:1 with grid columns: empty text is a blank cell
            // (renders as a space), except wide-char spacers which
            // contribute nothing.
            var text = row.cells.map { cell -> String in
                switch cell.wide {
                case .spacerTail, .spacerHead: return ""
                case .narrow, .wide: return cell.text.isEmpty ? " " : cell.text
                }
            }.joined()
            while text.hasSuffix(" ") || text.hasSuffix("\t") { text.removeLast() }
            return text
        }
        return Self.normalize(lines.joined(separator: "\n"))
    }

    private static func normalize(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private func checkFixture(_ transcript: String, _ expected: String, cols: Int = 80, rows: Int = 24, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(snapshotText(transcript, cols: cols, rows: rows), expected, "transcript \(transcript.debugDescription)", file: file, line: line)
    }

    func testSGRColorsBold() {
        checkFixture("a\u{1B}[1;31mRED\u{1B}[0mb", "aREDb")
    }

    func testCursorAddressing() {
        checkFixture("\u{1B}[2;5HX", "\n    X")
    }

    func testTabs() {
        checkFixture("a\tb", "a       b")
    }

    func testEraseLine() {
        checkFixture("hello\u{1B}[2K", "")
    }

    func testEraseDisplay() {
        checkFixture("hello\u{1B}[2J", "")
    }

    func testCarriageReturnOverwrite() {
        checkFixture("ab\rcd", "cd")
    }

    func testWideCharacters() {
        checkFixture("あいうx", "あいうx")
    }

    func testSoftWrap() {
        checkFixture(
            String(repeating: "w", count: 90),
            String(repeating: "w", count: 80) + "\n" + String(repeating: "w", count: 10),
            cols: 80, rows: 24)
    }

    func testScrollRegion() {
        checkFixture("\u{1B}[2;5r\u{1B}[2;1Hregion\u{1B}[r", "\nregion")
    }

    func testAlternateScreenRoundTrip() {
        checkFixture("main-screen\u{1B}[?1049halt-screen\u{1B}[?1049l", "main-screen")
    }

    func testCursorUpDown() {
        checkFixture("line1\r\nline2\r\n\u{1B}[Aover", "line1\nover2")
    }

    func testInsertDeleteLine() {
        checkFixture("one\r\ntwo\r\nthree\r\n\u{1B}[2;1H\u{1B}[L", "one\n\ntwo\nthree")
    }
}
