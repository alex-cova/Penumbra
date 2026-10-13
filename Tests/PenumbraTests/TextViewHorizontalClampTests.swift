import AppKit
import XCTest
@testable import Penumbra

/// A caret revealed while the view is still narrow scrolls the text sideways; once the view is
/// wide enough for every line, the offset has to come back, or the start of each line stays
/// hidden under the gutter (and clicks there land on the gutter).
@MainActor
final class TextViewHorizontalClampTests: XCTestCase {
    private func drainMainQueue() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testGrowingTheViewBringsAHorizontalOffsetBackWhenEveryLineFits() async {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 24, height: 40))
        textView.theme = DefaultTheme()
        textView.showLineNumbers = true
        textView.isLineWrappingEnabled = false
        textView.text = "GET https://example.com/stock/v1/medications?sku=7501125103049\n\n###\n"
        textView.layoutIfNeeded()
        textView.selectedRange = NSRange(location: 3, length: 0)
        textView.scrollRangeToVisible(NSRange(location: 3, length: 0))
        textView.layoutIfNeeded()
        await drainMainQueue()
        XCTAssertGreaterThan(textView.contentOffset.x, textView.minimumContentOffset.x, "the narrow view should have scrolled sideways")

        textView.frame = CGRect(x: 0, y: 0, width: 900, height: 500)
        textView.layoutSubtreeIfNeeded()
        await drainMainQueue()
        textView.layoutSubtreeIfNeeded()

        XCTAssertEqual(textView.contentOffset.x, textView.minimumContentOffset.x, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(textView.caretRectInViewport(at: 0).minX, textView.gutterWidth, "the first character is under the gutter")
    }

    /// A line wider than the view still scrolls: growing the view only pulls the offset back as far
    /// as the content allows.
    func testAnOffsetThatTheContentStillAllowsIsKept() async {
        let long = String(repeating: "x", count: 400)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        textView.theme = DefaultTheme()
        textView.isLineWrappingEnabled = false
        textView.text = long + "\nshort\n"
        textView.layoutIfNeeded()
        await drainMainQueue()
        textView.contentOffset = CGPoint(x: 200, y: textView.contentOffset.y)
        textView.layoutIfNeeded()

        textView.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        textView.layoutSubtreeIfNeeded()
        await drainMainQueue()

        XCTAssertEqual(textView.contentOffset.x, 200, accuracy: 0.5)
    }
}
