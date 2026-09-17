import AppKit
import XCTest
@testable import Penumbra

/// Covers the line-level editor commands added alongside move-line/indent: `selectLines()` (⌘L),
/// `duplicateSelectedLines()` (⌘D), and `deleteSelectedLines()` (⌘⌫). Each is multi-caret aware,
/// applies as a single undo step, and has to handle the final-line-without-a-trailing-newline
/// case. The keyboard section also pins the ⌘D → duplicate / ⌘⇧D → select-next-occurrence split.
@MainActor
final class LineOperationsTests: XCTestCase {
    private typealias KeyCode = TestKeyCode

    // MARK: - Select Line

    func testSelectLinesSnapsACaretOutToItsWholeLineIncludingTheNewline() {
        let textView = makeFocusedTextView(text: "foo\nbar\nbaz")
        textView.selectedRange = NSRange(location: 5, length: 0) // "ba|r" on line 1
        textView.selectLines()
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 4)) // "bar\n"
    }

    func testSelectLinesExpandsAMultiLineSelectionToFullLines() {
        let textView = makeFocusedTextView(text: "foo\nbar\nbaz")
        textView.selectedRange = NSRange(location: 1, length: 8) // "oo\nbar\nb"
        textView.selectLines()
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 11)) // whole document
    }

    func testSelectLinesRunsPerCaretWhenMultipleSelectionsAreActive() {
        let textView = makeFocusedTextView(text: "a\nb\nc\nd\ne")
        textView.selectedRanges = [
            NSRange(location: 0, length: 0), // line "a"
            NSRange(location: 4, length: 0)  // line "c"
        ]
        textView.selectLines()
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 0, length: 2), // "a\n"
            NSRange(location: 4, length: 2)  // "c\n"
        ])
    }

    func testSelectLinesOnTheFinalLineWithoutATrailingNewlineStopsAtEndOfDocument() {
        let textView = makeFocusedTextView(text: "a\nb\nc")
        textView.selectedRange = NSRange(location: 4, length: 0) // "|c"
        textView.selectLines()
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 1)) // "c", no newline to add
    }

    func testSelectLinesIsIdempotent() {
        let textView = makeFocusedTextView(text: "foo\nbar\nbaz")
        textView.selectedRange = NSRange(location: 5, length: 0)
        textView.selectLines()
        let afterFirst = textView.selectedRange
        textView.selectLines()
        XCTAssertEqual(textView.selectedRange, afterFirst)
    }

    // MARK: - Duplicate Line

    func testDuplicateSelectedLinesCopiesTheCaretLineBelowAndMovesTheCaretOntoTheCopy() {
        let textView = makeFocusedTextView(text: "foo\nbar\nbaz")
        textView.selectedRange = NSRange(location: 5, length: 0) // "ba|r"
        textView.duplicateSelectedLines()
        XCTAssertEqual(textView.text as String, "foo\nbar\nbar\nbaz")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 9, length: 0)) // "ba|r" on the copy
    }

    func testDuplicateSelectedLinesWithAdjacentCaretsCopiesTheGroupOnce() {
        let textView = makeFocusedTextView(text: "a\nb\nc\nd")
        textView.selectedRanges = [
            NSRange(location: 0, length: 0), // line "a"
            NSRange(location: 2, length: 0)  // line "b" -- adjacent, same group
        ]
        textView.duplicateSelectedLines()
        XCTAssertEqual(textView.text as String, "a\nb\na\nb\nc\nd")
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 4, length: 0), // "a" copy
            NSRange(location: 6, length: 0)  // "b" copy
        ])
    }

    func testDuplicateSelectedLinesWithNonAdjacentGroupsCopiesEachIndependently() {
        let textView = makeFocusedTextView(text: "a\nb\nc\nd\ne")
        textView.selectedRanges = [
            NSRange(location: 0, length: 0), // line "a"
            NSRange(location: 4, length: 0)  // line "c"
        ]
        textView.duplicateSelectedLines()
        XCTAssertEqual(textView.text as String, "a\na\nb\nc\nc\nd\ne")
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 2, length: 0), // "a" copy
            NSRange(location: 8, length: 0)  // "c" copy
        ])
    }

    func testDuplicateSelectedLinesOnFinalLineWithoutTrailingNewlinePrefixesALineBreak() {
        let textView = makeFocusedTextView(text: "a\nb\nc")
        textView.selectedRange = NSRange(location: 4, length: 0) // "|c"
        textView.duplicateSelectedLines()
        XCTAssertEqual(textView.text as String, "a\nb\nc\nc")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 6, length: 0)) // "|c" on the copy
    }

    func testDuplicateSelectedLinesOnCRLFDocument() {
        let textView = makeFocusedTextView(text: "foo\r\nbar\r\nbaz")
        textView.lineEndings = .crlf
        textView.selectedRange = NSRange(location: 6, length: 0) // "b|ar"
        textView.duplicateSelectedLines()
        let normalized = (textView.text as String).replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertEqual(normalized, "foo\nbar\nbar\nbaz")
    }

    func testUndoAfterDuplicateSelectedLinesRestoresTextAndTheWholeCaretSet() {
        let textView = makeFocusedTextView(text: "a\nb\nc")
        let original: [NSRange] = [
            NSRange(location: 0, length: 0), // line "a"
            NSRange(location: 4, length: 0)  // line "c"
        ]
        textView.selectedRanges = original
        textView.duplicateSelectedLines()
        XCTAssertNotEqual(textView.text as String, "a\nb\nc")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text as String, "a\nb\nc")
        XCTAssertEqual(textView.selectedRanges, original)
    }

    // MARK: - Delete Line

    func testDeleteSelectedLinesRemovesTheCaretLineIncludingItsNewline() {
        let textView = makeFocusedTextView(text: "foo\nbar\nbaz")
        textView.selectedRange = NSRange(location: 5, length: 0) // "ba|r"
        textView.deleteSelectedLines()
        XCTAssertEqual(textView.text as String, "foo\nbaz")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 0)) // same column on the line that slid up
    }

    func testDeleteSelectedLinesWithAdjacentCaretsRemovesTheWholeGroup() {
        let textView = makeFocusedTextView(text: "a\nb\nc\nd\ne")
        textView.selectedRanges = [
            NSRange(location: 2, length: 0), // line "b"
            NSRange(location: 4, length: 0)  // line "c" -- adjacent
        ]
        textView.deleteSelectedLines()
        XCTAssertEqual(textView.text as String, "a\nd\ne")
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 2, length: 0)])
    }

    func testDeleteSelectedLinesWithNonAdjacentGroupsRemovesEach() {
        let textView = makeFocusedTextView(text: "a\nb\nc\nd\ne")
        textView.selectedRanges = [
            NSRange(location: 0, length: 0), // line "a"
            NSRange(location: 6, length: 0)  // line "d"
        ]
        textView.deleteSelectedLines()
        XCTAssertEqual(textView.text as String, "b\nc\ne")
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 0, length: 0),
            NSRange(location: 4, length: 0)
        ])
    }

    func testDeleteSelectedLinesOnFinalLineWithoutTrailingNewlineSwallowsThePrecedingDelimiter() {
        let textView = makeFocusedTextView(text: "a\nb\nc")
        textView.selectedRange = NSRange(location: 4, length: 0) // "|c"
        textView.deleteSelectedLines()
        XCTAssertEqual(textView.text as String, "a\nb")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 0))
    }

    func testDeleteSelectedLinesCoveringTheWholeDocumentLeavesOneEmptyLine() {
        let textView = makeFocusedTextView(text: "a\nb\nc")
        textView.selectedRange = NSRange(location: 0, length: 5) // all three lines
        textView.deleteSelectedLines()
        XCTAssertEqual(textView.text as String, "")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))
    }

    func testDeleteSelectedLinesOnCRLFDocument() {
        let textView = makeFocusedTextView(text: "foo\r\nbar\r\nbaz")
        textView.lineEndings = .crlf
        textView.selectedRange = NSRange(location: 6, length: 0) // "b|ar"
        textView.deleteSelectedLines()
        let normalized = (textView.text as String).replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertEqual(normalized, "foo\nbaz")
    }

    func testUndoAfterDeleteSelectedLinesRestoresTextAndTheWholeCaretSet() {
        let textView = makeFocusedTextView(text: "a\nb\nc\nd")
        let original: [NSRange] = [
            NSRange(location: 2, length: 0), // line "b"
            NSRange(location: 6, length: 0)  // line "d"
        ]
        textView.selectedRanges = original
        textView.deleteSelectedLines()
        XCTAssertNotEqual(textView.text as String, "a\nb\nc\nd")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text as String, "a\nb\nc\nd")
        XCTAssertEqual(textView.selectedRanges, original)
    }

    // MARK: - Keyboard bindings

    func testCommandDDuplicatesTheCurrentLine() {
        let textView = makeFocusedTextView(text: "foo\nbar")
        textView.selectedRange = NSRange(location: 0, length: 0)
        send(keyEvent(keyCode: KeyCode.letterD, characters: "d", flags: .command), to: textView)
        XCTAssertEqual(textView.text as String, "foo\nfoo\nbar")
    }

    func testCommandShiftDStillReachesSelectNextOccurrence() {
        let textView = makeFocusedTextView(text: "foo foo")
        textView.selectedRange = NSRange(location: 0, length: 0)
        send(keyEvent(keyCode: KeyCode.letterD, characters: "d", flags: [.command, .shift]), to: textView)
        XCTAssertEqual(textView.text as String, "foo foo") // no mutation
        XCTAssertEqual(textView.selectedRanges, [NSRange(location: 0, length: 3)]) // word under caret
    }

    func testCommandLSelectsTheCurrentLine() {
        let textView = makeFocusedTextView(text: "foo\nbar")
        textView.selectedRange = NSRange(location: 5, length: 0)
        send(keyEvent(keyCode: KeyCode.letterL, characters: "l", flags: .command), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 3)) // "bar"
    }

    func testCommandBackspaceDeletesTheCurrentLine() {
        let textView = makeFocusedTextView(text: "foo\nbar\nbaz")
        textView.selectedRange = NSRange(location: 5, length: 0)
        send(keyEvent(keyCode: KeyCode.delete, flags: .command), to: textView)
        XCTAssertEqual(textView.text as String, "foo\nbaz")
    }

    func testCommandBackspaceIsInertInAReadOnlyTextView() {
        let textView = makeFocusedTextView(text: "foo\nbar", isEditable: false)
        textView.selectedRange = NSRange(location: 5, length: 0)
        send(keyEvent(keyCode: KeyCode.delete, flags: .command), to: textView)
        XCTAssertEqual(textView.text as String, "foo\nbar")
    }
}
