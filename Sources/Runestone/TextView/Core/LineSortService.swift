import Foundation

/// Pure computation for "sort lines" (command palette / Find Action, no default keybinding):
/// reorders every line in a contiguous row block by its content. Mirrors `JoinLinesService`'s
/// shape — computes one replacement string for the whole block, mutates nothing.
struct LineSortService {
    let stringView: StringView
    let lineManager: LineManager
    /// The document's own preferred line ending, used to join the reordered lines. A file with
    /// genuinely mixed per-line endings is normalized to this one symbol internally — matching
    /// how most editors' sort-lines command behaves; only the block's own leading/trailing edge
    /// (present or absent) is preserved exactly.
    let lineEndingSymbol: String

    struct SortOperation {
        /// The whole block: the first row's start through the last row's end (its delimiter, if
        /// any, included).
        let range: NSRange
        let replacement: String
    }

    /// Sorts `rows` (a contiguous block) by content, case-sensitive. Returns `nil` for a
    /// single-row block — there's nothing to reorder.
    func sortOperation(forRows rows: ClosedRange<Int>, descending: Bool) -> SortOperation? {
        guard rows.count > 1, rows.upperBound < lineManager.lineCount else {
            return nil
        }
        let firstLine = lineManager.line(atRow: rows.lowerBound)
        let lastLine = lineManager.line(atRow: rows.upperBound)
        let blockRange = NSRange(
            location: firstLine.location,
            length: lastLine.location + lastLine.data.totalLength - firstLine.location
        )
        let contents = rows.map { row -> String in
            let line = lineManager.line(atRow: row)
            return stringView.substring(in: NSRange(location: line.location, length: line.data.length)) ?? ""
        }
        let sorted = contents.sorted { descending ? $0 > $1 : $0 < $1 }
        var replacement = sorted.joined(separator: lineEndingSymbol)
        // Only the block's own trailing edge is preserved — whether it originally ended mid-
        // document (has a delimiter) or was the document's final, unterminated line (doesn't).
        if lastLine.data.delimiterLength > 0 {
            replacement += lineEndingSymbol
        }
        return SortOperation(range: blockRange, replacement: replacement)
    }
}
