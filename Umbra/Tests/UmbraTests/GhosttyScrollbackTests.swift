import XCTest
@testable import Umbra

/// Scrollback viewing contract (plan Step 4): the terminal viewport can be
/// scrolled into history and back; snapshots follow the viewport; new
/// output does not yank a parked viewport.
final class GhosttyScrollbackTests: XCTestCase {
    private func makeTerminal(cols: Int = 20, rows: Int = 6) -> GhosttyVtTerminal {
        GhosttyVtTerminal(cols: cols, rows: rows)!
    }

    /// Feeds `count` labeled lines without a trailing newline, so the last
    /// line sits on the bottom viewport row.
    private func feedLines(_ terminal: GhosttyVtTerminal, count: Int, prefix: String = "line") {
        var text = ""
        for i in 0..<count {
            if i > 0 { text += "\r\n" }
            text += "\(prefix)\(i)"
        }
        terminal.write(Data(text.utf8))
    }

    /// Visible rows as plain text (same blank/spacer mapping as parity).
    private func snapshotText(_ terminal: GhosttyVtTerminal) -> [String] {
        guard let snapshot = terminal.renderSnapshot() else { return [] }
        return snapshot.grid.map { row in
            var text = row.cells.map { cell -> String in
                switch cell.wide {
                case .spacerTail, .spacerHead: return ""
                case .narrow, .wide: return cell.text.isEmpty ? " " : cell.text
                }
            }.joined()
            while text.hasSuffix(" ") { text.removeLast() }
            return text
        }
    }

    func testScrollbarAtBottomAfterOutput() {
        let terminal = makeTerminal()
        feedLines(terminal, count: 20)
        guard let sb = terminal.scrollbar() else { return XCTFail("no scrollbar") }
        XCTAssertEqual(sb.length, 6)
        XCTAssertGreaterThan(sb.total, sb.length)
        XCTAssertEqual(sb.offset + sb.length, sb.total, "fresh output parks at the bottom")
        XCTAssertEqual(snapshotText(terminal), ["line14", "line15", "line16", "line17", "line18", "line19"])
    }

    func testScrollUpRevealsHistory() {
        let terminal = makeTerminal()
        feedLines(terminal, count: 20)
        let before = terminal.scrollbar()!
        terminal.scrollViewport(lines: -3)
        guard let sb = terminal.scrollbar() else { return XCTFail("no scrollbar") }
        XCTAssertEqual(sb.offset, before.offset - 3)
        XCTAssertEqual(snapshotText(terminal), ["line11", "line12", "line13", "line14", "line15", "line16"])
    }

    func testScrollClampedAtTop() {
        let terminal = makeTerminal()
        feedLines(terminal, count: 20)
        terminal.scrollViewport(lines: -100_000)
        guard let sb = terminal.scrollbar() else { return XCTFail("no scrollbar") }
        XCTAssertEqual(sb.offset, 0)
        XCTAssertEqual(snapshotText(terminal).first, "line0")
    }

    func testScrollDownClampedAtBottom() {
        let terminal = makeTerminal()
        feedLines(terminal, count: 20)
        terminal.scrollViewport(lines: -3)
        terminal.scrollViewport(lines: 100_000)
        guard let sb = terminal.scrollbar() else { return XCTFail("no scrollbar") }
        XCTAssertEqual(sb.offset + sb.length, sb.total)
        XCTAssertEqual(snapshotText(terminal).last, "line19")
    }

    func testScrollToBottomRestoresLiveView() {
        let terminal = makeTerminal()
        feedLines(terminal, count: 20)
        terminal.scrollViewport(lines: -3)
        terminal.scrollViewportToBottom()
        guard let sb = terminal.scrollbar() else { return XCTFail("no scrollbar") }
        XCTAssertEqual(sb.offset + sb.length, sb.total)
        XCTAssertEqual(snapshotText(terminal), ["line14", "line15", "line16", "line17", "line18", "line19"])
    }

    func testScrollToRowRoundTrips() {
        let terminal = makeTerminal()
        feedLines(terminal, count: 20)
        guard let sb = terminal.scrollbar() else { return XCTFail("no scrollbar") }
        let target = sb.total - sb.length - 2
        terminal.scrollViewport(toRow: target)
        XCTAssertEqual(terminal.scrollbar()?.offset, target)
        XCTAssertEqual(snapshotText(terminal).first, "line12")
    }

    func testNewOutputDoesNotYankParkedViewport() {
        let terminal = makeTerminal()
        feedLines(terminal, count: 20)
        terminal.scrollViewport(lines: -3)
        let parked = terminal.scrollbar()!.offset
        terminal.write(Data("\r\ntail".utf8))
        // The viewport stays where the user parked it; only the
        // scrollable area grows. (Typing snaps back via the view.)
        XCTAssertEqual(terminal.scrollbar()?.offset, parked)
    }

    func testAltScreenHasNoScrollback() {
        let terminal = makeTerminal()
        feedLines(terminal, count: 20)
        terminal.write(Data("\u{1B}[?1049h-alt".utf8))
        guard let sb = terminal.scrollbar() else { return XCTFail("no scrollbar") }
        XCTAssertEqual(sb.total, sb.length, "alternate screen has no scrollback")
        terminal.scrollViewport(lines: -5)
        XCTAssertEqual(terminal.scrollbar()?.offset, 0, "scroll is a no-op on the alternate screen")
        XCTAssertTrue(snapshotText(terminal).joined(separator: "\n").contains("-alt"))
        terminal.write(Data("\u{1B}[?1049l".utf8))
        XCTAssertEqual(snapshotText(terminal).last, "line19", "exit restores the primary screen")
    }
}
