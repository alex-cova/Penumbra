import AppKit
import XCTest
@testable import Penumbra

@MainActor
final class MultiSelectionTests: XCTestCase {
    func testInsertTextAtMultipleCarets() {
        let textView = makeFocusedTextView(text: "ab ab ab")
        textView.selectedRanges = [
            NSRange(location: 0, length: 0),
            NSRange(location: 3, length: 0),
            NSRange(location: 6, length: 0)
        ]
        textView.insertText("X")
        XCTAssertEqual(textView.text as String, "Xab Xab Xab")
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 1, length: 0),
            NSRange(location: 4, length: 0),
            NSRange(location: 7, length: 0)
        ])
    }

    func testDeleteBackwardAtMultipleCarets() {
        let textView = makeFocusedTextView(text: "aabb")
        textView.selectedRanges = [
            NSRange(location: 2, length: 0),
            NSRange(location: 4, length: 0)
        ]
        textView.deleteBackward()
        XCTAssertEqual(textView.text as String, "ab")
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 1, length: 0),
            NSRange(location: 3, length: 0)
        ])
    }

    func testCollapseMultiSelectionToPrimary() {
        let textView = makeFocusedTextView(text: "hello")
        textView.selectedRanges = [
            NSRange(location: 0, length: 0),
            NSRange(location: 3, length: 0)
        ]
        textView.collapseMultiSelectionToPrimary()
        XCTAssertFalse(textView.isMultiCursorActive)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))
    }

    func testAddSelectionsOnEachLine() {
        let textView = makeFocusedTextView(text: "one\ntwo\nthree")
        textView.selectedRange = NSRange(location: 0, length: 11)
        textView.addSelectionsOnEachLine()
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 0, length: 0),
            NSRange(location: 4, length: 0),
            NSRange(location: 8, length: 0)
        ])
    }

    func testMultiSelectionControllerNormalizesDuplicateCarets() {
        let controller = MultiSelectionController()
        controller.setSelections([
            NSRange(location: 2, length: 0),
            NSRange(location: 2, length: 0),
            NSRange(location: 5, length: 0)
        ])
        XCTAssertEqual(controller.selections, [
            NSRange(location: 2, length: 0),
            NSRange(location: 5, length: 0)
        ])
    }

    func testNonEmptyRangeReplacesMultiCaretSelection() {
        let controller = MultiSelectionController()
        controller.setSelections([
            NSRange(location: 0, length: 0),
            NSRange(location: 4, length: 0)
        ])
        controller.setSelections([NSRange(location: 1, length: 3)])
        XCTAssertEqual(controller.selections, [NSRange(location: 1, length: 3)])
        XCTAssertFalse(controller.hasMultipleSelections)
    }

    func testMultipleMatchingRangesArePreserved() {
        let controller = MultiSelectionController()
        controller.setSelections([
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3)
        ])
        XCTAssertEqual(controller.selections, [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3)
        ])
        XCTAssertTrue(controller.hasMultipleSelections)
    }

    // MARK: - Relaxed `normalize` (mixed-length / mixed empty+non-empty selections)
    //
    // These support column/block selection, where a rectangle over ragged lines produces ranges
    // of differing lengths, and a rectangle over short lines produces a mix of empty carets (rows
    // shorter than the block's left edge) and non-empty ranges.

    func testNormalizeAllowsMixedLengthRanges() {
        let normalized = MultiSelectionController.normalize([
            NSRange(location: 0, length: 3),
            NSRange(location: 10, length: 1),
            NSRange(location: 20, length: 5)
        ])
        XCTAssertEqual(normalized, [
            NSRange(location: 0, length: 3),
            NSRange(location: 10, length: 1),
            NSRange(location: 20, length: 5)
        ])
    }

    func testNormalizeAllowsMixedEmptyAndNonEmptyRanges() {
        let normalized = MultiSelectionController.normalize([
            NSRange(location: 0, length: 3),
            NSRange(location: 10, length: 0),
            NSRange(location: 20, length: 2)
        ])
        XCTAssertEqual(normalized, [
            NSRange(location: 0, length: 3),
            NSRange(location: 10, length: 0),
            NSRange(location: 20, length: 2)
        ])
    }

    func testNormalizeDropsCaretInsideNonEmptyRange() {
        let normalized = MultiSelectionController.normalize([
            NSRange(location: 0, length: 5),
            NSRange(location: 2, length: 0)
        ])
        XCTAssertEqual(normalized, [NSRange(location: 0, length: 5)])
    }

    func testNormalizeMergesOverlappingNonEmptyRanges() {
        let normalized = MultiSelectionController.normalize([
            NSRange(location: 0, length: 5),
            NSRange(location: 3, length: 5)
        ])
        XCTAssertEqual(normalized, [NSRange(location: 0, length: 8)])
    }

    func testAddSelectionAppendsNonEmptyRangeRatherThanReplacing() {
        let controller = MultiSelectionController()
        controller.setSelections([NSRange(location: 0, length: 0)])
        XCTAssertTrue(controller.addSelection(NSRange(location: 5, length: 3)))
        XCTAssertEqual(controller.selections, [
            NSRange(location: 0, length: 0),
            NSRange(location: 5, length: 3)
        ])
    }

    // MARK: - Caret-set history (⌘U)

    func testUndoLastCaretChangeAfterAddSelectionsOnEachLine() {
        let textView = makeFocusedTextView(text: "one\ntwo\nthree")
        textView.selectedRange = NSRange(location: 0, length: 8)
        XCTAssertFalse(textView.isMultiCursorActive)
        textView.addSelectionsOnEachLine()
        XCTAssertEqual(textView.selectedRanges.count, 2)
        textView.undoLastCaretChange()
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 8))
        XCTAssertFalse(textView.isMultiCursorActive)
    }

    func testUndoLastCaretChangeStepsBackThroughMultipleAdditions() {
        let textView = makeFocusedTextView(text: "aaa\nbbb\nccc\nddd")
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.addCaretBelow()
        textView.addCaretBelow()
        XCTAssertEqual(textView.selectedRanges.count, 3)
        textView.undoLastCaretChange()
        XCTAssertEqual(textView.selectedRanges.count, 2)
        textView.undoLastCaretChange()
        XCTAssertEqual(textView.selectedRanges.count, 1)
    }

    func testCaretHistoryClearsOnDocumentEdit() {
        let textView = makeFocusedTextView(text: "aaa\nbbb\nccc")
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.addCaretBelow()
        XCTAssertEqual(textView.selectedRanges.count, 2)
        textView.insertText("X")
        // The history entry captured before addCaretBelow() is gone -- undoing the caret set now
        // has nothing to step back to.
        let rangesBeforeUndo = textView.selectedRanges
        textView.undoLastCaretChange()
        XCTAssertEqual(textView.selectedRanges, rangesBeforeUndo)
    }

    func testSelectNextOccurrenceSelectsWordThenAddsNextMatch() {
        let textView = makeFocusedTextView(text: "foo foo foo")
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.selectNextOccurrence()
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 3))
        textView.selectNextOccurrence()
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3)
        ])
    }

    func testSkipCurrentOccurrenceReplacesLastRangeRatherThanAppending() {
        let textView = makeFocusedTextView(text: "foo bar foo bar foo")
        textView.selectedRange = NSRange(location: 0, length: 3) // "foo" at 0
        textView.selectNextOccurrence() // adds "foo" at 8
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3)
        ])
        textView.skipCurrentOccurrence() // replaces the one at 8 with the next "foo" at 16
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 0, length: 3),
            NSRange(location: 16, length: 3)
        ])
    }

    func testSkipCurrentOccurrenceIsNoOpWithOnlyOneRange() {
        let textView = makeFocusedTextView(text: "foo bar foo")
        textView.selectedRange = NSRange(location: 0, length: 3)
        textView.skipCurrentOccurrence()
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 0, length: 3)])
    }

    func testSelectAllOccurrencesFindsEveryMatch() {
        let textView = makeFocusedTextView(text: "foo bar foo baz foo")
        textView.selectedRange = NSRange(location: 0, length: 3)
        textView.selectAllOccurrences()
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3),
            NSRange(location: 16, length: 3)
        ])
    }

    func testSelectAllOccurrencesUsesWordUnderCaretWhenSelectionIsEmpty() {
        let textView = makeFocusedTextView(text: "foo bar foo")
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.selectAllOccurrences()
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3)
        ])
    }

    // MARK: - Clone caret vertically (⌥⌘↑/↓)

    func testAddCaretBelowClonesTopmostCaretDown() {
        let textView = makeFocusedTextView(text: "aaa\nbbb\nccc")
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.addCaretBelow()
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 0, length: 0),
            NSRange(location: 4, length: 0)
        ])
        textView.addCaretBelow()
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 0, length: 0),
            NSRange(location: 4, length: 0),
            NSRange(location: 8, length: 0)
        ])
    }

    func testAddCaretAboveClonesBottommostCaretUp() {
        let textView = makeFocusedTextView(text: "aaa\nbbb\nccc")
        textView.selectedRange = NSRange(location: 8, length: 0)
        textView.addCaretAbove()
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 4, length: 0),
            NSRange(location: 8, length: 0)
        ])
    }

    func testAddCaretBelowIsNoOpAtLastLine() {
        let textView = makeFocusedTextView(text: "aaa\nbbb\nccc")
        // Already at the end of the document, where downward movement can't advance further.
        textView.selectedRange = NSRange(location: 11, length: 0)
        textView.addCaretBelow()
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 11, length: 0)])
        XCTAssertFalse(textView.isMultiCursorActive)
    }

    func testAddCaretAboveIsNoOpAtFirstLine() {
        let textView = makeFocusedTextView(text: "aaa\nbbb\nccc")
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.addCaretAbove()
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 0, length: 0)])
        XCTAssertFalse(textView.isMultiCursorActive)
    }

    func testInsertTextAtMultipleMatchingRanges() {
        let textView = makeFocusedTextView(text: "foo bar foo")
        textView.selectedRanges = [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3)
        ]
        textView.insertText("X")
        XCTAssertEqual(textView.text as String, "X bar X")
    }

    func testVerticalArrowMovesAllCarets() {
        let textView = makeFocusedTextView(text: "aaa\nbbb\nccc")
        textView.selectedRanges = [
            NSRange(location: 0, length: 0),
            NSRange(location: 8, length: 0)
        ]
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0x7D
        )!
        textView.window?.sendEvent(event)
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 4, length: 0),
            NSRange(location: 11, length: 0)
        ])
    }
}
