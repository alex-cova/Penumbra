import AppKit
import XCTest
@testable import Penumbra

/// The caret's painted frame follows ``TextView/caretShape``. ``caretRect(at:)`` stays the thin
/// bar so selection and popups do not move.
@MainActor
final class CaretShapeTests: XCTestCase {
    func testBarBlockAndUnderlineFrames() throws {
        let textView = makeFocusedTextView(text: "W")
        let characterWidth = textView.caretRect(at: 1).minX - textView.caretRect(at: 0).minX
        let bar = textView.caretRect(at: 0)
        XCTAssertGreaterThan(characterWidth, Caret.width)

        textView.caretShape = .bar
        let barCaret = try XCTUnwrap(caret(in: textView))
        XCTAssertEqual(barCaret.frame.width, Caret.width, accuracy: 0.5)
        XCTAssertEqual(barCaret.frame.height, bar.height, accuracy: 0.5)
        XCTAssertEqual(barCaret.coveredText, "")

        textView.caretShape = .block
        let block = try XCTUnwrap(caret(in: textView))
        block.displayIfNeeded()
        XCTAssertEqual(block.frame.width, characterWidth, accuracy: 0.5)
        XCTAssertEqual(block.frame.height, bar.height, accuracy: 0.5)
        XCTAssertEqual(block.frame.minX, bar.minX, accuracy: 0.5)
        XCTAssertEqual(block.coveredText, "W")
        XCTAssertEqual(textView.caretRect(at: 0).width, Caret.width, accuracy: 0.5)

        textView.selectedRange = NSRange(location: 1, length: 0)
        let endBlock = try XCTUnwrap(caret(in: textView))
        XCTAssertEqual(endBlock.frame.width, characterWidth, accuracy: 0.5)
        XCTAssertEqual(endBlock.coveredText, "")

        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.caretShape = .underline
        let underline = try XCTUnwrap(caret(in: textView))
        XCTAssertEqual(underline.frame.width, characterWidth, accuracy: 0.5)
        XCTAssertEqual(underline.frame.height, Caret.width, accuracy: 0.5)
        XCTAssertGreaterThan(underline.frame.minY, bar.midY)
        XCTAssertLessThanOrEqual(underline.frame.maxY, bar.maxY + 0.5)
    }

    func testBlockCaretCoversOneGrapheme() throws {
        let textView = makeFocusedTextView(text: "👍x")
        textView.caretShape = .block
        let block = try XCTUnwrap(caret(in: textView))
        XCTAssertEqual(block.coveredText, "👍")
        let next = textView.caretRect(at: ("👍" as NSString).length)
        XCTAssertEqual(block.frame.width, next.minX - textView.caretRect(at: 0).minX, accuracy: 0.5)
    }

    func testTabBlockIsWiderThanTheBarAndDrawsNoGlyph() throws {
        let textView = makeFocusedTextView(text: "\tx")
        textView.caretShape = .block
        let block = try XCTUnwrap(caret(in: textView))
        XCTAssertGreaterThan(block.frame.width, Caret.width * 2)
        XCTAssertEqual(block.coveredText, "")
    }

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

    private func caret(in root: NSView) -> CaretView? {
        if let caret = root as? CaretView, !caret.isHidden, caret.frame.height > 0 {
            return caret
        }
        for subview in root.subviews {
            if let caret = caret(in: subview) {
                return caret
            }
        }
        return nil
    }
}
