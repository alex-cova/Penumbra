import Foundation

/// Pure computation for "toggle line comment" (⌘/): comments every touched line with the active
/// language's line-comment prefix, or uncomments them if every touched (non-blank) line is
/// already commented. Mirrors `JoinLinesService`'s shape — computes edits, mutates nothing;
/// `TextInputView` applies them under one undo group, `shiftAllSelections`-style (see
/// `TextInputView.toggleComment()`).
struct CommentToggleService {
    let stringView: StringView
    let lineManager: LineManager
    let commentPrefix: String

    enum Direction: Equatable {
        case comment
        case uncomment
    }

    /// One per-row edit: replace `range` with `replacement`. `editColumn` is the UTF-16 column
    /// (within the row, before the edit) where the insertion/removal happens — a caret at or
    /// after this column shifts by `delta` when the edit is applied; a caret strictly before it
    /// (e.g. sitting inside the row's leading whitespace) does not.
    struct RowEdit {
        let row: Int
        let range: NSRange
        let replacement: String
        let editColumn: Int
        var delta: Int { replacement.utf16.count - range.length }
    }

    /// Comment if any touched row with non-whitespace content lacks the prefix; uncomment only
    /// when every touched row is blank or already commented (matching VS Code/Zed: a selection
    /// mixing commented and uncommented lines always comments first).
    func direction(forRows rows: Set<Int>) -> Direction {
        for row in rows.sorted() where row < lineManager.lineCount {
            let content = lineContent(atRow: row)
            let trimmed = content.drop { $0 == " " || $0 == "\t" }
            guard !trimmed.isEmpty else { continue }
            if !trimmed.hasPrefix(commentPrefix) {
                return .comment
            }
        }
        return .uncomment
    }

    /// One edit per row that needs one. Commenting touches every row (blank lines included, so a
    /// fully-blank selection still gets commented rather than silently no-op'ing). Uncommenting
    /// skips rows that aren't actually commented (e.g. a blank line inside an otherwise-commented
    /// block).
    func edits(forRows rows: Set<Int>, direction: Direction) -> [RowEdit] {
        rows.sorted().compactMap { row -> RowEdit? in
            guard row < lineManager.lineCount else { return nil }
            let line = lineManager.line(atRow: row)
            let content = lineContent(atRow: row)
            let leadingWhitespace = content.prefix { $0 == " " || $0 == "\t" }
            // Leading whitespace is only ASCII space/tab, so Character count == UTF-16 count here
            // (matches `JoinLinesService.leadingWhitespaceCount`'s equivalent assumption).
            let editColumn = leadingWhitespace.count
            let editLocation = line.location + editColumn
            switch direction {
            case .comment:
                return RowEdit(
                    row: row,
                    range: NSRange(location: editLocation, length: 0),
                    replacement: commentPrefix + " ",
                    editColumn: editColumn
                )
            case .uncomment:
                let rest = content[leadingWhitespace.endIndex...]
                guard rest.hasPrefix(commentPrefix) else { return nil }
                var removedLength = commentPrefix.utf16.count
                if rest.dropFirst(commentPrefix.count).first == " " {
                    removedLength += 1
                }
                return RowEdit(
                    row: row,
                    range: NSRange(location: editLocation, length: removedLength),
                    replacement: "",
                    editColumn: editColumn
                )
            }
        }
    }

    private func lineContent(atRow row: Int) -> String {
        let line = lineManager.line(atRow: row)
        return stringView.substring(in: NSRange(location: line.location, length: line.data.length)) ?? ""
    }
}
