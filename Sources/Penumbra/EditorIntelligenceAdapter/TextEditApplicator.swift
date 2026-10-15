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
        apply(replacements: edits.map { (nsRange(for: $0.range, in: textView), $0.replacement) }, in: textView)
    }

    /// Applies replacements given as UTF-16 ranges of the text as it is now, last to first, as one
    /// undo step, with the selections following as in ``apply(_:in:)``. The ranges must not overlap.
    public static func apply(replacements: [(range: NSRange, text: String)], in textView: TextView) {
        guard !replacements.isEmpty else {
            return
        }
        let originalSelections = textView.selectedRanges
        let sorted = replacements.sorted { $0.range.location > $1.range.location }
        textView.undoManager?.beginUndoGrouping()
        var adjustedSelections = originalSelections
        for replacement in sorted {
            let range = replacement.range
            let delta = (replacement.text as NSString).length - range.length
            textView.replace(range, withText: replacement.text)
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
