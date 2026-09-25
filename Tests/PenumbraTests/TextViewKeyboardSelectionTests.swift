import AppKit
import XCTest
@testable import Penumbra

/// Covers keyboard-driven caret movement and selection extension on `TextView`/`TextInputView`
/// on macOS — in particular the shift-arrow "extension sticks after one step" regression, and
/// that read-only (but selectable) editors still support navigation, selection and copy.
@MainActor
final class TextViewKeyboardSelectionTests: XCTestCase {
    /// Arrow keys set the selection through `selectedTextRange`, whose delegate notification is
    /// delivered from `layoutSubviews`. A caret move must still schedule that layout.
    func testArrowKeyCaretMoveNotifiesDelegate() {
        let textView = makeFocusedTextView(text: "hello world")
        let delegate = SelectionCountingDelegate()
        textView.editorDelegate = delegate
        textView.selectedRange = NSRange(location: 0, length: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let before = delegate.selectionChanges

        send(keyEvent(keyCode: TestKeyCode.rightArrow), to: textView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(textView.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertGreaterThan(delegate.selectionChanges, before, "the host never heard about the caret move")
    }

    private typealias KeyCode = TestKeyCode

    // MARK: - Shift-arrow extension (regression: stuck after one step)

    func testShiftRightArrowExtendsSelectionRepeatedly() {
        let textView = makeFocusedTextView(text: "hello world")
        textView.selectedRange = NSRange(location: 0, length: 0)

        for _ in 0..<3 {
            send(keyEvent(keyCode: KeyCode.rightArrow, flags: .shift), to: textView)
        }

        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 3))
    }

    func testShiftLeftArrowShrinksThenExtendsTheOtherWay() {
        let textView = makeFocusedTextView(text: "hello world")
        textView.selectedRange = NSRange(location: 5, length: 0)

        for _ in 0..<3 {
            send(keyEvent(keyCode: KeyCode.rightArrow, flags: .shift), to: textView)
        }
        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 3))

