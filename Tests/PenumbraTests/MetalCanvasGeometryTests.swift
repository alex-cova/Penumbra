import CoreGraphics
import XCTest
@testable import Penumbra

final class MetalCanvasGeometryTests: XCTestCase {
    func testZeroGutterOverlayMatchesFullViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        let (viewFrame, canvasFrame) = MetalCanvasGeometry.frames(
            viewport: viewport,
            gutterWidth: 0,
            isScrollViewOverlay: true
        )
        XCTAssertEqual(viewFrame, CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(canvasFrame, viewport)
    }

    func testOverlayInsetsLeadingEdgeByGutterWidthOnScreenAndInContentSpace() {
        let viewport = CGRect(x: 120, y: 0, width: 800, height: 600)
        let (viewFrame, canvasFrame) = MetalCanvasGeometry.frames(
            viewport: viewport,
            gutterWidth: 48,
            isScrollViewOverlay: true
        )
        // On-screen frame starts right after the gutter column, in the scroll view's own bounds.
        XCTAssertEqual(viewFrame, CGRect(x: 48, y: 0, width: 752, height: 600))
        // Content-space frame skips the gutter's horizontally-scrolled position (`viewport.minX`)
        // plus the gutter's own width, so projection still lines up with where glyphs start.
        XCTAssertEqual(canvasFrame, CGRect(x: 168, y: 0, width: 752, height: 600))
    }

    func testGutterWidthNeverProducesNegativeSize() {
        let viewport = CGRect(x: 0, y: 0, width: 40, height: 600)
        let (viewFrame, canvasFrame) = MetalCanvasGeometry.frames(
            viewport: viewport,
            gutterWidth: 48,
            isScrollViewOverlay: true
        )
        XCTAssertEqual(viewFrame.width, 0)
        XCTAssertEqual(canvasFrame.width, 0)
    }

    func testNonOverlayCanvasUsesContentSpaceFrameForBothValues() {
        let viewport = CGRect(x: 30, y: 10, width: 400, height: 200)
        let (viewFrame, canvasFrame) = MetalCanvasGeometry.frames(
            viewport: viewport,
            gutterWidth: 20,
            isScrollViewOverlay: false
        )
        XCTAssertEqual(viewFrame, canvasFrame)
        XCTAssertEqual(canvasFrame, CGRect(x: 50, y: 10, width: 380, height: 200))
    }

    func testVerticalScrollLeavesGutterInsetUnaffected() {
        let scrolledViewport = CGRect(x: 0, y: 240, width: 800, height: 600)
        let (viewFrame, canvasFrame) = MetalCanvasGeometry.frames(
            viewport: scrolledViewport,
            gutterWidth: 48,
            isScrollViewOverlay: true
        )
        // The overlay's own on-screen frame never moves with vertical scroll — only its
        // content-space projection rect does.
        XCTAssertEqual(viewFrame.origin.y, 0)
        XCTAssertEqual(canvasFrame.origin.y, 240)
    }
}
