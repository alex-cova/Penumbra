import AppKit
import XCTest
@testable import Penumbra

@MainActor
final class CaseToggleTests: XCTestCase {
    private func makeFocusedTextView(text: String) -> TextView {
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
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.focusTextInput())
        return textView
    }

    func testTogglesSelectedText() {
        let textView = makeFocusedTextView(text: "hello")
        textView.selectedRange = NSRange(location: 0, length: 5)
        textView.toggleCase()
        XCTAssertEqual(textView.text, "HELLO")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 5))
    }

    func testTogglesWordAtCaretWhenSelectionIsEmpty() {
        let textView = makeFocusedTextView(text: "say hello there")
        textView.selectedRange = NSRange(location: 7, length: 0)
        textView.toggleCase()
        XCTAssertEqual(textView.text, "say HELLO there")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 5))
    }

    func testRunsPerCaretIndependently() {
        let textView = makeFocusedTextView(text: "foo bar")
        textView.selectedRanges = [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3)
        ]
        textView.toggleCase()
        XCTAssertEqual(textView.text, "FOO BAR")
    }

    func testKeyboardShortcutCommandShiftU() {
        let textView = makeFocusedTextView(text: "hello")
        textView.selectedRange = NSRange(location: 0, length: 5)
        XCTAssertTrue(textView.perform(.toggleCase))
        XCTAssertEqual(textView.text, "HELLO")
    }

    func testIsOneUndoStep() {
        let textView = makeFocusedTextView(text: "hello")
        textView.selectedRange = NSRange(location: 0, length: 5)
        textView.toggleCase()
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, "hello")
    }
}
