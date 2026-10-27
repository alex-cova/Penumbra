import XCTest
@testable import Umbra

/// Headless tests for `GhosttyGridLayout` (plan Step 4): grid geometry the
/// renderer and the PTY size share.
final class GhosttyGridLayoutTests: XCTestCase {
    func testFittingUsesMinimumGrid() {
        let layout = GhosttyGridLayout.fitting(
            boundsSize: CGSize(width: 10, height: 10), cellWidth: 8, cellHeight: 16)
        XCTAssertEqual(layout.cols, 80)
        XCTAssertEqual(layout.rows, 24)
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
