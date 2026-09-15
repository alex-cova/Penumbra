import AppKit
import TestTreeSitterLanguages
import XCTest
@testable import Runestone

/// Integration coverage for `TextView.toggleComment()` (⌘/), `insertLineAbove()`/
/// `insertLineBelow()` (⌘⇧⏎ / ⌘⏎), and `sortSelectedLinesAscending()`/`sortSelectedLinesDescending()`
/// — each multi-caret aware, one undo step. Mirrors `LineOperationsTests`' shape.
@MainActor
final class LineCommentAndInsertLineTests: XCTestCase {
    private typealias KeyCode = TestKeyCode

    private func makeFocusedTextView(text: String, commentPrefix: String? = "//") -> TextView {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.isEditable = true
        textView.isSelectable = true
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        if let commentPrefix {
            let language = TreeSitterLanguage(tree_sitter_javascript(), lineCommentPrefix: commentPrefix)
            textView.setState(TextViewState(text: text, theme: DefaultTheme(), language: language))
        } else {
            textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        }
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.focusTextInput())
        return textView
    }

    // MARK: - Toggle Comment

    func testTogglesAnUncommentedLineOn() {
        let textView = makeFocusedTextView(text: "let x = 1")
        textView.selectedRange = NSRange(location: 4, length: 0)
        textView.toggleComment()
        XCTAssertEqual(textView.text, "// let x = 1")
    }

    func testTogglingTwiceReturnsToTheOriginalText() {
        let textView = makeFocusedTextView(text: "let x = 1")
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.toggleComment()
        textView.toggleComment()
        XCTAssertEqual(textView.text, "let x = 1")
    }

    func testCommentsAtTheIndentLevel() {
        let textView = makeFocusedTextView(text: "    let x = 1")
        textView.selectedRange = NSRange(location: 8, length: 0)
        textView.toggleComment()
        XCTAssertEqual(textView.text, "    // let x = 1")
    }

    func testCommentsEveryLineTouchedByAMultiLineSelection() {
        let textView = makeFocusedTextView(text: "a\nb\nc")
        textView.selectedRange = NSRange(location: 0, length: 5) // whole document
        textView.toggleComment()
        XCTAssertEqual(textView.text, "// a\n// b\n// c")
    }

    func testRunsPerCaretWhenMultipleSelectionsAreActive() {
        let textView = makeFocusedTextView(text: "a\nb\nc")
        textView.selectedRanges = [
            NSRange(location: 0, length: 0), // "a"
            NSRange(location: 4, length: 0)  // "c"
        ]
        textView.toggleComment()
        XCTAssertEqual(textView.text, "// a\nb\n// c")
    }

    func testIsOneUndoStep() {
        let textView = makeFocusedTextView(text: "a\nb\nc")
        textView.selectedRange = NSRange(location: 0, length: 5)
        textView.toggleComment()
        XCTAssertEqual(textView.text, "// a\n// b\n// c")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "a\nb\nc")
    }

    func testCaretStaysAtTheEquivalentPositionAfterTheEditNotInsideTheIndent() {
        let textView = makeFocusedTextView(text: "let x = 1")
        textView.selectedRange = NSRange(location: 4, length: 0) // caret right after "let "
        textView.toggleComment()
        // "// " (3 chars) was inserted before column 0, so the caret shifts by 3.
        XCTAssertEqual(textView.selectedRange, NSRange(location: 7, length: 0))
    }

    func testIsANoOpWithNoCommentPrefixConfigured() {
        let textView = makeFocusedTextView(text: "let x = 1", commentPrefix: nil)
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.toggleComment()
        XCTAssertEqual(textView.text, "let x = 1")
    }

    func testKeyboardShortcutCommandSlashTogglesComment() {
        let textView = makeFocusedTextView(text: "let x = 1")
        textView.selectedRange = NSRange(location: 0, length: 0)
        send(keyEvent(keyCode: 0x2C /* "/" */, characters: "/", flags: .command), to: textView)
        XCTAssertEqual(textView.text, "// let x = 1")
    }

    // MARK: - Insert Line Above / Below

    func testInsertLineBelowAddsABlankLineAndMovesTheCaretOntoIt() {
        let textView = makeFocusedTextView(text: "foo\nbar", commentPrefix: nil)
        textView.selectedRange = NSRange(location: 1, length: 0) // "f|oo"
        textView.insertLineBelow()
        XCTAssertEqual(textView.text, "foo\n\nbar")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0))
    }

    func testInsertLineAboveAddsABlankLineAndMovesTheCaretOntoIt() {
        let textView = makeFocusedTextView(text: "foo\nbar", commentPrefix: nil)
        textView.selectedRange = NSRange(location: 5, length: 0) // "b|ar"
        textView.insertLineAbove()
        XCTAssertEqual(textView.text, "foo\n\nbar")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0))
    }

    func testInsertLineBelowMatchesTheCurrentLinesIndentation() {
        let textView = makeFocusedTextView(text: "    foo\nbar", commentPrefix: nil)
        textView.selectedRange = NSRange(location: 5, length: 0)
        textView.insertLineBelow()
        XCTAssertEqual(textView.text, "    foo\n    \nbar")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 12, length: 0))
    }

    func testInsertLineBelowOnTheFinalLineWithNoTrailingNewlineStillWorks() {
        let textView = makeFocusedTextView(text: "foo", commentPrefix: nil)
        textView.selectedRange = NSRange(location: 1, length: 0)
        textView.insertLineBelow()
        XCTAssertEqual(textView.text, "foo\n")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0))
    }

    func testInsertLineAboveOnTheFirstLineWorks() {
        let textView = makeFocusedTextView(text: "foo", commentPrefix: nil)
        textView.selectedRange = NSRange(location: 1, length: 0)
        textView.insertLineAbove()
        XCTAssertEqual(textView.text, "\nfoo")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))
    }

    func testInsertLineBelowRunsPerCaretAndIsOneUndoStep() {
        let textView = makeFocusedTextView(text: "a\nb\nc", commentPrefix: nil)
        textView.selectedRanges = [
            NSRange(location: 0, length: 0), // "a"
            NSRange(location: 4, length: 0)  // "c"
        ]
        textView.insertLineBelow()
        XCTAssertEqual(textView.text, "a\n\nb\nc\n")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "a\nb\nc")
    }

    func testKeyboardShortcutCommandReturnInsertsLineBelow() {
        let textView = makeFocusedTextView(text: "foo", commentPrefix: nil)
        textView.selectedRange = NSRange(location: 1, length: 0)
        send(keyEvent(keyCode: KeyCode.returnKey, flags: .command), to: textView)
        XCTAssertEqual(textView.text, "foo\n")
    }

    func testKeyboardShortcutCommandShiftReturnInsertsLineAbove() {
        let textView = makeFocusedTextView(text: "foo", commentPrefix: nil)
        textView.selectedRange = NSRange(location: 1, length: 0)
        send(keyEvent(keyCode: KeyCode.returnKey, flags: [.command, .shift]), to: textView)
        XCTAssertEqual(textView.text, "\nfoo")
    }

    // MARK: - Sort Lines

    func testSortsSelectedLinesAscending() {
        let textView = makeFocusedTextView(text: "banana\napple\ncherry", commentPrefix: nil)
        textView.selectedRange = NSRange(location: 0, length: 19) // whole document
        textView.sortSelectedLinesAscending()
        XCTAssertEqual(textView.text, "apple\nbanana\ncherry")
    }

    func testSortsSelectedLinesDescending() {
        let textView = makeFocusedTextView(text: "banana\napple\ncherry", commentPrefix: nil)
        textView.selectedRange = NSRange(location: 0, length: 19)
        textView.sortSelectedLinesDescending()
        XCTAssertEqual(textView.text, "cherry\nbanana\napple")
    }

    func testSortWithASingleLineSelectionIsANoOp() {
        let textView = makeFocusedTextView(text: "only line", commentPrefix: nil)
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.sortSelectedLinesAscending()
        XCTAssertEqual(textView.text, "only line")
    }

    func testSortIsOneUndoStep() {
        let textView = makeFocusedTextView(text: "b\na\nc", commentPrefix: nil)
        textView.selectedRange = NSRange(location: 0, length: 5)
        textView.sortSelectedLinesAscending()
        XCTAssertEqual(textView.text, "a\nb\nc")
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "b\na\nc")
    }
}
