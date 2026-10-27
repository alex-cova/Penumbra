import CoreGraphics
import Foundation

/// Pure grid geometry for `GhosttyTerminalView`: cell metrics from the font,
/// grid dimensions from the view bounds, and point/cell mapping.
///
/// Headless-testable: the view feeds real font metrics in, and pure numbers
/// come out. No AppKit, no CoreText here.
struct GhosttyGridLayout: Equatable, Sendable {
    /// Advance width of one cell in points.
    var cellWidth: CGFloat
    /// Line height of one row in points.
    var cellHeight: CGFloat
    /// Grid size in cells.
    var cols: Int
    var rows: Int

    /// Derives the grid that fits `boundsSize`, enforcing the minimum
    /// 80×24 and at least 1×1 (the C terminal requires nonzero dimensions).
    static func fitting(
        boundsSize: CGSize,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        minimumCols: Int = 80,
        minimumRows: Int = 24
    ) -> GhosttyGridLayout {
        let safeCellWidth = max(cellWidth, 1)
        let safeCellHeight = max(cellHeight, 1)
        let cols = max(Int(boundsSize.width / safeCellWidth), 1)
        let rows = max(Int(boundsSize.height / safeCellHeight), 1)
        return GhosttyGridLayout(
            cellWidth: safeCellWidth,
            cellHeight: safeCellHeight,
            cols: max(cols, minimumCols),
            rows: max(rows, minimumRows))
    }

    /// Cell size in pixels for `ghostty_terminal_resize`.
    func pixelCellSize(scale: CGFloat) -> (width: UInt32, height: UInt32) {
        (
            width: UInt32(clamping: Int((cellWidth * scale).rounded(.down))),
            height: UInt32(clamping: Int((cellHeight * scale).rounded(.down))))
    }

    /// Which cell contains `point` (view coordinates, origin bottom-left),
    /// clamped into the grid.
    func cellAt(point: CGPoint) -> (col: Int, row: Int) {
        (
            col: min(max(Int(point.x / cellWidth), 0), cols - 1),
            row: min(max(Int(point.y / cellHeight), 0), rows - 1))
    }

    /// View rect of a cell range on one row (origin bottom-left).
    func rectForCells(col: Int, row: Int, count: Int) -> CGRect {
        CGRect(
            x: CGFloat(col) * cellWidth,
            y: CGFloat(row) * cellHeight,
            width: CGFloat(count) * cellWidth,
            height: cellHeight)
    }
}
