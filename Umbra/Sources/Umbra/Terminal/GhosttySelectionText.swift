import Foundation

/// Builds the copied string for a viewport-cell selection: soft-wrapped lines
/// join without a newline, hard line ends keep it, trailing blank space is
/// trimmed per line.
enum GhosttySelectionText {
    static func text(
        in snapshot: GhosttyRenderSnapshot,
        from: (col: Int, row: Int),
        to: (col: Int, row: Int)
    ) -> String? {
        let (start, end) = (from.row, from.col) <= (to.row, to.col) ? (from, to) : (to, from)
        guard !snapshot.grid.isEmpty else { return nil }
        var lines: [String] = []
        var current = ""
        let lastRow = min(end.row, snapshot.grid.count - 1)
        for row in start.row...max(lastRow, start.row) {
            if row < snapshot.grid.count {
                let gridRow = snapshot.grid[row]
                let startCol = (row == start.row) ? start.col : 0
                let endCol = (row == end.row)
                    ? min(end.col, gridRow.cells.count - 1)
                    : gridRow.cells.count - 1
                if startCol <= endCol, endCol >= 0, startCol < gridRow.cells.count {
                    var text = gridRow.cells[startCol...endCol].map(\.text).joined()
                    while text.hasSuffix(" ") || text.hasSuffix("\t") { text.removeLast() }
                    current += text
                }
            }
            if row >= lastRow { break }
            // The break after this row belongs to the next row: a soft-wrapped
            // continuation joins without a newline.
            let nextContinues = row + 1 < snapshot.grid.count
                && snapshot.grid[row + 1].wrapContinuation
            if !nextContinues {
                lines.append(current)
                current = ""
            }
        }
        lines.append(current)
        let result = lines.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }
}
