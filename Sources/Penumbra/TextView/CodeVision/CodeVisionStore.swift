import CoreGraphics
import EditorIntelligence
import Foundation

/// The lenses above declarations, by row. Sorted, one per row, kept on their lines through edits
/// like the gutter's line markers: an edit that moves no line break costs nothing, one that does
/// shifts the lenses below it.
final class CodeVisionStore {
    struct Lens: Equatable {
        var row: Int
        /// UTF-16 column of the declaration's name in its line (the click's anchor).
        var column: Int
        var entries: [CodeVisionEntry]
    }

    private(set) var lenses: [Lens] = []
    /// Height of the room above a lens row. 0 until the layout knows the font.
    var rowHeight: CGFloat = 0

    var isEmpty: Bool {
        lenses.isEmpty
    }

    /// Replaces every lens. `newLenses` need not be sorted; the first of two on one row wins.
    func replace(with newLenses: [Lens]) {
        var sorted = newLenses.sorted { $0.row < $1.row }
        var unique: [Lens] = []
        unique.reserveCapacity(sorted.count)
        for lens in sorted where unique.last?.row != lens.row {
            unique.append(lens)
        }
        sorted = []
        lenses = unique
    }

    /// The room above the text of `row`: ``rowHeight`` when it carries a lens, else 0.
    func inset(forRow row: Int) -> CGFloat {
        index(ofRow: row) == nil ? 0 : rowHeight
    }

    func lens(atRow row: Int) -> Lens? {
        index(ofRow: row).map { lenses[$0] }
    }

    /// The lenses on rows `rows`, in row order.
    func lenses(inRows rows: ClosedRange<Int>) -> ArraySlice<Lens> {
        let start = firstIndex(atOrAfterRow: rows.lowerBound)
        var end = start
        while end < lenses.count, lenses[end].row <= rows.upperBound {
            end += 1
        }
        return lenses[start ..< end]
    }

    /// Moves the lenses through an edit. Returns whether any moved or went.
    @discardableResult
    func applyEdit(_ edit: GutterLineMarkerEdit) -> Bool {
        // Typing within a line, or any edit that adds and removes no line break, leaves every row.
        guard edit.lineDelta != 0 || edit.removedRows != 0 else {
            return false
        }
        let start = firstIndex(atOrAfterRow: edit.startRow)
        guard start < lenses.count else {
            return false
        }
        var result = Array(lenses[..<start])
        var changed = false
        for lens in lenses[start...] {
            guard let newRow = edit.newRow(forRow: lens.row) else {
                changed = true
                continue
            }
            var moved = lens
            moved.row = newRow
            if newRow != lens.row { changed = true }
            if result.last?.row == newRow {
                changed = true
                continue
            }
            result.append(moved)
        }
        lenses = result
        return changed
    }

    // MARK: - Lookup

    private func firstIndex(atOrAfterRow row: Int) -> Int {
        var low = 0
        var high = lenses.count
        while low < high {
            let mid = (low + high) / 2
            if lenses[mid].row < row { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func index(ofRow row: Int) -> Int? {
        let candidate = firstIndex(atOrAfterRow: row)
        return candidate < lenses.count && lenses[candidate].row == row ? candidate : nil
    }
}
