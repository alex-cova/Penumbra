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

    /// Derives the grid that fits `boundsSize`: whole cells only, at least 1×1 (the C terminal
    /// requires nonzero dimensions). No larger floor: the PTY is told this size, and a row or column
    /// the view cannot show is one where the shell's output, a prompt or a pager's first page
    /// (psql's column headers) lands out of sight.
    static func fitting(
        boundsSize: CGSize,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        minimumCols: Int = 1,
        minimumRows: Int = 1
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

    /// Whether `boundsSize` holds at least one whole cell. A view smaller than that (not laid out
    /// yet, or mid-animation) keeps its previous grid rather than reflowing the screen to one column.
    static func canFit(boundsSize: CGSize, cellWidth: CGFloat, cellHeight: CGFloat) -> Bool {
        boundsSize.width >= max(cellWidth, 1) && boundsSize.height >= max(cellHeight, 1)
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

    /// View rects of an inclusive cell range that may span rows (a selection or a search match),
    /// one per row, clipped to the grid. The ends may come in either order.
    func rects(from a: (col: Int, row: Int), to b: (col: Int, row: Int)) -> [CGRect] {
        let (start, end) = (a.row, a.col) <= (b.row, b.col) ? (a, b) : (b, a)
        guard cols > 0, rows > 0, start.row < rows, end.row >= 0 else { return [] }
        var result: [CGRect] = []
        for row in max(start.row, 0)...min(end.row, rows - 1) {
            let first = row == start.row ? max(start.col, 0) : 0
            let last = row == end.row ? min(end.col, cols - 1) : cols - 1
            guard first <= last, first < cols else { continue }
            result.append(rectForCells(col: first, row: row, count: last - first + 1))
        }
        return result
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