        for _ in 0..<3 {
            send(keyEvent(keyCode: KeyCode.leftArrow, flags: .shift), to: textView)
        }
        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 0))

        for _ in 0..<3 {
            send(keyEvent(keyCode: KeyCode.leftArrow, flags: .shift), to: textView)
        }
        XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 3))
    }

    func testShiftOptionRightArrowExtendsByWord() {
        let textView = makeFocusedTextView(text: "hello world today")
        textView.selectedRange = NSRange(location: 0, length: 0)

        send(keyEvent(keyCode: KeyCode.rightArrow, flags: [.shift, .option]), to: textView)
        send(keyEvent(keyCode: KeyCode.rightArrow, flags: [.shift, .option]), to: textView)

        XCTAssertEqual(textView.selectedRange.location, 0)
        // Selection should have grown to cover "hello world" (both words), not be stuck
        // after the first extension.
        XCTAssertGreaterThan(textView.selectedRange.length, 5)
        XCTAssertLessThanOrEqual(textView.selectedRange.upperBound, 12)
    }

    func testShiftCommandRightArrowExtendsToEndOfLine() {
        let textView = makeFocusedTextView(text: "hello world")
        textView.selectedRange = NSRange(location: 0, length: 0)

        send(keyEvent(keyCode: KeyCode.rightArrow, flags: [.shift, .command]), to: textView)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 11))
    }

    func testPlainRightArrowWithExistingSelectionCollapsesToUpperBound() {
        let textView = makeFocusedTextView(text: "hello world")
        textView.selectedRange = NSRange(location: 2, length: 3)

        send(keyEvent(keyCode: KeyCode.rightArrow), to: textView)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 0))
    }

    func testPlainLeftArrowWithExistingSelectionCollapsesToLocation() {
        let textView = makeFocusedTextView(text: "hello world")
        textView.selectedRange = NSRange(location: 2, length: 3)

        send(keyEvent(keyCode: KeyCode.leftArrow), to: textView)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 0))
    }

    // MARK: - Read-only (selectable, non-editable) editors

    func testReadOnlyEditorSupportsArrowNavigation() {
        let textView = makeFocusedTextView(text: "hello world", isEditable: false)
        textView.selectedRange = NSRange(location: 0, length: 0)

        send(keyEvent(keyCode: KeyCode.rightArrow), to: textView)
        send(keyEvent(keyCode: KeyCode.rightArrow), to: textView)

        XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 0))
    }

    func testReadOnlyEditorSupportsShiftSelection() {
        let textView = makeFocusedTextView(text: "hello world", isEditable: false)
        textView.selectedRange = NSRange(location: 0, length: 0)

        for _ in 0..<4 {
            send(keyEvent(keyCode: KeyCode.rightArrow, flags: .shift), to: textView)
        }

        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 4))
    }

    func testReadOnlyEditorDoesNotInsertText() {
        let textView = makeFocusedTextView(text: "hello world", isEditable: false)
        textView.selectedRange = NSRange(location: 0, length: 0)

        send(keyEvent(keyCode: KeyCode.letterA, characters: "a"), to: textView)

        XCTAssertEqual(textView.text, "hello world")
    }

    func testReadOnlyEditorShowsCaret() {
        let textView = makeFocusedTextView(text: "hello world", isEditable: false)

        XCTAssertTrue(textView.isEditing)
        XCTAssertNotNil(visibleCaret(in: textView))
    }

    /// Opening a non-editable document (a JDK class) used to end the caret session while
    /// leaving the text input as first responder. The next focus was then a no-op, so the
    /// caret stayed hidden in that file and in every editable file opened afterwards.
    func testCaretSurvivesBecomingReadOnlyAndBack() {
        let textView = makeFocusedTextView(text: "hello world")
        let responder = textView.window?.firstResponder
        XCTAssertNotNil(visibleCaret(in: textView))

        textView.isEditable = false
        XCTAssertTrue(textView.focusTextInput())
        XCTAssertTrue(textView.window?.firstResponder === responder)
        XCTAssertTrue(textView.isEditing)
        XCTAssertNotNil(visibleCaret(in: textView))

        send(keyEvent(keyCode: KeyCode.letterA, characters: "a"), to: textView)
        XCTAssertEqual(textView.text, "hello world")

        textView.isEditable = true
        XCTAssertTrue(textView.focusTextInput())
        XCTAssertTrue(textView.window?.firstResponder === responder)
        XCTAssertTrue(textView.isEditing)
        XCTAssertNotNil(visibleCaret(in: textView))
    }

    func testCommandZUndoesAndCommandShiftZRedoes() {
        let textView = makeFocusedTextView(text: "hello")
        textView.selectedRange = NSRange(location: 5, length: 0)
        textView.insertText("!")

        XCTAssertEqual(textView.text, "hello!")
        XCTAssertTrue(textView.undoManager?.canUndo ?? false)

        send(keyEvent(keyCode: KeyCode.letterZ, characters: "z", flags: .command), to: textView)
        XCTAssertEqual(textView.text, "hello")

        send(keyEvent(keyCode: KeyCode.letterZ, characters: "z", flags: [.command, .shift]), to: textView)
        XCTAssertEqual(textView.text, "hello!")
    }

    func testResponderChainUndoAndRedo() {
        let textView = makeFocusedTextView(text: "hello")
        textView.selectedRange = NSRange(location: 5, length: 0)
        textView.insertText("!")

        let responder = textView.window?.firstResponder
        XCTAssertTrue(responder?.responds(to: #selector(TextInputView.undoFromResponderChain(_:))) ?? false)
        XCTAssertTrue(responder?.responds(to: #selector(TextInputView.redoFromResponderChain(_:))) ?? false)

        responder?.perform(#selector(TextInputView.undoFromResponderChain(_:)), with: nil)
        XCTAssertEqual(textView.text, "hello")
        responder?.perform(#selector(TextInputView.redoFromResponderChain(_:)), with: nil)
        XCTAssertEqual(textView.text, "hello!")
    }

    func testReadOnlyEditorDoesNotPaste() {
        let pasteboardBackup = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let pasteboardBackup {
                NSPasteboard.general.setString(pasteboardBackup, forType: .string)
            }
        }
        let textView = makeFocusedTextView(text: "hello world", isEditable: false)
        textView.selectedRange = NSRange(location: 0, length: 0)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("pasted", forType: .string)

        (textView.window?.firstResponder as? TextInputView)?.paste(nil)

        XCTAssertEqual(textView.text, "hello world")
    }

    private func visibleCaret(in view: NSView) -> CaretView? {
        if let caret = view as? CaretView, !caret.isHidden, caret.frame.height > 0 {
            return caret
        }
        for subview in view.subviews {
            if let caret = visibleCaret(in: subview) {
                return caret
            }
        }
        return nil
    }
}

private final class SelectionCountingDelegate: TextViewDelegate {
    var selectionChanges = 0

    func textViewDidChangeSelection(_ textView: TextView) {
        selectionChanges += 1
    }
}
