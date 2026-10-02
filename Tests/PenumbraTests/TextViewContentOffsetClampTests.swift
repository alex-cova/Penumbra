import XCTest
import AppKit
@testable import Penumbra

/// A restored session hands the text view its selection before the window has its final height.
/// The caret reveal that follows must not leave the offset past the end once the view grows, or a
/// short file opens blank until the first scroll.
@MainActor
final class TextViewContentOffsetClampTests: XCTestCase {
    private func drainMainQueue() {
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func makeTextView(text: String, height: CGFloat) -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: height))
        textView.theme = DefaultTheme()
        textView.text = text
        textView.layoutSubtreeIfNeeded()
        drainMainQueue()
        return textView
    }

    private func grow(_ textView: TextView, toHeight height: CGFloat) {
        textView.frame.size.height = height
        textView.layoutSubtreeIfNeeded()
        drainMainQueue()
    }

    func testCaretRevealedWhileShortIsPulledBackOnceTheViewGrows() {
        let text = (1...26).map { "line \($0)" }.joined(separator: "\n") + "\n"
        for initialHeight: CGFloat in [0, 20] {
            let textView = makeTextView(text: text, height: initialHeight)
            textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            textView.setNeedsLayout()
            textView.layoutSubtreeIfNeeded()
            drainMainQueue()
            XCTAssertGreaterThan(textView.contentOffset.y, 400, "precondition: the reveal scrolled the last line to the top")
            grow(textView, toHeight: 600)
            XCTAssertLessThanOrEqual(textView.contentOffset.y, textView.maximumContentOffset.y + 0.5)
            XCTAssertEqual(textView.contentOffset.y, textView.minimumContentOffset.y, accuracy: 0.5)
        }
    }

    func testRestoredOffsetInsideALongDocumentSurvivesTheViewGrowing() {
        let text = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let textView = makeTextView(text: text, height: 0)
        textView.contentOffset = CGPoint(x: 0, y: 2000)
        grow(textView, toHeight: 300)
        XCTAssertEqual(textView.contentOffset.y, 2000, accuracy: 0.5)
    }
}
