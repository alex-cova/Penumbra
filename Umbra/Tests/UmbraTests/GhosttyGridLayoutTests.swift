import XCTest
@testable import Umbra

/// Headless tests for `GhosttyGridLayout` (plan Step 4): grid geometry the
/// renderer and the PTY size share.
final class GhosttyGridLayoutTests: XCTestCase {
    /// No 80×24 floor: the PTY is told this size, so a short bottom panel must get a short grid
    /// (a taller one put new output and psql's column headers below the visible rows).
    func testFittingUsesOnlyWhatFits() {
        let layout = GhosttyGridLayout.fitting(
            boundsSize: CGSize(width: 300, height: 190), cellWidth: 8, cellHeight: 16)
        XCTAssertEqual(layout.cols, 37)
        XCTAssertEqual(layout.rows, 11)
    }

    func testFittingNeverGoesBelowOneCell() {
        let layout = GhosttyGridLayout.fitting(
            boundsSize: CGSize(width: 0, height: 0), cellWidth: 8, cellHeight: 16)
        XCTAssertEqual(layout.cols, 1)
        XCTAssertEqual(layout.rows, 1)
    }

    func testCanFitNeedsOneWholeCell() {
        XCTAssertFalse(GhosttyGridLayout.canFit(boundsSize: .zero, cellWidth: 8, cellHeight: 16))
        XCTAssertFalse(GhosttyGridLayout.canFit(boundsSize: CGSize(width: 100, height: 15), cellWidth: 8, cellHeight: 16))
        XCTAssertTrue(GhosttyGridLayout.canFit(boundsSize: CGSize(width: 8, height: 16), cellWidth: 8, cellHeight: 16))
    }

    func testRectsForARangeOnOneRow() {
        let layout = GhosttyGridLayout(cellWidth: 8, cellHeight: 16, cols: 10, rows: 5)
        XCTAssertEqual(layout.rects(from: (2, 1), to: (4, 1)), [CGRect(x: 16, y: 16, width: 24, height: 16)])
    }

    func testRectsForARangeAcrossRowsClipToTheGrid() {
        let layout = GhosttyGridLayout(cellWidth: 8, cellHeight: 16, cols: 10, rows: 3)
        XCTAssertEqual(layout.rects(from: (8, 1), to: (500, 9)), [
            CGRect(x: 64, y: 16, width: 16, height: 16),
            CGRect(x: 0, y: 32, width: 80, height: 16),
        ])
        XCTAssertEqual(layout.rects(from: (3, 2), to: (1, 0)), [
            CGRect(x: 8, y: 0, width: 72, height: 16),
            CGRect(x: 0, y: 16, width: 80, height: 16),
            CGRect(x: 0, y: 32, width: 32, height: 16),
        ], "the ends may come in either order")
    }

    func testFittingDerivesGridFromBounds() {
        let layout = GhosttyGridLayout.fitting(
            boundsSize: CGSize(width: 800, height: 480), cellWidth: 8, cellHeight: 16)
        XCTAssertEqual(layout.cols, 100)
        XCTAssertEqual(layout.rows, 30)
    }

    func testFittingSurvivesZeroMetrics() {
        let layout = GhosttyGridLayout.fitting(
            boundsSize: CGSize(width: 800, height: 480), cellWidth: 0, cellHeight: 0)
        XCTAssertGreaterThanOrEqual(layout.cols, 1)
        XCTAssertGreaterThanOrEqual(layout.rows, 1)
    }

    func testCellAtClamps() {
        let layout = GhosttyGridLayout(cellWidth: 8, cellHeight: 16, cols: 100, rows: 30)
        XCTAssertEqual(layout.cellAt(point: CGPoint(x: 20, y: 40)).col, 2)
        XCTAssertEqual(layout.cellAt(point: CGPoint(x: 20, y: 40)).row, 2)
        let clamped = layout.cellAt(point: CGPoint(x: 100_000, y: -5))
        XCTAssertEqual(clamped.col, 99)
        XCTAssertEqual(clamped.row, 0)
    }

    func testRectForCells() {
        let layout = GhosttyGridLayout(cellWidth: 8, cellHeight: 16, cols: 100, rows: 30)
        let rect = layout.rectForCells(col: 2, row: 3, count: 4)
        XCTAssertEqual(rect, CGRect(x: 16, y: 48, width: 32, height: 16))
    }

    func testPixelCellSize() {
        let layout = GhosttyGridLayout(cellWidth: 8, cellHeight: 16, cols: 100, rows: 30)
        let px = layout.pixelCellSize(scale: 2)
        XCTAssertEqual(px.width, 16)
        XCTAssertEqual(px.height, 32)
    }
}
