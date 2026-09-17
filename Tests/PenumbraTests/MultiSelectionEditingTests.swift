import AppKit
import XCTest
@testable import Penumbra

/// Covers multi-cursor-aware editing operations that used to be (or, for copy/cut/paste, still
/// silently were) single-selection only: indent/outdent, move-line, newline insertion,
/// copy/cut/paste, and that undo restores the whole caret set rather than collapsing to one.
@MainActor
final class MultiSelectionEditingTests: XCTestCase {
    private func performResponderAction(_ selectorName: String, on textView: TextView) {
        let selector = NSSelectorFromString(selectorName)
        _ = textView.window?.firstResponder?.tryToPerform(selector, with: nil)
    }

    // MARK: - Indent / Outdent

    func testShiftRightIndentsEveryLineTouchedByNonAdjacentCaretGroups() {
        let textView = makeFocusedTextView(text: "one\ntwo\nthree\nfour")
        textView.indentStrategy = .space(length: 2)
        // Two separate groups: a caret on line 0, and carets spanning lines 2-3.
        textView.selectedRanges = [
            NSRange(location: 0, length: 0),
            NSRange(location: 8, length: 0), // start of "three"
            NSRange(location: 14, length: 0) // start of "four"
        ]
        textView.shiftRight()
        XCTAssertEqual(textView.text as String, "  one\ntwo\n  three\n  four")
    }

    func testShiftLeftOutdentsOnlyLinesThatHaveThePrefix() {
        let textView = makeFocusedTextView(text: "  one\ntwo\n  three")
        textView.indentStrategy = .space(length: 2)
        textView.selectedRanges = [
            NSRange(location: 0, length: 0), // "  one" -- has the prefix
            NSRange(location: 6, length: 0), // "two" -- no prefix, no-op
            NSRange(location: 10, length: 0) // "  three" -- has the prefix
        ]
        textView.shiftLeft()
        XCTAssertEqual(textView.text as String, "one\ntwo\nthree")
    }

