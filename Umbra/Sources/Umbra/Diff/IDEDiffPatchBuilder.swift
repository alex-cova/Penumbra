import Foundation

/// Builds a one-hunk patch with no context lines: the description of one change that
/// `GitRepository.applyHunk` swaps into the index blob. It is also a valid `git apply --unidiff-zero`
/// patch, which the tests check against real git.
enum IDEDiffPatchBuilder {
    /// The patch turning `chunk`'s left lines into its right lines in `path` (relative to the
    /// repository root), or nil when the chunk is only the editor's empty last line (a final line
    /// break added or removed), which git does not count as a line.
    static func patch(for chunk: IDEDiffChunk, left: IDEDiffText, right: IDEDiffText, path: String) -> String? {
        let leftLines = GitLines(left)
        let rightLines = GitLines(right)
        var leftRange = chunk.left.clamped(to: 0 ..< leftLines.count)
        var rightRange = chunk.right.clamped(to: 0 ..< rightLines.count)
        guard !leftRange.isEmpty || !rightRange.isEmpty else { return nil }
        let oldName = headerPath("a/" + path)
        let newName = headerPath("b/" + path)
        // Adding after a last line that has no line break changes that line too (it gains one):
        // take it into the hunk on both sides.
        let appendsToUnterminatedLeft = leftRange.isEmpty && leftRange.lowerBound == leftLines.count
            && leftLines.count > 0 && !leftLines.endsWithLineBreak
        let appendsToUnterminatedRight = rightRange.isEmpty && rightRange.lowerBound == rightLines.count
            && rightLines.count > 0 && !rightLines.endsWithLineBreak
        if (appendsToUnterminatedLeft || appendsToUnterminatedRight),
           leftRange.lowerBound > 0, rightRange.lowerBound > 0 {
            leftRange = leftRange.lowerBound - 1 ..< leftRange.upperBound
            rightRange = rightRange.lowerBound - 1 ..< rightRange.upperBound
        }
        var patch = "diff --git \(oldName) \(newName)\n--- \(oldName)\n+++ \(newName)\n"
        patch += "@@ -\(header(leftRange)) +\(header(rightRange)) @@\n"
        for index in leftRange {
            patch += "-" + leftLines.line(index)
        }
        for index in rightRange {
            patch += "+" + rightLines.line(index)
        }
        return patch
    }

    /// A name as git writes it in a diff header (`a/dir/file`): C-quoted, prefix inside the quotes
    /// (`"a/tab\\tname.txt"`), when it holds a quote, a backslash or a control character; plain
    /// otherwise (a space needs no quotes).
    static func headerPath(_ path: String) -> String {
        guard path.unicodeScalars.contains(where: { $0 == "\"" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }) else {
            return path
        }
        var quoted = ""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\t": quoted += "\\t"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    quoted += "\\" + String(format: "%03o", scalar.value)
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"" + quoted + "\""
    }

    /// `start,count`, where an empty range names the line before it, as zero-context hunks do.
    private static func header(_ range: Range<Int>) -> String {
        let start = range.isEmpty ? range.lowerBound : range.lowerBound + 1
        return "\(start),\(range.count)"
    }

    /// The text's lines as git counts them: the editor's empty last line after a final line break
    /// is not one.
    private struct GitLines {
        let text: IDEDiffText
        let count: Int
        let endsWithLineBreak: Bool

        init(_ text: IDEDiffText) {
            self.text = text
            let lastIsEmpty = text.lines.last?.length == 0
            count = lastIsEmpty ? text.lineCount - 1 : text.lineCount
            endsWithLineBreak = lastIsEmpty && text.lineCount > 1
        }

        /// The line with its own line break ("\r\n" kept), or git's marker when it has none.
        func line(_ index: Int) -> String {
            let full = (text.string as NSString).substring(with: text.range(ofLines: index ..< index + 1))
            // UTF-16, not `Character`: Swift reads "\r\n" as one character, which ends in neither.
            if full.utf16.last == 10 { return full }
            if full.utf16.last == 13 { return full + "\n" }
            return full + "\n\\ No newline at end of file\n"
        }
    }
}
