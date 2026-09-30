import AppKit
@testable import Penumbra
import XCTest

/// AppKit re-clamps the clip view when the document container shrinks. `contentOffset` must win
/// once the content has grown back, or the views in the container (the gutter) show from a
/// different offset than the Metal-drawn text.
@MainActor
final class EditorScrollViewTests: XCTestCase {
    func testClipViewReturnsToContentOffsetWhenContentGrowsBack() {
        let scrollView = EditorScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.contentSize = CGSize(width: 400, height: 5000)
        scrollView.contentOffset = CGPoint(x: 0, y: 1200)

        scrollView.contentSize = CGSize(width: 400, height: 500)
        scrollView.contentSize = CGSize(width: 400, height: 5000)

        XCTAssertEqual(scrollView.contentOffset.y, 1200)
        XCTAssertEqual(scrollView.visibleContentOffset.y, 1200)
    }

    func testLayoutKeepsClipViewAtContentOffset() {
        let scrollView = EditorScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.contentSize = CGSize(width: 400, height: 5000)
        scrollView.contentOffset = CGPoint(x: 0, y: 1200)

        scrollView.frame.size = CGSize(width: 400, height: 6000)
        scrollView.layout()
        scrollView.frame.size = CGSize(width: 400, height: 300)
        scrollView.layout()

        XCTAssertEqual(scrollView.visibleContentOffset.y, 1200)
    }
}
