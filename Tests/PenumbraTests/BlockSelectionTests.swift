import AppKit
import XCTest
@testable import Penumbra

/// Covers column/block selection: dragging (via `beginBlockSelection`/`extendBlockSelection`),
/// growing a block with the keyboard (⌃⇧←/→/↑/↓), ragged/short lines producing a mix of clamped
/// non-empty ranges and zero-length carets, off-screen rows that haven't been laid out yet, and
/// typing into an active block.
@MainActor
final class BlockSelectionTests: XCTestCase {
    /// A point in view coordinates for `row`/`column` in `textView`, computed via the same
    /// `caretRect(for:)` the real UI uses, so tests never hardcode pixel geometry.
    private func point(forRow row: Int, column: Int, rowLocations: [Int], in textView: TextView) -> CGPoint {
        let rect = textView.caretRect(for: IndexedPosition(index: rowLocations[row] + column))
        return CGPoint(x: rect.minX, y: rect.midY)
    }

    func testBlockSelectionOverEvenWidthLines() {
        let textView = makeFocusedTextView(text: "xxxxx\nxxxxx\nxxxxx")
        let rowLocations = [0, 6, 12]
        textView.beginBlockSelection(at: point(forRow: 0, column: 1, rowLocations: rowLocations, in: textView))
        textView.extendBlockSelection(to: point(forRow: 2, column: 3, rowLocations: rowLocations, in: textView))
        XCTAssertTrue(textView.isBlockSelectionActive)
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 1, length: 2),
            NSRange(location: 7, length: 2),
            NSRange(location: 13, length: 2)
        ])
    }

    func testBlockSelectionOverRaggedLinesClampsShortRowsAndCollapsesEmptyRowToACaret() {
        // Row 0 and row 2 are wide enough for the block; row 1 is empty and shorter than even
        // the block's left edge, so it should collapse to a zero-length caret rather than being
        // dropped or crashing.
        let textView = makeFocusedTextView(text: "aaaaaa\n\ncccccc")
        let rowLocations = [0, 7, 8]
        textView.beginBlockSelection(at: point(forRow: 0, column: 1, rowLocations: rowLocations, in: textView))
        textView.extendBlockSelection(to: point(forRow: 2, column: 4, rowLocations: rowLocations, in: textView))
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 1, length: 3),
            NSRange(location: 7, length: 0),
            NSRange(location: 9, length: 3)
        ])
    }

    func testBlockSelectionClampsRowShorterThanBlockButLongerThanLeftEdge() {
        // Row 1 ("bb") is shorter than the block's right edge (column 4) but longer than its left
        // edge (column 1), so it should be clamped to a non-empty range ending at its own length,
        // not collapsed to a caret.
        let textView = makeFocusedTextView(text: "aaaaaa\nbb\ncccccc")
        let rowLocations = [0, 7, 10]
        textView.beginBlockSelection(at: point(forRow: 0, column: 1, rowLocations: rowLocations, in: textView))
        textView.extendBlockSelection(to: point(forRow: 2, column: 4, rowLocations: rowLocations, in: textView))
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 1, length: 3),
            NSRange(location: 8, length: 1), // "bb" clamped to its own 1-character remainder
            NSRange(location: 11, length: 3)
        ])
    }

    func testBlockSelectionStartingMidLine() {
        let textView = makeFocusedTextView(text: "xxxxxx\nxxxxxx")
        let rowLocations = [0, 7]
        textView.beginBlockSelection(at: point(forRow: 0, column: 2, rowLocations: rowLocations, in: textView))
        textView.extendBlockSelection(to: point(forRow: 1, column: 5, rowLocations: rowLocations, in: textView))
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 2, length: 3),
            NSRange(location: 9, length: 3)
        ])
    }

    func testBlockSelectionSpanningOffScreenRowsTypesetsThemOnDemand() {
        // 25 short lines in a 300pt-tall window lay out only a handful on screen; rows well past
        // the viewport must still be typeset correctly rather than collapsing to their start.
        let lineCount = 25
        let text = Array(repeating: "xxxxx", count: lineCount).joined(separator: "\n")
        let textView = makeFocusedTextView(text: text)
        var rowLocations: [Int] = []
        var location = 0
        for index in 0..<lineCount {
            rowLocations.append(location)
            location += 5 + (index == lineCount - 1 ? 0 : 1)
        }
        textView.beginBlockSelection(at: point(forRow: 0, column: 1, rowLocations: rowLocations, in: textView))
        textView.extendBlockSelection(to: point(forRow: lineCount - 1, column: 3, rowLocations: rowLocations, in: textView))
        let ranges = textView.selectedRanges
        XCTAssertEqual(ranges.count, lineCount)
        XCTAssertEqual(ranges.first, NSRange(location: rowLocations[0] + 1, length: 2))
        XCTAssertEqual(ranges.last, NSRange(location: rowLocations[lineCount - 1] + 1, length: 2))
        // A never-laid-out row collapsing to its start (the bug this test guards against) would
        // produce a zero-length range at the row's own location instead of a 2-character one.
        let middleRow = lineCount / 2
        XCTAssertEqual(ranges[middleRow], NSRange(location: rowLocations[middleRow] + 1, length: 2))
    }

    func testControlShiftDownArrowGrowsBlockSelectionByOneRow() {
        let textView = makeFocusedTextView(text: "xxxxx\nxxxxx\nxxxxx")
        textView.selectedRange = NSRange(location: 1, length: 0)
        send(keyEvent(keyCode: TestKeyCode.downArrow, flags: [.control, .shift]), to: textView)
        XCTAssertTrue(textView.isBlockSelectionActive)
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 1, length: 0),
            NSRange(location: 7, length: 0)
        ])
        send(keyEvent(keyCode: TestKeyCode.downArrow, flags: [.control, .shift]), to: textView)
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 1, length: 0),
            NSRange(location: 7, length: 0),
            NSRange(location: 13, length: 0)
        ])
    }

    func testControlShiftRightArrowGrowsBlockSelectionByOneColumn() {
        let textView = makeFocusedTextView(text: "xxxxx\nxxxxx")
        textView.selectedRange = NSRange(location: 1, length: 0)
        send(keyEvent(keyCode: TestKeyCode.downArrow, flags: [.control, .shift]), to: textView)
        send(keyEvent(keyCode: TestKeyCode.rightArrow, flags: [.control, .shift]), to: textView)
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 1, length: 1),
            NSRange(location: 7, length: 1)
        ])
    }

    func testEscapeEndsBlockSelectionAndCollapsesToPrimaryCaret() {
        let textView = makeFocusedTextView(text: "xxxxx\nxxxxx\nxxxxx")
        textView.selectedRange = NSRange(location: 1, length: 0)
        send(keyEvent(keyCode: TestKeyCode.downArrow, flags: [.control, .shift]), to: textView)
        send(keyEvent(keyCode: TestKeyCode.downArrow, flags: [.control, .shift]), to: textView)
        XCTAssertTrue(textView.isBlockSelectionActive)
        send(keyEvent(keyCode: TestKeyCode.escape), to: textView)
        XCTAssertFalse(textView.isBlockSelectionActive)
        XCTAssertFalse(textView.isMultiCursorActive)
    }

    func testTypingIntoActiveBlockReplacesEveryRow() {
        let textView = makeFocusedTextView(text: "aaaa\nbbbb\ncccc")
        let rowLocations = [0, 5, 10]
        textView.beginBlockSelection(at: point(forRow: 0, column: 0, rowLocations: rowLocations, in: textView))
        textView.extendBlockSelection(to: point(forRow: 2, column: 2, rowLocations: rowLocations, in: textView))
        textView.insertText("X")
        XCTAssertEqual(textView.text as String, "Xaa\nXbb\nXcc")
    }

    func testNonBlockSelectionMutationEndsBlockSelection() {
        let textView = makeFocusedTextView(text: "xxxxx\nxxxxx")
        textView.selectedRange = NSRange(location: 1, length: 0)
        send(keyEvent(keyCode: TestKeyCode.downArrow, flags: [.control, .shift]), to: textView)
        XCTAssertTrue(textView.isBlockSelectionActive)
        textView.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertFalse(textView.isBlockSelectionActive)
    }
}
