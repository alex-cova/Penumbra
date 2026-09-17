import AppKit
import XCTest
@testable import Penumbra

/// Covers keyboard-driven caret movement and selection extension on `TextView`/`TextInputView`
/// on macOS — in particular the shift-arrow "extension sticks after one step" regression, and
/// that read-only (but selectable) editors still support navigation, selection and copy.
@MainActor
final class TextViewKeyboardSelectionTests: XCTestCase {
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
}
