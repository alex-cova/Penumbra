@preconcurrency import AppKit
@testable import Penumbra
import XCTest

/// Selection chrome is refreshed on every layout pass. It used to measure every selected range,
/// so Select All Occurrences on a large file made a line handle and laid out a line for each
/// match on every scroll frame (~1 s to select 38k matches, ~250 ms per scrolled page).
final class SelectionOverlayViewportTests: XCTestCase {
    @MainActor
    func testSelectAllOccurrencesOnlyMeasuresRangesNearTheViewport() throws {
        let lines = (0 ..< 5_000).map { "let word\($0) = word" }
        let (window, textView) = makeTextView(text: lines.joined(separator: "\n"))
        defer { window.orderOut(nil) }
        let textInputView = try XCTUnwrap(textView.minimapViewForTesting.lineDataSource)
        let lineManager = textInputView.lineManager

        textView.selectedRange = NSRange(location: 4, length: 4)
        lineManager.resetHandleCounters()
        textView.selectAllOccurrences()
        textView.layoutIfNeeded()
        XCTAssertEqual(textView.selectedRanges.count, 10_000)
        XCTAssertLessThan(lineManager.handlesCreated, 500, "no handle per selected range")
        let topRects = textView.selectionRectsForTesting
        XCTAssertFalse(topRects.isEmpty)
        XCTAssertLessThan(topRects.count, 500, "only ranges near the viewport get rects")

        // Scrolled into the middle, the ranges there get rects on the next layout pass.
        let offsetY = textView.contentSize.height / 2
        textView.contentOffset = CGPoint(x: 0, y: offsetY)
        textView.layoutIfNeeded()
        let visibleRect = CGRect(x: 0, y: offsetY, width: textView.bounds.width, height: textView.bounds.height)
        let middleRects = textView.selectionRectsForTesting
        XCTAssertLessThan(middleRects.count, 500)
        XCTAssertTrue(middleRects.contains { $0.rect.intersects(visibleRect) }, "selections in the viewport are drawn")
    }

    @MainActor
    func testRangeSpanningTheViewportIsStillDrawn() throws {
        let lines = (0 ..< 2_000).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        let (window, textView) = makeTextView(text: text)
        defer { window.orderOut(nil) }
        // A long selection that starts and ends far outside the viewport, plus a caret, so the
        // overlay takes the multi-range path.
        let length = (text as NSString).length
        textView.selectedRanges = [NSRange(location: 0, length: 0), NSRange(location: 3, length: length - 10)]
        let offsetY = textView.contentSize.height / 2
        textView.contentOffset = CGPoint(x: 0, y: offsetY)
        textView.layoutIfNeeded()
        let visibleRect = CGRect(x: 0, y: offsetY, width: textView.bounds.width, height: textView.bounds.height)
        XCTAssertTrue(textView.selectionRectsForTesting.contains { $0.rect.intersects(visibleRect) })
    }

    @MainActor
    private func makeTextView(text: String) -> (NSWindow, TextView) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.setState(TextViewState(text: text))
        window.makeFirstResponder(textView)
        textView.layoutIfNeeded()
        return (window, textView)
    }
}
