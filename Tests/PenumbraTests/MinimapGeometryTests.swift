import CoreGraphics
@testable import Penumbra
import XCTest

/// `MinimapGeometry` is the whole scroll transform, as a pure value type. These assert the two
/// guarantees the design rests on — the indicator never leaves the minimap's bounds, and it is
/// flush at both ends of the scroll range — plus that the click/drag inverses round-trip, across
/// short, exactly-fitting, and very large documents and under a large `textContainerInset`.
final class MinimapGeometryTests: XCTestCase {
    private let estimatedLineHeight: CGFloat = 20
    private let minimapRowHeight: CGFloat = 3
    private var scale: CGFloat { minimapRowHeight / estimatedLineHeight }

    private func geometry(
        contentOffsetY: CGFloat,
        documentHeight: CGFloat,
        boundsHeight: CGFloat = 500,
        viewportHeight: CGFloat = 500,
        insetTop: CGFloat = 0,
        minContentOffsetY: CGFloat = 0
    ) -> MinimapGeometry {
        MinimapGeometry(
            boundsHeight: boundsHeight,
            viewportHeight: viewportHeight,
            contentOffsetY: contentOffsetY,
            minimumContentOffsetY: minContentOffsetY,
            maximumContentOffsetY: max(documentHeight - viewportHeight, minContentOffsetY),
            documentHeight: documentHeight,
            textContainerInsetTop: insetTop,
            scale: scale,
            minIndicatorHeight: 6
        )
    }

    private func sweep(_ body: (CGFloat) -> Void, min: CGFloat, max: CGFloat, steps: Int = 40) {
        guard steps > 0 else { return }
        for i in 0 ... steps {
            body(min + (max - min) * CGFloat(i) / CGFloat(steps))
        }
    }

    func testIndicatorStaysInsideBoundsAcrossFullScrollRange() {
        for documentHeight: CGFloat in [120, 500, 700, 1_000, 2_000, 4_000, 200_000] {
            let maxOffset = Swift.max(documentHeight - 500, 0)
            sweep({ offset in
                let g = geometry(contentOffsetY: offset, documentHeight: documentHeight)
                let rect = g.indicatorRect(width: 100)
                XCTAssertGreaterThanOrEqual(rect.minY, -0.001, "doc \(documentHeight) offset \(offset)")
                XCTAssertLessThanOrEqual(rect.maxY, 500 + 0.001, "doc \(documentHeight) offset \(offset)")
            }, min: -60, max: maxOffset + 60)
        }
    }

    func testIndicatorFlushAtBothEndsForLargeDocument() {
        let documentHeight: CGFloat = 200_000
        let maxOffset = documentHeight - 500

        let top = geometry(contentOffsetY: 0, documentHeight: documentHeight)
        XCTAssertEqual(top.indicatorRect(width: 100).minY, 0, accuracy: 0.001)

        let bottom = geometry(contentOffsetY: maxOffset, documentHeight: documentHeight)
        XCTAssertEqual(bottom.indicatorRect(width: 100).maxY, 500, accuracy: 0.001)
    }

    /// The regression the earlier row-index geometry failed: a large `textContainerInset.top`
    /// (typewriter scrolling) plus bottom overscroll must not push the indicator off either end.
    func testIndicatorFlushWithLargeTextContainerInset() {
        let lineManagerHeight: CGFloat = 200_000
        let insetTop: CGFloat = 250
        let insetBottom: CGFloat = 250
        let bottomOverscroll: CGFloat = 250
        let contentSizeHeight = lineManagerHeight + insetTop + insetBottom + bottomOverscroll
        let documentHeight = Swift.max(contentSizeHeight, insetTop + lineManagerHeight + insetBottom)
        let maxOffset = documentHeight - 500

        let top = geometry(contentOffsetY: 0, documentHeight: documentHeight, insetTop: insetTop)
        XCTAssertEqual(top.indicatorRect(width: 100).minY, 0, accuracy: 0.001)

        let bottom = geometry(contentOffsetY: maxOffset, documentHeight: documentHeight, insetTop: insetTop)
        XCTAssertEqual(bottom.indicatorRect(width: 100).maxY, 500, accuracy: 0.001)
    }

    func testClickRoundTripsToTheSameContentOffset() {
        for documentHeight: CGFloat in [700, 1_000, 2_000, 60_000] {
            let maxOffset = documentHeight - 500
            sweep({ offset in
                let g = geometry(contentOffsetY: offset, documentHeight: documentHeight)
                let midY = g.indicatorRect(width: 100).midY
                XCTAssertEqual(g.contentOffsetY(forClickAtLocalY: midY), offset, accuracy: 0.01,
                               "doc \(documentHeight) offset \(offset)")
            }, min: 0, max: maxOffset)
        }
    }

