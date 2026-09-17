import XCTest
@testable import Penumbra

final class TypewriterScrollingPolicyTests: XCTestCase {
    func testShouldAnchorRequiresBothFlagsZeroLengthRangeAndNoUserSuspension() {
        XCTAssertTrue(TypewriterScrollingPolicy.shouldAnchor(
            isTypewriterScrollingEnabled: true,
            isAutomaticScrollEnabled: true,
            isSuspendedByUser: false,
            rangeLength: 0
        ))
        XCTAssertFalse(TypewriterScrollingPolicy.shouldAnchor(
            isTypewriterScrollingEnabled: false,
            isAutomaticScrollEnabled: true,
            isSuspendedByUser: false,
            rangeLength: 0
        ))
        XCTAssertFalse(TypewriterScrollingPolicy.shouldAnchor(
            isTypewriterScrollingEnabled: true,
            isAutomaticScrollEnabled: false,
            isSuspendedByUser: false,
            rangeLength: 0
        ))
        XCTAssertFalse(TypewriterScrollingPolicy.shouldAnchor(
            isTypewriterScrollingEnabled: true,
            isAutomaticScrollEnabled: true,
            isSuspendedByUser: true,
            rangeLength: 0
        ))
        XCTAssertFalse(TypewriterScrollingPolicy.shouldAnchor(
            isTypewriterScrollingEnabled: true,
            isAutomaticScrollEnabled: true,
            isSuspendedByUser: false,
            rangeLength: 3
        ))
    }

    func testAnchorYUsesLineCenter() {
        XCTAssertEqual(TypewriterScrollingPolicy.anchorY(lineYPosition: 100, lineHeight: 20), 110)
    }

    func testContentOffsetYPlacesAnchorAtFraction() {
        // 300pt viewport, anchor at 50% → offset 110 - 150 = -40
        XCTAssertEqual(
            TypewriterScrollingPolicy.contentOffsetY(anchorY: 110, viewportHeight: 300, anchorFraction: 0.5),
            -40
        )
        // anchor at 25% → offset 110 - 75 = 35
        XCTAssertEqual(
            TypewriterScrollingPolicy.contentOffsetY(anchorY: 110, viewportHeight: 300, anchorFraction: 0.25),
            35
        )
    }

    func testRequiredOverscrollKeepsAtLeastHalfViewportOnBothEdges() {
        XCTAssertEqual(
            TypewriterScrollingPolicy.requiredTopOverscroll(viewportHeight: 400, anchorFraction: 0.5),
            200
        )
        XCTAssertEqual(
            TypewriterScrollingPolicy.requiredTopOverscroll(viewportHeight: 400, anchorFraction: 0.75),
            300
        )
        XCTAssertEqual(
            TypewriterScrollingPolicy.requiredBottomOverscroll(viewportHeight: 400, anchorFraction: 0.5),
            200
        )
        XCTAssertEqual(
            TypewriterScrollingPolicy.requiredBottomOverscroll(viewportHeight: 400, anchorFraction: 0.75),
            200
        )
    }
}
