import XCTest
import AppKit
@testable import Penumbra

@MainActor
final class TextViewScrollToCenterTests: XCTestCase {
    private func makeTextView(lines: Int, height: CGFloat = 300) -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: height))
        textView.theme = DefaultTheme()
        textView.text = (1...lines).map { "line \($0)" }.joined(separator: "\n")
        textView.layoutIfNeeded()
        return textView
    }

    private func location(ofLine line: Int, in textView: TextView) -> Int {
        (textView.text as NSString).range(of: "line \(line)\n").location
    }

    /// The caret's vertical center, measured from the top of the visible area.
    private func caretOffsetInViewport(_ location: Int, _ textView: TextView) -> CGFloat {
        textView.caretRectInViewport(at: location).midY
    }

    func testTargetLineEndsUpInTheMiddleOfTheViewport() {
        let textView = makeTextView(lines: 500)
        let target = location(ofLine: 250, in: textView)
        textView.scrollRangeToCenter(NSRange(location: target, length: 4))
        textView.layoutIfNeeded()
        let lineHeight = textView.caretRectInViewport(at: target).height
        XCTAssertEqual(caretOffsetInViewport(target, textView), textView.frame.height / 2, accuracy: lineHeight)
    }

    func testLineNearTheStartIsNotScrolledPastTheTop() {
        let textView = makeTextView(lines: 500)
        textView.contentOffset = CGPoint(x: 0, y: 2000)
        textView.scrollRangeToCenter(NSRange(location: location(ofLine: 2, in: textView), length: 0))
        XCTAssertLessThanOrEqual(textView.contentOffset.y, 0.5)
    }

    func testRequestBeforeTheViewHasAHeightIsAppliedAtLayout() {
        let textView = makeTextView(lines: 500, height: 0)
        let target = location(ofLine: 300, in: textView)
        textView.scrollRangeToCenter(NSRange(location: target, length: 0))
        XCTAssertEqual(textView.contentOffset.y, 0, accuracy: 0.5)
        textView.frame.size.height = 300
        textView.layoutSubtreeIfNeeded()
        let lineHeight = textView.caretRectInViewport(at: target).height
        XCTAssertEqual(caretOffsetInViewport(target, textView), 150, accuracy: lineHeight)
    }
}
