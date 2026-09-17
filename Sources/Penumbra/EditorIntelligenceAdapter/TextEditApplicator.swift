@preconcurrency import AppKit
import EditorIntelligence

/// Applies EIP text edits to a live `TextView`, preserving offsets by applying from end to start.
@MainActor
public enum TextEditApplicator {
    /// Applies `edits` from end to start in one undo group, then restores the caret set that was
    /// active beforehand — shifted through each edit's own length delta, and clamped to an edit's
    /// start when it fell inside that edit's range — instead of leaving whatever single caret the
    /// last individual `replace` call happened to land. Without this, a multi-cursor/block
    /// selection would collapse to one caret every time a formatter or code action ran.
    public static func apply(_ edits: [EditorIntelligence.TextEdit], in textView: TextView) {
        guard !edits.isEmpty else {
            return
        }
        let originalSelections = textView.selectedRanges
        let sorted = edits.sorted {
            let lhs = nsRange(for: $0.range, in: textView)
            let rhs = nsRange(for: $1.range, in: textView)
            return lhs.location > rhs.location
        }
        textView.undoManager?.beginUndoGrouping()
        var adjustedSelections = originalSelections
        for edit in sorted {
            let range = nsRange(for: edit.range, in: textView)
            let delta = (edit.replacement as NSString).length - range.length
            textView.replace(range, withText: edit.replacement)
            adjustedSelections = adjustedSelections.map { selection in
                if selection.location >= range.upperBound {
                    return NSRange(location: selection.location + delta, length: selection.length)
                } else if selection.location >= range.location {
                    // The selection fell inside the edited range — clamp to its start rather
                    // than leave it pointing at whatever content now occupies that offset.
                    return NSRange(location: range.location, length: 0)
                } else {
                    return selection
                }
            }
        }
        textView.undoManager?.endUndoGrouping()
        if adjustedSelections != originalSelections || adjustedSelections.count > 1 {
            textView.selectedRanges = adjustedSelections
        }
    }

    public static func nsRange(for textRange: EditorIntelligence.TextRange, in textView: TextView) -> NSRange {
        let start = position(for: textRange.start, in: textView)
        let end = position(for: textRange.end, in: textView)
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func position(for textPosition: TextPosition, in textView: TextView) -> Int {
        let location = TextLocation(lineNumber: textPosition.line, column: textPosition.column)
        return textView.location(at: location) ?? textPosition.utf16Offset
    }
}
