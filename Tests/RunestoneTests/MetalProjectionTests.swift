import AppKit
import CoreText
import Metal
import XCTest
@testable import Runestone

final class MetalProjectionTests: XCTestCase {
    func testContentSpaceToNDCFlipsYAndIgnoresScale() {
        let canvas = CGRect(x: 0, y: 0, width: 800, height: 600)
        let top = MetalProjection.project(CGPoint(x: 400, y: 0), canvasFrame: canvas, scale: 1)
        let bottom = MetalProjection.project(CGPoint(x: 400, y: 600), canvasFrame: canvas, scale: 1)
        let left = MetalProjection.project(CGPoint(x: 0, y: 300), canvasFrame: canvas, scale: 1)
        let right = MetalProjection.project(CGPoint(x: 800, y: 300), canvasFrame: canvas, scale: 1)
        XCTAssertEqual(top.x, 0, accuracy: 0.0001)
        XCTAssertEqual(top.y, 1, accuracy: 0.0001)
        XCTAssertEqual(bottom.y, -1, accuracy: 0.0001)
        XCTAssertEqual(left.x, -1, accuracy: 0.0001)
        XCTAssertEqual(right.x, 1, accuracy: 0.0001)

        let point = CGPoint(x: 200, y: 150)
        let ndc1 = MetalProjection.project(point, canvasFrame: canvas, scale: 1)
        let ndc2 = MetalProjection.project(point, canvasFrame: canvas, scale: 2)
        XCTAssertEqual(ndc1.x, ndc2.x, accuracy: 0.0001)
        XCTAssertEqual(ndc1.y, ndc2.y, accuracy: 0.0001)
        XCTAssertEqual(ndc1.x, 200 / 800 * 2 - 1, accuracy: 0.0001)
        XCTAssertEqual(ndc1.y, 1 - 150 / 600 * 2, accuracy: 0.0001)
    }

    func testNonZeroGutterVerticalAndHorizontalPanAt1xAnd2x() {
        let gutter: CGFloat = 48
        let canvasSize = CGSize(width: 640, height: 360)
        let glyph = CGPoint(x: gutter + 10, y: 80)
        for scale in [CGFloat(1), CGFloat(2)] {
            let origin = MetalProjection.project(
                glyph,
                canvasFrame: CGRect(origin: .zero, size: canvasSize),
                scale: scale
            )
            XCTAssertEqual(origin.x, Float((gutter + 10) / canvasSize.width * 2 - 1), accuracy: 0.0001)

            let vertical = CGRect(x: 0, y: 40, width: canvasSize.width, height: canvasSize.height)
            let afterVertical = MetalProjection.project(glyph, canvasFrame: vertical, scale: scale)
            XCTAssertEqual(afterVertical.x, origin.x, accuracy: 0.0001)
            XCTAssertEqual(afterVertical.y, Float(1 - (80 - 40) / canvasSize.height * 2), accuracy: 0.0001)

            let horizontal = CGRect(x: 30, y: 0, width: canvasSize.width, height: canvasSize.height)
            let afterHorizontal = MetalProjection.project(glyph, canvasFrame: horizontal, scale: scale)
            XCTAssertEqual(afterHorizontal.y, origin.y, accuracy: 0.0001)
            XCTAssertEqual(afterHorizontal.x, Float((gutter + 10 - 30) / canvasSize.width * 2 - 1), accuracy: 0.0001)

            let both = CGRect(x: 30, y: 40, width: canvasSize.width, height: canvasSize.height)
            let afterBoth = MetalProjection.project(glyph, canvasFrame: both, scale: scale)
            XCTAssertEqual(afterBoth.x, afterHorizontal.x, accuracy: 0.0001)
            XCTAssertEqual(afterBoth.y, afterVertical.y, accuracy: 0.0001)
        }
    }

