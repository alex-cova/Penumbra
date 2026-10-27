import XCTest
@testable import Umbra

/// Headless tests for `GhosttyVtTerminal.renderSnapshot` (plan Step 4):
/// the grid/cell/cursor data the future `GhosttyTerminalView` will draw.
final class GhosttyRenderSnapshotTests: XCTestCase {
    private func snapshot(
        cols: Int = 80,
        rows: Int = 24,
        writing bytes: Data? = nil
    ) -> GhosttyRenderSnapshot {
        let term = GhosttyVtTerminal(cols: cols, rows: rows)
        XCTAssertNotNil(term)
        if let bytes { term!.write(bytes) }
        let snap = term!.renderSnapshot()
        XCTAssertNotNil(snap)
        return snap!
    }

    private func rowText(_ row: GhosttySnapshotRow) -> String {
        row.cells.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    }

    func testGridDimensionsMatchResize() {
        let snap = snapshot(cols: 100, rows: 30)
        XCTAssertEqual(snap.cols, 100)
        XCTAssertEqual(snap.rows, 30)
        XCTAssertEqual(snap.grid.count, 30)
        XCTAssertTrue(snap.grid.allSatisfy { $0.cells.count == 100 })
    }

    func testPlainTextLandsInCells() {
        let snap = snapshot(writing: Data("hi\r\n".utf8))
        XCTAssertTrue(rowText(snap.grid[0]).hasPrefix("hi"))
        XCTAssertEqual(snap.grid[0].cells[0].text, "h")
        XCTAssertEqual(snap.grid[0].cells[1].text, "i")
        XCTAssertNil(snap.grid[0].cells[0].fg, "unstyled cells use the default foreground")
        XCTAssertFalse(snap.grid[0].cells[0].bold)
    }

    func testSgrBoldAndColor() {
        let snap = snapshot(writing: Data("a\u{1B}[1;31mR\u{1B}[0mb".utf8))
        let cells = snap.grid[0].cells
        XCTAssertFalse(cells[0].bold)
        XCTAssertTrue(cells[1].bold, "SGR 1 sets bold")
        XCTAssertNotNil(cells[1].fg, "SGR 31 resolves a foreground color")
        XCTAssertNotEqual(cells[1].fg, snap.fg, "resolved color differs from the default fg")
        XCTAssertFalse(cells[2].bold, "SGR 0 resets")
        XCTAssertNil(cells[2].fg)
    }

    func testBackgroundColor() {
        let snap = snapshot(writing: Data("\u{1B}[44mB".utf8))
        let cell = snap.grid[0].cells[0]
        XCTAssertNotNil(cell.bg, "SGR 44 resolves a background color")
        XCTAssertNotEqual(cell.bg, snap.bg)
    }

    func testUnderlineAndInverse() {
        let snap = snapshot(writing: Data("\u{1B}[4mU\u{1B}[0m\u{1B}[7mI".utf8))
        let cells = snap.grid[0].cells
        XCTAssertNotEqual(cells[0].underline, 0, "SGR 4 sets an underline style")
        XCTAssertTrue(cells[1].inverse, "SGR 7 sets inverse")
    }

    func testWideCharacters() {
        let snap = snapshot(writing: Data("あx".utf8))
        let cells = snap.grid[0].cells
        XCTAssertEqual(cells[0].text, "あ")
        XCTAssertEqual(cells[0].wide, .wide)
        XCTAssertEqual(cells[1].wide, .spacerTail)
        XCTAssertEqual(cells[2].text, "x")
    }

    func testCursorFollowsWrites() {
        let snap = snapshot(writing: Data("ab".utf8))
        XCTAssertTrue(snap.cursor.hasPosition)
        XCTAssertEqual(snap.cursor.x, 2)
        XCTAssertEqual(snap.cursor.y, 0)
        XCTAssertTrue(snap.cursor.visible)
    }

    func testSoftWrapMarksContinuation() {
        let snap = snapshot(cols: 80, rows: 24, writing: Data(String(repeating: "w", count: 90).utf8))
        XCTAssertEqual(snap.grid.count, 24)
        XCTAssertTrue(snap.grid[1].wrapContinuation, "second row continues the wrapped line")
        XCTAssertEqual(rowText(snap.grid[0]).count, 80)
        XCTAssertEqual(rowText(snap.grid[1]).count, 10)
    }

    func testAlternateScreenSnapshotsActiveScreen() {
        let term = GhosttyVtTerminal(cols: 80, rows: 24)!
        term.write(Data("primary".utf8))
        term.write(Data("\u{1B}[?1049h".utf8))
        term.write(Data("alternate".utf8))
        var snap = term.renderSnapshot()!
        XCTAssertTrue(rowText(snap.grid[0]).contains("alternate"))
        term.write(Data("\u{1B}[?1049l".utf8))
        snap = term.renderSnapshot()!
        XCTAssertTrue(rowText(snap.grid[0]).contains("primary"))
    }

    func testSnapshotAfterResetIsBlank() {
        let term = GhosttyVtTerminal(cols: 80, rows: 24)!
        term.write(Data("stuff".utf8))
        term.reset()
        let snap = term.renderSnapshot()!
        XCTAssertTrue(snap.grid.allSatisfy { rowText($0).isEmpty })
    }
}