    func testShiftRightPreservesCaretColumnsAfterIndenting() {
        let textView = makeFocusedTextView(text: "abc\ndef")
        textView.indentStrategy = .space(length: 2)
        textView.selectedRanges = [
            NSRange(location: 1, length: 0), // "a|bc"
            NSRange(location: 6, length: 0)  // "de|f"
        ]
        textView.shiftRight()
        XCTAssertEqual(textView.text as String, "  abc\n  def")
        // Both carets should have shifted right by the inserted indent length (2), preserving
        // their column within the line rather than landing at some fixed offset.
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 3, length: 0), // "  a|bc"
            NSRange(location: 10, length: 0) // "  de|f"
        ])
    }

    // MARK: - Move Lines

    func testMoveLinesDownOntoCRLFFileWithoutTrailingNewlineKeepsMovedText() {
        let textView = makeFocusedTextView(text: "foo\r\nbar\r\nbaz")
        textView.lineEndings = .crlf
        // Select the "bar" line including its CRLF (location 5, length 5: bar\r\n).
        textView.selectedRange = NSRange(location: 5, length: 5)
        textView.moveSelectedLinesDown()
        let normalized = (textView.text as String).replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertEqual(normalized, "foo\nbaz\nbar")
    }

    func testShiftRightOnFullLineDoesNotIndentTheFollowingLine() {
        let textView = makeFocusedTextView(text: "foo\nbar")
        textView.indentStrategy = .space(length: 4)
        textView.selectedRange = NSRange(location: 0, length: 4)
        textView.shiftRight()
        XCTAssertEqual(textView.text as String, "    foo\nbar")
    }

    func testMoveSelectedLinesDownWithTwoNonAdjacentCaretGroups() {
        let textView = makeFocusedTextView(text: "a\nb\nc\nd\ne")
        textView.selectedRanges = [
            NSRange(location: 0, length: 0), // line "a"
            NSRange(location: 4, length: 0)  // line "c"
        ]
        textView.moveSelectedLinesDown()
        XCTAssertEqual(textView.text as String, "b\na\nd\nc\ne")
    }

    func testMoveSelectedLinesUpWithTwoNonAdjacentCaretGroups() {
        let textView = makeFocusedTextView(text: "a\nb\nc\nd\ne")
        textView.selectedRanges = [
            NSRange(location: 2, length: 0), // line "b"
            NSRange(location: 6, length: 0)  // line "d"
        ]
        textView.moveSelectedLinesUp()
        XCTAssertEqual(textView.text as String, "b\na\nd\nc\ne")
    }

    func testMoveSelectedLinesUpAbortsEntirelyWhenAnyGroupIsAtTheDocumentEdge() {
        let textView = makeFocusedTextView(text: "a\nb\nc")
        textView.selectedRanges = [
            NSRange(location: 0, length: 0), // already the first line -- can't move up
            NSRange(location: 4, length: 0)
        ]
        textView.moveSelectedLinesUp()
        XCTAssertEqual(textView.text as String, "a\nb\nc")
    }

    // MARK: - Newline

    func testNewlineAtMultipleCaretsInsertsAtEverySite() {
        let textView = makeFocusedTextView(text: "ab ab ab")
        textView.selectedRanges = [
            NSRange(location: 1, length: 0),
            NSRange(location: 4, length: 0),
            NSRange(location: 7, length: 0)
        ]
        textView.insertText("\n")
        XCTAssertEqual(textView.text as String, "a\nb a\nb a\nb")
        // Sites are applied highest-location-first (1, then 4, then 7 -- the original offsets),
        // so each caret lands one past where its own "\n" was inserted, unaffected by the edits
        // still to come further left.
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 2, length: 0),
            NSRange(location: 5, length: 0),
            NSRange(location: 8, length: 0)
        ])
        XCTAssertTrue(textView.isMultiCursorActive)
    }

    // MARK: - Copy / Cut / Paste

    func testCopyAtMultipleSelectionsJoinsWithLineEnding() {
        let pasteboardBackup = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let pasteboardBackup {
                NSPasteboard.general.setString(pasteboardBackup, forType: .string)
            }
        }
        let textView = makeFocusedTextView(text: "foo bar baz")
        textView.selectedRanges = [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3)
        ]
        performResponderAction("copy:", on: textView)
        XCTAssertEqual(UIPasteboard.general.string, "foo\nbaz")
    }

    func testCutAtMultipleSelectionsRemovesEveryRange() {
        let pasteboardBackup = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let pasteboardBackup {
                NSPasteboard.general.setString(pasteboardBackup, forType: .string)
            }
        }
        let textView = makeFocusedTextView(text: "foo bar baz")
        textView.selectedRanges = [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3)
        ]
        performResponderAction("cut:", on: textView)
        XCTAssertEqual(textView.text as String, " bar ")
        XCTAssertEqual(UIPasteboard.general.string, "foo\nbaz")
    }

    func testPasteDistributesOneLinePerCaretWhenLineCountMatches() {
        let pasteboardBackup = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let pasteboardBackup {
                NSPasteboard.general.setString(pasteboardBackup, forType: .string)
            }
        }
        UIPasteboard.general.string = "X\nY"
        let textView = makeFocusedTextView(text: "aa\nbb")
        textView.selectedRanges = [
            NSRange(location: 0, length: 0),
            NSRange(location: 3, length: 0)
        ]
        performResponderAction("paste:", on: textView)
        XCTAssertEqual(textView.text as String, "Xaa\nYbb")
    }

    func testPasteInsertsWholeClipboardAtEveryCaretWhenLineCountDoesNotMatch() {
        let pasteboardBackup = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let pasteboardBackup {
                NSPasteboard.general.setString(pasteboardBackup, forType: .string)
            }
        }
        UIPasteboard.general.string = "Z"
        let textView = makeFocusedTextView(text: "aa bb")
        textView.selectedRanges = [
            NSRange(location: 0, length: 0),
            NSRange(location: 3, length: 0)
        ]
        performResponderAction("paste:", on: textView)
        XCTAssertEqual(textView.text as String, "Zaa Zbb")
    }

    // MARK: - Undo restores the whole caret set

    func testUndoAfterMultiCaretInsertRestoresAllCarets() {
        let textView = makeFocusedTextView(text: "ab ab ab")
        textView.selectedRanges = [
            NSRange(location: 0, length: 0),
            NSRange(location: 3, length: 0),
            NSRange(location: 6, length: 0)
        ]
        textView.insertText("X")
        XCTAssertEqual(textView.text as String, "Xab Xab Xab")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text as String, "ab ab ab")
        XCTAssertEqual(textView.selectedRanges, [
            NSRange(location: 0, length: 0),
            NSRange(location: 3, length: 0),
            NSRange(location: 6, length: 0)
        ])
    }

    func testUndoAfterMultiCaretIndentRestoresAllCarets() {
        let textView = makeFocusedTextView(text: "one\ntwo\nthree")
        textView.indentStrategy = .space(length: 2)
        let original: [NSRange] = [
            NSRange(location: 0, length: 0),
            NSRange(location: 4, length: 0),
            NSRange(location: 8, length: 0)
        ]
        textView.selectedRanges = original
        textView.shiftRight()
        XCTAssertNotEqual(textView.text as String, "one\ntwo\nthree")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text as String, "one\ntwo\nthree")
        XCTAssertEqual(textView.selectedRanges, original)
    }
}
