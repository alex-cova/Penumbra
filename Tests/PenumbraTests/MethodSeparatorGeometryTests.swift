import CoreGraphics
import XCTest
@testable import Penumbra

final class MethodSeparatorGeometryTests: XCTestCase {
    func testHairlineUsesPageGuideThicknessCenteredOnTheLineTop() {
        let thickness: CGFloat = 1
        let frames = MethodSeparatorGeometry.frames(
            lineYPositions: [40],
            insetTop: 8,
            width: 240,
            thickness: thickness,
            clip: CGRect(x: 0, y: 0, width: 240, height: 400)
        )
        let expectedY = (8 + 40 - thickness / 2).rounded()
        XCTAssertEqual(frames, [CGRect(x: 0, y: expectedY, width: 240, height: thickness)])
    }

    func testClipKeepsOnlyLinesInsideTheViewport() {
        let frames = MethodSeparatorGeometry.frames(
            lineYPositions: [0, 500],
            insetTop: 0,
            width: 100,
            thickness: 1,
            clip: CGRect(x: 0, y: 0, width: 100, height: 80)
        )
        XCTAssertEqual(frames.count, 1)
        XCTAssertLessThan(frames[0].minY, 80)
    }

    func testWidthCapsAtRightMargin() {
        let frames = MethodSeparatorGeometry.frames(
            lineYPositions: [40],
            insetTop: 0,
            width: 80,
            thickness: 1,
            clip: CGRect(x: 0, y: 0, width: 240, height: 400)
        )
        XCTAssertEqual(frames, [CGRect(x: 0, y: 40, width: 80, height: 1)])
    }

    func testZeroWidthOrThicknessProducesNoLines() {
        let clip = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(
            MethodSeparatorGeometry.frames(
                lineYPositions: [10], insetTop: 0, width: 0, thickness: 1, clip: clip
            ).isEmpty
        )
        XCTAssertTrue(
            MethodSeparatorGeometry.frames(
                lineYPositions: [10], insetTop: 0, width: 100, thickness: 0, clip: clip
            ).isEmpty
        )
    }
}
