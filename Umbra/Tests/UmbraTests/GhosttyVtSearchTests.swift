import XCTest
@testable import Umbra

/// The terminal find bar's engine: libghostty-vt's native search over the screen and scrollback
/// (`GhosttyVtSearch.swift`). Headless: bytes in, matches and viewport highlights out.
final class GhosttyVtSearchTests: XCTestCase {
    private func makeTerminal(cols: Int = 40, rows: Int = 10) throws -> GhosttyVtTerminal {
        let terminal = try XCTUnwrap(GhosttyVtTerminal(cols: cols, rows: rows))
        terminal.configure(GhosttyVtConfiguration())
        return terminal
    }

    private func writeNumberedLines(_ terminal: GhosttyVtTerminal, count: Int) {
        var text = ""
        for index in 0..<count { text += String(format: "line-%04d\r\n", index) }
        terminal.write(Data(text.utf8))
    }

    @discardableResult
    private func runToCompletion(_ terminal: GhosttyVtTerminal) -> GhosttySearchState {
        var state = terminal.stepSearch()
        var steps = 0
        while state.status == .searching, steps < 100_000 {
            state = terminal.stepSearch()
            steps += 1
        }
        XCTAssertEqual(state.status, .complete, "the search must catch up")
        return state
    }

    /// Text of a viewport row, from the render snapshot.
    private func rowText(_ terminal: GhosttyVtTerminal, _ row: Int) -> String {
        guard let snapshot = terminal.renderSnapshot(), row < snapshot.grid.count else { return "" }
        return snapshot.grid[row].cells.map(\.text).joined()
    }

    func testFindsMatchesInScrollbackAndTheActiveArea() throws {
        let terminal = try makeTerminal()
        writeNumberedLines(terminal, count: 2_000)
        terminal.setSearchNeedle("line-01")
        let state = runToCompletion(terminal)
        XCTAssertEqual(state.total, 100, "line-0100 … line-0199, all in scrollback")

        terminal.setSearchNeedle("line-199")
        XCTAssertEqual(runToCompletion(terminal).total, 10, "line-1990 … line-1999, partly on screen")
    }

    func testNextSelectsTheNewestMatchAndScrollsToIt() throws {
        let terminal = try makeTerminal()
        writeNumberedLines(terminal, count: 2_000)
        let before = try XCTUnwrap(terminal.scrollbar())
        terminal.setSearchNeedle("line-01")
        runToCompletion(terminal)

        var state = terminal.selectSearchMatch(forward: true)
        XCTAssertEqual(state.selectedIndex, 0, "Return starts at the newest match")
        let after = try XCTUnwrap(terminal.scrollbar())
        XCTAssertLessThan(after.offset, before.offset, "the viewport scrolled up into history")
        let selected = try XCTUnwrap(state.highlights.first(where: \.isSelected), "the selected match is drawn")
        XCTAssertTrue(rowText(terminal, selected.from.row).contains("line-0199"))
        XCTAssertEqual(selected.from.col, 0)
        XCTAssertEqual(selected.to.col, "line-01".count - 1)

        state = terminal.selectSearchMatch(forward: true)
        XCTAssertEqual(state.selectedIndex, 1, "next moves toward older output")
        let older = try XCTUnwrap(state.highlights.first(where: \.isSelected))
        XCTAssertTrue(rowText(terminal, older.from.row).contains("line-0198"))

        state = terminal.selectSearchMatch(forward: false)
        state = terminal.selectSearchMatch(forward: false)
        XCTAssertEqual(state.selectedIndex, 99, "previous past the newest wraps to the oldest")
        let oldest = try XCTUnwrap(state.highlights.first(where: \.isSelected))
        XCTAssertTrue(rowText(terminal, oldest.from.row).contains("line-0100"))
    }

    func testViewportHighlightsCoverOnlyVisibleRows() throws {
        let terminal = try makeTerminal(cols: 40, rows: 10)
        writeNumberedLines(terminal, count: 50)
        terminal.setSearchNeedle("line-004")
        let state = runToCompletion(terminal)
        XCTAssertEqual(state.total, 10)
        XCTAssertFalse(state.highlights.isEmpty)
        for highlight in state.highlights {
            XCTAssertLessThan(highlight.from.row, 10)
            XCTAssertTrue(rowText(terminal, highlight.from.row).hasPrefix("line-004"))
        }
    }

    func testAsciiCaseIsIgnored() throws {
        let terminal = try makeTerminal()
        writeNumberedLines(terminal, count: 300)
        terminal.setSearchNeedle("LINE-0150")
        XCTAssertEqual(runToCompletion(terminal).total, 1)
    }

    func testSearchesTheAlternateScreenWhileItShows() throws {
        let terminal = try makeTerminal()
        writeNumberedLines(terminal, count: 30)
        terminal.write(Data("\u{1B}[?1049h\u{1B}[Hpager-only-text\r\n".utf8))
        terminal.setSearchNeedle("pager-only")
        XCTAssertEqual(runToCompletion(terminal).total, 1)
        terminal.write(Data("\u{1B}[?1049l".utf8))
        XCTAssertEqual(runToCompletion(terminal).total, 0, "back on the primary screen, its own results")
    }

    func testClearingTheNeedleDropsTheResults() throws {
        let terminal = try makeTerminal()
        writeNumberedLines(terminal, count: 100)
        terminal.setSearchNeedle("line-00")
        XCTAssertGreaterThan(runToCompletion(terminal).total, 0)
        terminal.setSearchNeedle(nil)
        let state = runToCompletion(terminal)
        XCTAssertEqual(state.total, 0)
        XCTAssertTrue(state.highlights.isEmpty)
        XCTAssertNil(state.selectedIndex)
    }

    func testNewOutputIsFoundOnTheNextStep() throws {
        let terminal = try makeTerminal()
        terminal.setSearchNeedle("late-arrival")
        XCTAssertEqual(runToCompletion(terminal).total, 0)
        terminal.write(Data("late-arrival\r\n".utf8))
        XCTAssertEqual(runToCompletion(terminal).total, 1)
    }

    func testTwoTerminalsSearchIndependently() throws {
        let first = try makeTerminal()
        let second = try makeTerminal()
        writeNumberedLines(first, count: 100)
        writeNumberedLines(second, count: 100)
        first.setSearchNeedle("line-005")
        XCTAssertEqual(runToCompletion(first).total, 10)
        XCTAssertEqual(second.stepSearch(), .idle, "a terminal nobody searched has no search")
        _ = first.selectSearchMatch(forward: true)
        XCTAssertEqual(second.scrollbar()?.offset, second.scrollbar().map { $0.total - $0.length },
                       "selecting in one terminal does not scroll the other")
    }

    func testTerminalFreesWithALiveSearch() throws {
        var terminal: GhosttyVtTerminal? = try makeTerminal()
        writeNumberedLines(terminal!, count: 100)
        terminal?.setSearchNeedle("line")
        _ = terminal?.stepSearch()
        terminal = nil
    }
}