    func testDragIsMonotonicAndFullTravelCoversEntireScrollRange() {
        let documentHeight: CGFloat = 60_000
        let maxOffset = documentHeight - 500
        let g = geometry(contentOffsetY: 0, documentHeight: documentHeight)
        let travel = 500 - g.indicatorRect(width: 100).height

        var previous = -CGFloat.greatestFiniteMagnitude
        sweep({ delta in
            let value = g.contentOffsetY(forDragDelta: delta, from: 0)
            XCTAssertGreaterThanOrEqual(value, previous - 0.001)
            previous = value
        }, min: 0, max: travel)

        XCTAssertEqual(g.contentOffsetY(forDragDelta: travel, from: 0), maxOffset, accuracy: 0.5)
        XCTAssertEqual(g.contentOffsetY(forDragDelta: 0, from: 0), 0, accuracy: 0.001)
    }

    func testShortDocumentPinsIndicatorToTopWithNoContentOffset() {
        let g = geometry(contentOffsetY: 0, documentHeight: 120)
        XCTAssertEqual(g.progress, 0)
        XCTAssertEqual(g.contentOffset, 0, accuracy: 0.001)
        XCTAssertEqual(g.indicatorRect(width: 100).minY, 0, accuracy: 0.001)
    }

    func testDegenerateInputsDoNotProduceNaNOrCrash() {
        let cases: [MinimapGeometry] = [
            MinimapGeometry(boundsHeight: 0, viewportHeight: 500, contentOffsetY: 10, minimumContentOffsetY: 0,
                            maximumContentOffsetY: 100, documentHeight: 1000, textContainerInsetTop: 0,
                            scale: scale, minIndicatorHeight: 6),
            MinimapGeometry(boundsHeight: 500, viewportHeight: 0, contentOffsetY: 10, minimumContentOffsetY: 0,
                            maximumContentOffsetY: 100, documentHeight: 1000, textContainerInsetTop: 0,
                            scale: scale, minIndicatorHeight: 6),
            MinimapGeometry(boundsHeight: 500, viewportHeight: 500, contentOffsetY: 10, minimumContentOffsetY: 0,
                            maximumContentOffsetY: 0, documentHeight: 0, textContainerInsetTop: 0,
                            scale: 0, minIndicatorHeight: 6),
        ]
        for g in cases {
            XCTAssertFalse(g.isValid)
            let rect = g.indicatorRect(width: 100)
            XCTAssertFalse(rect.minY.isNaN)
            XCTAssertFalse(rect.height.isNaN)
            XCTAssertFalse(g.contentOffset.isNaN)
            XCTAssertFalse(g.contentOffsetY(forClickAtLocalY: 42).isNaN)
            XCTAssertFalse(g.contentOffsetY(forDragDelta: 42, from: 0).isNaN)
        }
    }

    /// The reported bug: a short file that is nonetheless scrollable (short editor pane, a
    /// split, or typewriter overscroll) made the whole block of bars slide down the minimap
    /// as you scrolled, because `indicatorTravel` used the full minimap height even though
    /// the scaled document only filled part of it. When the scaled document fits inside the
    /// minimap nothing needs to scroll, so `contentOffset` must stay pinned at `0`.
    func testShortScrollableDocumentDoesNotSlideItsContent() {
        for documentHeight: CGFloat in [700, 1_000, 2_000] {
            let maxOffset = documentHeight - 500
            XCTAssertGreaterThan(maxOffset, 0, "doc \(documentHeight) must be scrollable for this test")
            sweep({ offset in
                let g = geometry(contentOffsetY: offset, documentHeight: documentHeight)
                XCTAssertLessThan(g.scaledDocumentHeight, 500,
                                  "doc \(documentHeight) must be scaled-shorter than the minimap")
                XCTAssertEqual(g.contentOffset, 0, accuracy: 0.001, "doc \(documentHeight) offset \(offset)")
            }, min: 0, max: maxOffset)
        }
    }

    /// The drawn content may only ever be scrolled within the minimap's own overflow — never
    /// negative (bars pushed below their home) and never past the point where the last bar
    /// reaches the bottom edge.
    func testContentOffsetNeverExceedsScrollableMinimapRange() {
        for documentHeight: CGFloat in [120, 500, 700, 1_000, 2_000, 4_000, 60_000, 200_000] {
            let maxOffset = Swift.max(documentHeight - 500, 0)
            sweep({ offset in
                let g = geometry(contentOffsetY: offset, documentHeight: documentHeight)
                let upperBound = Swift.max(g.scaledDocumentHeight - 500, 0)
                XCTAssertGreaterThanOrEqual(g.contentOffset, -0.001, "doc \(documentHeight) offset \(offset)")
                XCTAssertLessThanOrEqual(g.contentOffset, upperBound + 0.001, "doc \(documentHeight) offset \(offset)")
            }, min: 0, max: maxOffset)
        }
    }

    /// When the document is shorter than the viewport it can't fill the indicator box, so the
    /// box is sized to the bars that exist rather than overhanging them.
    func testIndicatorNeverExtendsPastTheDrawnContent() {
        for documentHeight: CGFloat in [60, 120, 300, 480] {
            let g = geometry(contentOffsetY: 0, documentHeight: documentHeight)
            XCTAssertLessThanOrEqual(g.indicatorRect(width: 100).maxY, g.scaledDocumentHeight + 0.001,
                                     "doc \(documentHeight)")
        }
    }
}
