import AppKit
import QuartzCore
import XCTest
@testable import Penumbra

/// The caret blinks with a Core Animation opacity animation that restarts whenever the caret
/// moves or text is typed, and glides to its new place when smooth movement is on.
@MainActor
final class CaretBlinkTests: XCTestCase {
    func testCaretBlinksWithTheConfiguredInterval() throws {
        let textView = makeFocusedTextView(text: "hello world")
        textView.caretBlinkInterval = 0.8
        textView.selectedRange = NSRange(location: 2, length: 0)

        let animation = try XCTUnwrap(blinkAnimation(in: textView))
        XCTAssertEqual(animation.duration, 1.6, accuracy: 0.001)
        XCTAssertEqual(animation.repeatCount, .infinity)
    }

    func testBlinkIntervalIsClamped() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        textView.caretBlinkInterval = 0.001
        XCTAssertEqual(textView.caretBlinkInterval, 0.1, accuracy: 0.0001)
        textView.caretBlinkInterval = 99
        XCTAssertEqual(textView.caretBlinkInterval, 2, accuracy: 0.0001)
    }

    func testDefaultIntervalIsHalfASecond() {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        XCTAssertEqual(textView.caretBlinkInterval, 0.5, accuracy: 0.0001)
        XCTAssertTrue(textView.caretBlinkingEnabled)
    }

    func testBlinkingOffLeavesNoAnimation() {
        let textView = makeFocusedTextView(text: "hello world")
        textView.caretBlinkingEnabled = false
        textView.selectedRange = NSRange(location: 3, length: 0)

        XCTAssertNil(blinkAnimation(in: textView))
        XCTAssertNotNil(visibleCaret(in: textView), "the caret is still shown, just solid")

        textView.caretBlinkingEnabled = true
        XCTAssertNotNil(blinkAnimation(in: textView))
    }

    func testMovingTheCaretRestartsTheBlink() throws {
        let textView = makeFocusedTextView(text: "hello world")
        textView.selectedRange = NSRange(location: 1, length: 0)
        let first = try XCTUnwrap(blinkAnimation(in: textView)).beginTime

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        textView.selectedRange = NSRange(location: 4, length: 0)

        let second = try XCTUnwrap(blinkAnimation(in: textView)).beginTime
        XCTAssertGreaterThan(second, first, "a caret move must show the caret solid again")
    }

    func testTypingRestartsTheBlink() throws {
        let textView = makeFocusedTextView(text: "hello")
        textView.selectedRange = NSRange(location: 5, length: 0)
        let first = try XCTUnwrap(blinkAnimation(in: textView)).beginTime

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        textView.insertText("!")

        let second = try XCTUnwrap(blinkAnimation(in: textView)).beginTime
        XCTAssertGreaterThan(second, first)
    }

    func testRelayoutWithoutAMoveKeepsTheBlinkPhase() throws {
        let textView = makeFocusedTextView(text: "hello world")
        textView.selectedRange = NSRange(location: 2, length: 0)
        let first = try XCTUnwrap(blinkAnimation(in: textView)).beginTime

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        textView.setNeedsLayout()
        textView.layoutIfNeeded()

        XCTAssertEqual(try XCTUnwrap(blinkAnimation(in: textView)).beginTime, first, accuracy: 0.0001)
    }

    func testSmoothBlinkFadesAndHardBlinkSwitches() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion turns smooth blinking off")
        let textView = makeFocusedTextView(text: "hello world")
        textView.smoothCaretBlinking = true
        textView.selectedRange = NSRange(location: 2, length: 0)
        XCTAssertEqual(try XCTUnwrap(blinkAnimation(in: textView)).calculationMode, .linear)

        textView.smoothCaretBlinking = false
        XCTAssertEqual(try XCTUnwrap(blinkAnimation(in: textView)).calculationMode, .discrete)
    }

    func testSmoothMovementAddsAGlideToTheNewPosition() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion turns the glide off")
        let textView = makeFocusedTextView(text: "hello world")
        textView.smoothCaretMovement = true
        textView.selectedRange = NSRange(location: 0, length: 0)
        let caret = try XCTUnwrap(visibleCaret(in: textView))
        let before = caret.frame.origin

        textView.selectedRange = NSRange(location: 6, length: 0)

        XCTAssertGreaterThan(caret.frame.origin.x, before.x, "the model frame is already at the destination")
        let glide = try XCTUnwrap(caret.layer?.animation(forKey: CaretAnimation.moveKey) as? CABasicAnimation)
        XCTAssertEqual(glide.keyPath, "position")
        XCTAssertTrue(glide.isAdditive)
        XCTAssertEqual(glide.duration, CaretAnimation.moveDuration, accuracy: 0.0001)
    }

    func testNoGlideWhenSmoothMovementIsOff() throws {
        let textView = makeFocusedTextView(text: "hello world")
        textView.selectedRange = NSRange(location: 0, length: 0)
        let caret = try XCTUnwrap(visibleCaret(in: textView))

        textView.selectedRange = NSRange(location: 6, length: 0)

        XCTAssertNil(caret.layer?.animation(forKey: CaretAnimation.moveKey))
    }

    func testScrollingDoesNotGlideTheCaret() throws {
        let lines = (0..<200).map { "line \($0)" }.joined(separator: "\n")
        let textView = makeFocusedTextView(text: lines)
        textView.smoothCaretMovement = true
        textView.selectedRange = NSRange(location: 0, length: 0)
        let caret = try XCTUnwrap(visibleCaret(in: textView))
        caret.layer?.removeAnimation(forKey: CaretAnimation.moveKey)

        textView.contentOffset = CGPoint(x: 0, y: 200)
        textView.layoutIfNeeded()

        XCTAssertNil(caret.layer?.animation(forKey: CaretAnimation.moveKey))
    }

    // MARK: - Helpers

    private func blinkAnimation(in textView: TextView) -> CAKeyframeAnimation? {
        visibleCaret(in: textView)?.layer?.animation(forKey: CaretAnimation.blinkKey) as? CAKeyframeAnimation
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
