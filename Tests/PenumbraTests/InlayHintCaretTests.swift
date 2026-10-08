@preconcurrency import AppKit
import EditorIntelligence
import XCTest
@testable import Penumbra

/// An inlay hint is a chip drawn between two characters. The caret steps in front of it and then
/// behind it, a click on the chip lands at the hint, and selections and block carets stop short of it.
@MainActor
final class InlayHintCaretTests: XCTestCase {
    private let text = "call(1, 2);"
    private let hintOffset = 5

    private func makeTextView(shape: CaretShape = .bar) -> TextView {
        let textView = makeFocusedTextView(text: text)
        textView.caretShape = shape
        textView.inlayHints = [InlayHint(utf16Offset: hintOffset, label: "count:")]
        textView.layoutIfNeeded()
        textView.selectedRange = NSRange(location: 4, length: 0)
        return textView
    }

    private func press(_ keyCode: UInt16, in textView: TextView) {
        send(keyEvent(keyCode: keyCode), to: textView)
    }

    private func width(_ textView: TextView) -> CGFloat {
        textView.inlayHintAppearanceForTesting.width(of: "count:")
    }

    private func caret(in textView: TextView) -> CaretView? {
        func find(_ view: NSView) -> CaretView? {
            if let caret = view as? CaretView, !caret.isHidden, caret.frame.height > 0 { return caret }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(textView)
    }

    func testRightArrowStopsInFrontOfTheChipThenBehindIt() throws {
        let textView = makeTextView()
        let behind = textView.caretRectInViewport(at: hintOffset).minX

        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: hintOffset, length: 0))
        XCTAssertTrue(textView.stickyLinesInput.caretIsBeforeInlayHint)
        XCTAssertEqual(try XCTUnwrap(caret(in: textView)).frame.minX, behind - width(textView), accuracy: 1,
                       "drawn in front of the chip")

        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: hintOffset, length: 0), "same offset, other side")
        XCTAssertFalse(textView.stickyLinesInput.caretIsBeforeInlayHint)
        XCTAssertEqual(try XCTUnwrap(caret(in: textView)).frame.minX, behind, accuracy: 1)

        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: hintOffset + 1, length: 0))
    }

    func testLeftArrowStopsBehindTheChipThenInFrontOfIt() {
        let textView = makeTextView()
        textView.selectedRange = NSRange(location: hintOffset + 1, length: 0)

        press(TestKeyCode.leftArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: hintOffset, length: 0))
        XCTAssertFalse(textView.stickyLinesInput.caretIsBeforeInlayHint, "arrives behind the chip")

        press(TestKeyCode.leftArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: hintOffset, length: 0))
        XCTAssertTrue(textView.stickyLinesInput.caretIsBeforeInlayHint)

        press(TestKeyCode.leftArrow, in: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: hintOffset - 1, length: 0))
        XCTAssertFalse(textView.stickyLinesInput.caretIsBeforeInlayHint)
    }

    func testOtherSelectionChangesPutTheCaretBehindTheChip() {
        let textView = makeTextView()
        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertTrue(textView.stickyLinesInput.caretIsBeforeInlayHint)

        textView.selectedRange = NSRange(location: 2, length: 0)
        XCTAssertFalse(textView.stickyLinesInput.caretIsBeforeInlayHint)
    }

    func testArrowsWithoutHintsMoveOneCharacterAsBefore() {
        let textView = makeFocusedTextView(text: text)
        textView.selectedRange = NSRange(location: 4, length: 0)
        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertEqual(textView.selectedRange.location, 5)
        press(TestKeyCode.rightArrow, in: textView)
        XCTAssertEqual(textView.selectedRange.location, 6)
    }

    // MARK: - Clicks

    func testClickOnTheChipPutsTheCaretAtTheHint() throws {
        let textView = makeTextView()
        let rect = textView.caretRectInViewport(at: hintOffset)
        let chipMiddle = rect.minX - width(textView) / 2

        let index = try XCTUnwrap(textView.characterIndex(at: CGPoint(x: chipMiddle, y: rect.midY)))
        XCTAssertEqual(index, hintOffset)
    }

    func testClickOnTheCharacterBeforeTheChipSplitsAtTheMiddleOfTheCharacterAlone() throws {
        let textView = makeTextView()
        let rect = textView.caretRectInViewport(at: hintOffset)
        let characterStart = textView.caretRectInViewport(at: hintOffset - 1).minX
        let characterEnd = rect.minX - width(textView)
        let quarter = characterStart + (characterEnd - characterStart) * 0.25
        let threeQuarters = characterStart + (characterEnd - characterStart) * 0.75

        XCTAssertEqual(try XCTUnwrap(textView.characterIndex(at: CGPoint(x: quarter, y: rect.midY))), hintOffset - 1)
        XCTAssertEqual(try XCTUnwrap(textView.characterIndex(at: CGPoint(x: threeQuarters, y: rect.midY))), hintOffset)
    }

    // MARK: - Geometry

    func testBlockCaretOnTheCharacterBeforeTheChipIsOneCharacterWide() throws {
        let textView = makeTextView(shape: .block)
        textView.selectedRange = NSRange(location: hintOffset - 1, length: 0)
        let block = try XCTUnwrap(caret(in: textView))
        let character = textView.caretRectInViewport(at: hintOffset).minX - width(textView)
            - textView.caretRectInViewport(at: hintOffset - 1).minX
        XCTAssertEqual(block.frame.width, character, accuracy: 1)
    }

    func testSelectionEndingAtTheHintStopsInFrontOfTheChip() {
        let textView = makeTextView()
        textView.selectedRange = NSRange(location: 0, length: hintOffset)
        textView.layoutIfNeeded()

        let maxX = textView.selectionRectsForTesting.map(\.rect.maxX).max() ?? 0
        let behind = textView.caretRectInViewport(at: hintOffset).minX
        XCTAssertEqual(maxX, behind - width(textView), accuracy: 1.5)
    }

    func testAControllerMadeOutsideLayoutAlreadyHasItsHints() throws {
        let long = (0 ..< 400).map { _ in "call(1, 2);" }.joined(separator: "\n")
        let textView = makeFocusedTextView(text: long)
        textView.inlayHints = (0 ..< 400).map { InlayHint(utf16Offset: $0 * 12 + 5, label: "count:") }
        textView.layoutIfNeeded()
        let input = textView.stickyLinesInput

        // A caret query far from the viewport builds a controller outside the layout pass.
        let before = input.lineControllerCount
        _ = textView.caretRectInViewport(at: 350 * 12 + 6)
        XCTAssertGreaterThan(input.lineControllerCount, before, "the query built a controller")
        XCTAssertTrue(input.lineControllerHasInlayHintsForTesting(atRow: 350))
    }
}
