import Foundation

/// IntelliJ's Smart Home and line end (`EditorActionUtil.moveCaretToLineStart` /
/// `moveCaretToLineEnd`) as pure offset arithmetic, used by ⌘←/→ and Home/End.
///
/// All offsets are document UTF-16 locations. A "fragment" is one visual row of a
/// soft-wrapped line; an unwrapped line is a single fragment spanning the whole line.
enum LineBoundaryNavigator {
    struct Line {
        /// Location of the line's first character.
        var start: Int
        /// Location just before the line break.
        var contentEnd: Int
        /// Location of the first non-whitespace character, or `nil` for a blank line.
        var firstNonWhitespace: Int?
        /// Location just after the last non-whitespace character, or `nil` for a blank line.
        var lastNonWhitespaceEnd: Int?
    }

    /// Where Home / ⌘← moves a caret at `caret`.
    ///
    /// On the line's first row the caret goes to the first non-whitespace character, or to
    /// column 0 when it is already at or before it — so repeated presses toggle between the
    /// two. A blank line toggles between column 0 and the end of its indentation. On a later
    /// soft-wrapped row the caret goes to the row start, then to the line's first
    /// non-whitespace character.
    static func homeTarget(caret: Int, line: Line, fragmentStart: Int) -> Int {
        if fragmentStart > line.start {
            return caret > fragmentStart ? fragmentStart : (line.firstNonWhitespace ?? line.start)
        }
        guard let firstNonWhitespace = line.firstNonWhitespace else {
            return caret == line.start ? line.contentEnd : line.start
        }
        if caret == line.start {
            return firstNonWhitespace
        }
        return firstNonWhitespace >= caret ? line.start : firstNonWhitespace
    }

    /// Where End / ⌘→ moves a caret at `caret`.
    ///
    /// The first press on a line with trailing whitespace stops after its last
    /// non-whitespace character; a caret already there goes to the real end. Rows other than
    /// the line's last one simply go to `fragmentEnd`.
    static func endTarget(caret: Int, line: Line, fragmentEnd: Int) -> Int {
        guard fragmentEnd >= line.contentEnd,
              let lastNonWhitespaceEnd = line.lastNonWhitespaceEnd,
              lastNonWhitespaceEnd < line.contentEnd,
              lastNonWhitespaceEnd != caret else {
            return fragmentEnd
        }
        return lastNonWhitespaceEnd
    }
}
