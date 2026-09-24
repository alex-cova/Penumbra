import EditorIntelligence
import Foundation

/// Turns a formatted copy of a text into the smallest edits that produce it.
enum JavaFormatEdits {
    /// - Parameter lines: when set, only these (0-based, inclusive) original lines may change. This
    ///   needs `new` to have as many lines as `old`; otherwise nothing is returned.
    ///
    /// With equal line counts each changed line becomes its own edit, trimmed to the characters
    /// that differ, so a caret inside a re-indented line moves with its text instead of being
    /// thrown to the start of the line. Otherwise (blank lines were cut) one edit covers the
    /// changed block of lines.
    static func edits(from old: String, to new: String, lines: ClosedRange<Int>? = nil) -> [TextEdit] {
        guard old != new else { return [] }
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        var starts: [Int] = []
        var offset = 0
        for line in oldLines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }

        if oldLines.count == newLines.count {
            var edits: [TextEdit] = []
            for index in oldLines.indices where oldLines[index] != newLines[index] {
                if let lines, !lines.contains(index) { continue }
                let a = Array(oldLines[index].utf16), b = Array(newLines[index].utf16)
                var prefix = 0
                while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
                var suffix = 0
                while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
                let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
                edits.append(TextEdit(
                    range: EditorIntelligence.TextRange(
                        start: TextPosition(line: index, column: prefix, utf16Offset: starts[index] + prefix),
                        end: TextPosition(line: index, column: a.count - suffix, utf16Offset: starts[index] + a.count - suffix)
                    ),
                    replacement: replacement
                ))
            }
            return edits
        }
        guard lines == nil else { return [] }

        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] { prefix += 1 }
        // Keep the last shared line in the block, so the block always starts at a line that exists
        // (adding a final newline shares every old line with the new text).
        prefix = min(prefix, oldLines.count - 1, newLines.count - 1)
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] { suffix += 1 }
        let oldEnd = oldLines.count - suffix
        let newEnd = newLines.count - suffix
        let startOffset = starts[prefix]
        let start = TextPosition(line: prefix, column: 0, utf16Offset: startOffset)
        let end: TextPosition
        if oldEnd < oldLines.count {
            end = TextPosition(line: oldEnd, column: 0, utf16Offset: starts[oldEnd])
        } else {
            let last = oldLines.count - 1
            end = TextPosition(line: last, column: oldLines[last].utf16.count, utf16Offset: offset - 1)
        }
        var replacement = ""
        if newEnd > prefix {
            replacement = newLines[prefix..<newEnd].joined(separator: "\n") + (newEnd < newLines.count ? "\n" : "")
        }
        return [TextEdit(range: EditorIntelligence.TextRange(start: start, end: end), replacement: replacement)]
    }
}
