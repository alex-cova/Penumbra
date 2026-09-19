import CoreGraphics
@testable import Penumbra
import XCTest

/// `ScrollerGeometry` is the whole scroll transform for an overlay scroller, as a pure value type.
/// These assert the guarantees the design rests on — the knob never leaves the track and is flush
/// at both ends of the scroll range — plus that the click/drag inverses round-trip and stay clamped,
/// across short, exactly-fitting, and very large documents and under a negative minimum offset.
final class ScrollerGeometryTests: XCTestCase {
    private func geometry(
        contentOffset: CGFloat,
        scrollRange: CGFloat = 1_500,
        trackLength: CGFloat = 500,
        viewportLength: CGFloat = 500,
        minimumContentOffset: CGFloat = 0,
        minKnobLength: CGFloat = 24
    ) -> ScrollerGeometry {
        ScrollerGeometry(
            trackLength: trackLength,
            viewportLength: viewportLength,
            contentOffset: contentOffset,
            minimumContentOffset: minimumContentOffset,
            maximumContentOffset: minimumContentOffset + scrollRange,
            minKnobLength: minKnobLength
        )
    }

    // MARK: - Scrollability

    func testDocumentThatFitsIsNotScrollable() {
        XCTAssertFalse(geometry(contentOffset: 0, scrollRange: 0).isScrollable)
    }

    func testSubPointRangeIsNotScrollable() {
        XCTAssertFalse(geometry(contentOffset: 0, scrollRange: 0.3).isScrollable)
    }

    func testOverflowingDocumentIsScrollable() {
        XCTAssertTrue(geometry(contentOffset: 0).isScrollable)
    }

    func testZeroTrackOrViewportIsNotScrollable() {
        XCTAssertFalse(geometry(contentOffset: 0, trackLength: 0).isScrollable)
        XCTAssertFalse(geometry(contentOffset: 0, viewportLength: 0).isScrollable)
    }

    // MARK: - Knob placement

    func testKnobIsFlushAtBothEndsOfTheRange() {
        let top = geometry(contentOffset: 0)
        XCTAssertEqual(top.knobOrigin, 0, accuracy: 0.001)

        let bottom = geometry(contentOffset: 1_500)
        XCTAssertEqual(bottom.knobOrigin + bottom.knobLength, 500, accuracy: 0.001)
    }

    func testKnobLengthMirrorsViewportShareOfContent() {
        // Viewport 500 of 2000 total scrollable extent → a quarter of the track.
        XCTAssertEqual(geometry(contentOffset: 0).knobLength, 125, accuracy: 0.001)
    }

    func testKnobNeverLeavesTheTrackForAnyOffset() {
        for offset in stride(from: CGFloat(-200), through: 2_000, by: 37) {
            let g = geometry(contentOffset: offset)
            XCTAssertGreaterThanOrEqual(g.knobOrigin, 0, "offset \(offset)")
            XCTAssertLessThanOrEqual(g.knobOrigin + g.knobLength, 500 + 0.001, "offset \(offset)")
        }
    }

    func testKnobRespectsMinimumLengthOnHugeDocuments() {
        let g = geometry(contentOffset: 0, scrollRange: 5_000_000)
        XCTAssertEqual(g.knobLength, 24, accuracy: 0.001)
        let atEnd = geometry(contentOffset: 5_000_000, scrollRange: 5_000_000)
        XCTAssertEqual(atEnd.knobOrigin + atEnd.knobLength, 500, accuracy: 0.001)
    }

    func testMinimumKnobLengthNeverExceedsATinyTrack() {
        let g = geometry(contentOffset: 0, trackLength: 10)
        XCTAssertLessThanOrEqual(g.knobLength, 10)
    }

    func testNegativeMinimumOffsetFromAContentInsetMapsToTheTop() {
        let top = geometry(contentOffset: -60, scrollRange: 1_500, minimumContentOffset: -60)
        XCTAssertEqual(top.progress, 0, accuracy: 0.001)
        XCTAssertEqual(top.knobOrigin, 0, accuracy: 0.001)
    }

    func testProgressIsClampedWhenOffsetOvershoots() {
        XCTAssertEqual(geometry(contentOffset: -300).progress, 0)
        XCTAssertEqual(geometry(contentOffset: 9_999).progress, 1)
    }

    // MARK: - Inverse mappings

    func testClickAtKnobCenterRoundTripsToTheSameOffset() {
        for offset in [CGFloat(0), 300, 750, 1_200, 1_500] {
            let g = geometry(contentOffset: offset)
            let center = g.knobOrigin + g.knobLength / 2
            XCTAssertEqual(g.contentOffset(forClickAt: center), offset, accuracy: 0.5, "offset \(offset)")
        }
    }

    func testClickAtTrackEndsClampsToTheScrollRange() {
        let g = geometry(contentOffset: 700)
        XCTAssertEqual(g.contentOffset(forClickAt: -50), 0, accuracy: 0.001)
        XCTAssertEqual(g.contentOffset(forClickAt: 9_999), 1_500, accuracy: 0.001)
    }

    func testDragByTheKnobsTravelScrollsTheWholeRange() {
        let g = geometry(contentOffset: 0)
        let travel = 500 - g.knobLength
        XCTAssertEqual(g.contentOffset(forDragDelta: travel, from: 0), 1_500, accuracy: 0.001)
    }

    func testDragIsClampedAtBothEnds() {
        let g = geometry(contentOffset: 700)
        XCTAssertEqual(g.contentOffset(forDragDelta: 9_999, from: 700), 1_500, accuracy: 0.001)
        XCTAssertEqual(g.contentOffset(forDragDelta: -9_999, from: 700), 0, accuracy: 0.001)
    }

    func testPagedClickMovesOneViewportTowardTheClick() {
        let g = geometry(contentOffset: 600)
        XCTAssertEqual(g.pagedContentOffset(forClickAt: 490), 1_100, accuracy: 0.001)
        XCTAssertEqual(g.pagedContentOffset(forClickAt: 0), 100, accuracy: 0.001)
    }

    func testPagedClickOnTheKnobLeavesTheOffsetAlone() {
        let g = geometry(contentOffset: 600)
        XCTAssertEqual(g.pagedContentOffset(forClickAt: g.knobOrigin + g.knobLength / 2), 600)
    }

    func testPagedClickIsClamped() {
        let g = geometry(contentOffset: 1_400)
        XCTAssertEqual(g.pagedContentOffset(forClickAt: 499), 1_500, accuracy: 0.001)
    }

    // MARK: - Degenerate inputs

    func testDegenerateGeometryIsSafe() {
        let g = geometry(contentOffset: 0, scrollRange: 0, trackLength: 0, viewportLength: 0)
        XCTAssertEqual(g.knobLength, 0)
        XCTAssertEqual(g.knobOrigin, 0)
        XCTAssertEqual(g.contentOffset(forClickAt: 10), 0)
        XCTAssertEqual(g.contentOffset(forDragDelta: 10, from: 0), 0)
    }
}
