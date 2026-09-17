import CoreGraphics
import XCTest
@testable import Penumbra

final class MarkdownPreviewTileGridTests: XCTestCase {
    func testTilePixelHeightClampsToMaxTilePixelHeight() {
        let grid = MarkdownPreviewTileGrid(
            contentSize: CGSize(width: 525, height: 20_000),
            scale: 2,
            maxTilePixelHeight: 4096
        )
        XCTAssertEqual(grid?.tilePixelHeight, 4096)
        XCTAssertEqual(grid?.pixelWidth, 1050)
    }

    func testTilePixelHeightClampsToMaxPixelCountForWideDocuments() {
        // pixelWidth = 4096 -> maxPixelCount / pixelWidth = 4096, so a 4096px-tall tile is
        // already at the max-pixel-count ceiling regardless of `maxTilePixelHeight`.
        let grid = MarkdownPreviewTileGrid(
            contentSize: CGSize(width: 2048, height: 1000),
            scale: 2,
            maxTilePixelHeight: 8192
        )
        XCTAssertEqual(grid?.pixelWidth, 4096)
        XCTAssertEqual(grid?.tilePixelHeight, MetalTextureUpload.maxPixelCount / 4096)
    }

    func testInitReturnsNilForDocumentTooWideToTile() {
        let grid = MarkdownPreviewTileGrid(
            contentSize: CGSize(width: CGFloat(MetalTextureUpload.maxTextureDimension) + 1, height: 1000),
            scale: 1
        )
        XCTAssertNil(grid)
    }

    func testInitReturnsNilForNonPositiveSize() {
        XCTAssertNil(MarkdownPreviewTileGrid(contentSize: .zero, scale: 2))
        XCTAssertNil(MarkdownPreviewTileGrid(contentSize: CGSize(width: 100, height: 0), scale: 2))
        XCTAssertNil(MarkdownPreviewTileGrid(contentSize: CGSize(width: 100, height: 100), scale: 0))
    }

    func testTileCountCoversFullDocumentHeight() {
        // 4096px tiles at scale 2 -> 2048pt per tile. A 5000pt document needs 3 tiles.
        let grid = MarkdownPreviewTileGrid(contentSize: CGSize(width: 500, height: 5000), scale: 2)
        XCTAssertEqual(grid?.tileCount, 3)
    }

    func testContentRectsAbutWithNoGapOrOverlap() throws {
        let grid = try XCTUnwrap(
            MarkdownPreviewTileGrid(contentSize: CGSize(width: 500, height: 5000), scale: 2)
        )
        var previousMaxY: CGFloat = 0
        for index in 0..<grid.tileCount {
            let rect = grid.contentRect(for: index)
            XCTAssertEqual(rect.minY, previousMaxY, accuracy: 0.001)
            previousMaxY = rect.maxY
        }
        XCTAssertEqual(previousMaxY, 5000, accuracy: 0.001)
    }

    func testLastTileIsShorterThanInteriorTiles() throws {
        let grid = try XCTUnwrap(
            MarkdownPreviewTileGrid(contentSize: CGSize(width: 500, height: 5000), scale: 2, maxTilePixelHeight: 4096)
        )
        let lastRect = grid.contentRect(for: grid.tileCount - 1)
        let interiorRect = grid.contentRect(for: 0)
        XCTAssertLessThan(lastRect.height, interiorRect.height)
        XCTAssertGreaterThan(lastRect.height, 0)
    }

    func testPixelSizeMatchesContentRectHeight() throws {
        let grid = try XCTUnwrap(
            MarkdownPreviewTileGrid(contentSize: CGSize(width: 500, height: 5000), scale: 2, maxTilePixelHeight: 4096)
        )
        for index in 0..<grid.tileCount {
            let rect = grid.contentRect(for: index)
            let pixelSize = grid.pixelSize(for: index)
            XCTAssertEqual(pixelSize.width, grid.pixelWidth)
            XCTAssertEqual(CGFloat(pixelSize.height), (rect.height * grid.scale).rounded(.up), accuracy: 1)
        }
    }

    func testIndicesIntersectingReturnsScrolledRangeWithMargin() throws {
        // 4 tiles of 2048pt each (4096px @ 2x) covering an 8000pt document.
        let grid = try XCTUnwrap(
            MarkdownPreviewTileGrid(contentSize: CGSize(width: 500, height: 8000), scale: 2, maxTilePixelHeight: 4096)
        )
        XCTAssertEqual(grid.tileCount, 4)

        // Viewport entirely inside tile 2 (global y in [4096, 6144)).
        let visible = CGRect(x: 0, y: 4200, width: 500, height: 300)
        XCTAssertEqual(grid.indices(intersecting: visible, margin: 1), [1, 2, 3])
    }

    func testIndicesIntersectingClampsMarginAtDocumentEdges() throws {
        let grid = try XCTUnwrap(
            MarkdownPreviewTileGrid(contentSize: CGSize(width: 500, height: 8000), scale: 2, maxTilePixelHeight: 4096)
        )
        let atTop = CGRect(x: 0, y: 0, width: 500, height: 100)
        XCTAssertEqual(grid.indices(intersecting: atTop, margin: 1), [0, 1])

        let atBottom = CGRect(x: 0, y: 7900, width: 500, height: 100)
        XCTAssertEqual(grid.indices(intersecting: atBottom, margin: 1), [2, 3])
    }

    func testIndicesIntersectingWithNoMarginReturnsExactTile() throws {
        let grid = try XCTUnwrap(
            MarkdownPreviewTileGrid(contentSize: CGSize(width: 500, height: 8000), scale: 2, maxTilePixelHeight: 4096)
        )
        let visible = CGRect(x: 0, y: 4200, width: 500, height: 300)
        XCTAssertEqual(grid.indices(intersecting: visible, margin: 0), [2])
    }
}
