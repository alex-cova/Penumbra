import AppKit
import XCTest
@testable import Penumbra

@MainActor
final class TextViewMirroredEditTests: XCTestCase {
    private final class CountingDelegate: TextViewDelegate {
        var changes = 0
        var contentChanges = 0
        var selectionChanges = 0
        func textViewDidChange(_ textView: TextView) { changes += 1 }
        func textView(_ textView: TextView, didChangeContent change: TextContentChange) { contentChanges += 1 }
        func textViewDidChangeSelection(_ textView: TextView) { selectionChanges += 1 }
    }

    private func makeTextView(text: String) -> TextView {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        textView.layoutIfNeeded()
        return textView
    }

    func testEditBeforeTheCaretShiftsItAndKeepsItOnTheSameText() {
        let textView = makeTextView(text: "hello world")
        textView.selectedRange = NSRange(location: 6, length: 5)

        XCTAssertTrue(textView.applyMirroredEdit(NSRange(location: 0, length: 0), replacementText: "say "))

        XCTAssertEqual(textView.text, "say hello world")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 10, length: 5))
    }

    func testEditAfterTheCaretLeavesItAlone() {
        let textView = makeTextView(text: "hello world")
        textView.selectedRange = NSRange(location: 2, length: 0)

        XCTAssertTrue(textView.applyMirroredEdit(NSRange(location: 11, length: 0), replacementText: "!"))

        XCTAssertEqual(textView.text, "hello world!")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 0))
    }

    func testCaretInsideAReplacedRangeLandsAfterTheReplacement() {
        let textView = makeTextView(text: "hello world")
        textView.selectedRange = NSRange(location: 8, length: 0)

        XCTAssertTrue(textView.applyMirroredEdit(NSRange(location: 6, length: 5), replacementText: "you"))

        XCTAssertEqual(textView.text, "hello you")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 9, length: 0))
    }

    func testDelegateIsNotToldAndIsRestored() {
        let textView = makeTextView(text: "abc")
        let delegate = CountingDelegate()
        textView.editorDelegate = delegate

        textView.applyMirroredEdit(NSRange(location: 3, length: 0), replacementText: "d")

        XCTAssertEqual(delegate.changes, 0)
        XCTAssertEqual(delegate.contentChanges, 0)
        XCTAssertTrue(textView.editorDelegate === delegate)

        textView.replace(NSRange(location: 0, length: 0), withText: "x")
        XCTAssertEqual(delegate.contentChanges, 1, "later edits are reported again")
    }

    func testRejectsARangeOutsideTheText() {
        let textView = makeTextView(text: "abc")
        XCTAssertFalse(textView.applyMirroredEdit(NSRange(location: 2, length: 5), replacementText: "x"))
        XCTAssertEqual(textView.text, "abc")
    }

    func testMirroringEveryEditKeepsTwoViewsIdentical() {
        let source = makeTextView(text: "one\ntwo\nthree")
        let mirror = makeTextView(text: "one\ntwo\nthree")
        final class Forwarder: TextViewDelegate {
            let target: TextView
            init(target: TextView) { self.target = target }
            func textView(_ textView: TextView, didChangeContent change: TextContentChange) {
                target.applyMirroredEdit(change.range, replacementText: change.replacementText)
            }
        }
        let forwarder = Forwarder(target: mirror)
        source.editorDelegate = forwarder

        source.selectedRange = NSRange(location: 3, length: 0)
        source.insertText("!")
        source.insertText("\n")
        source.selectedRange = NSRange(location: 0, length: 4)
        source.deleteBackward()

        XCTAssertEqual(mirror.text, source.text)
    }
}