    func testEmitRectIsCanvasFrameInsetByNegativeTwo() {
        let canvas = CGRect(x: 10, y: 20, width: 100, height: 50)
        let emit = MetalProjection.emitRect(canvasFrame: canvas)
        XCTAssertEqual(emit, canvas.insetBy(dx: -2, dy: -2))
        let warm = MetalProjection.atlasWarmRect(canvasFrame: canvas)
        XCTAssertEqual(warm.minX, canvas.minX)
        XCTAssertEqual(warm.width, canvas.width)
        XCTAssertEqual(warm.minY, canvas.minY - 350)
        XCTAssertEqual(warm.height, canvas.height + 700)
    }

    func testGlyphOriginAlignsToCanvasDevicePixelGrid() {
        let canvas = CGRect(x: 10.25, y: 20.25, width: 100, height: 50)
        let aligned = MetalProjection.pixelAligned(
            SIMD2<Float>(11.13, 21.62),
            canvasFrame: canvas,
            scale: 2
        )

        XCTAssertEqual(aligned.x, 11.25, accuracy: 0.0001)
        XCTAssertEqual(aligned.y, 21.75, accuracy: 0.0001)
        XCTAssertEqual((aligned.x - Float(canvas.minX)) * 2, 2, accuracy: 0.0001)
        XCTAssertEqual((aligned.y - Float(canvas.minY)) * 2, 3, accuracy: 0.0001)
    }

    func testWrappingOffLongLinePanChangesNDCWithoutSubtractingViewportTwice() {
        let gutter: CGFloat = 36
        let glyph = CGPoint(x: gutter + 10, y: 18)
        let canvas = CGRect(x: 120, y: 0, width: 400, height: 200)
        let ndc = MetalProjection.project(glyph, canvasFrame: canvas, scale: 2)
        let expectedX = (gutter + 10 - canvas.minX) / canvas.width * 2 - 1
        XCTAssertEqual(ndc.x, Float(expectedX), accuracy: 0.0001)
        XCTAssertNotEqual(ndc.x, Float((gutter + 10) / canvas.width * 2 - 1), accuracy: 0.0001)
    }

    @MainActor
    func testWrappingOffLongLineRebuildsInstancesWhenCanvasFrameMoves() throws {
        guard MetalContext.isAvailable else {
            throw XCTSkip("Metal is not available")
        }
        guard let device = MetalContext.shared.device, let queue = MetalContext.shared.commandQueue else {
            XCTFail("MetalContext.isAvailable is true but device or command queue is nil")
            throw XCTSkip("Metal is not available")
        }
        let atlas = GlyphAtlas(device: device, commandQueue: queue, hasUnifiedMemory: device.hasUnifiedMemory)
        let font = CTFontCreateWithName("Menlo" as CFString, 16, nil)
        let string = String(repeating: "MMMM", count: 80)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: [.font: font])
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ascent + descent + leading
        let base = CGSize(width: width, height: height)
        let frame = CGRect(x: 48, y: 0, width: width, height: height)
        let canvasA = CGRect(x: 0, y: 0, width: 200, height: 40)
        let canvasB = CGRect(x: 360, y: 0, width: 200, height: 40)
        func extract(canvas: CGRect) -> GlyphExtractResult {
            let request = GlyphExtractRequest(
                line: line,
                fragmentFrame: frame,
                descent: descent,
                baseSize: base,
                scaledSize: base,
                unfocusedAlpha: 1,
                focusedRanges: [],
                scale: 2,
                emitRect: MetalProjection.emitRect(canvasFrame: canvas),
                atlasWarmRect: .null,
                fallbackFont: font,
                fallbackColor: .white,
                appearance: nil
            )
            return GlyphRunExtractor.extract(request, atlas: atlas)
        }
        let first = extract(canvas: canvasA)
        let second = extract(canvas: canvasB)
        XCTAssertFalse(first.instances.isEmpty)
        XCTAssertFalse(second.instances.isEmpty)
        XCTAssertNotEqual(first.instances.map(\.origin.x), second.instances.map(\.origin.x))
        let previous = GlyphExtractCacheKey(revision: 1, emitRect: MetalProjection.emitRect(canvasFrame: canvasA))
        XCTAssertTrue(
            GlyphExtractCacheKey.shouldRebuild(
                previous: previous,
                revision: 1,
                emitRect: MetalProjection.emitRect(canvasFrame: canvasB)
            )
        )
    }
}
