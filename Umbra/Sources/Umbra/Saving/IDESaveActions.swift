import Foundation

/// Which lines Strip Trailing Spaces on Save touches.
enum IDEStripWhitespaceScope: String, CaseIterable, Codable, Identifiable {
    case off
    /// The lines that differ from the last commit (from the file on disk outside a repository).
    case modifiedLines
    case allLines

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "None"
        case .modifiedLines: "Modified Lines"
        case .allLines: "All Lines"
        }
    }
}

/// The text edits behind Settings ▸ Saving ▸ Actions on Save. Pure: they read the text and say what
/// to replace, so they are tested without an editor, and the pipeline applies the result as one
/// undo step.
enum IDESaveActions {
    /// A UTF-16 range of the text and what replaces it.
    typealias Replacement = (range: NSRange, text: String)

    /// Languages whose trailing spaces mean something: two of them end a Markdown line, and a
    /// patch's context lines carry theirs.
    static let languagesKeepingTrailingWhitespace: Set<String> = ["markdown", "diff"]

    /// Above this many UTF-16 units the text actions are skipped: they read the whole buffer, and a
    /// save must not stall on a generated file.
    static let maximumTextLength = 4_000_000

    // MARK: Changed lines

    /// The rows of `current` that differ from `base`, per the line diff. A `nil` base (a file that
    /// is new) makes every row changed. A middle over 20,000 lines on either side counts as one
    /// changed span, as the change markers do.
    static func changedRows(base: String?, current: String) -> Set<Int> {
        let right = IDEDiffText(current)
        guard let base else { return Set(0 ..< right.lineCount) }
        let chunks = IDEDiffComputer.lineChunks(left: IDEDiffText(base), right: right, maximumMiddle: 20_000)
        var rows = Set<Int>()
        for chunk in chunks { rows.formUnion(chunk.right) }
        return rows
    }

    /// The content ranges (no line break) of `rows`, with neighbouring rows merged into one range,
    /// in `text`.
    static func ranges(ofRows rows: Set<Int>, in text: String) -> [NSRange] {
        guard !rows.isEmpty else { return [] }
        let lines = IDEDiffText(text).lines
        var result: [NSRange] = []
        var runStart: Int?
        var runEnd = 0
        for row in rows.sorted() where row < lines.count {
            let range = lines[row]
            if let start = runStart, row == runEnd + 1 {
                result[result.count - 1] = NSRange(location: start, length: NSMaxRange(range) - start)
            } else {
                runStart = range.location
                result.append(range)
            }
            runEnd = row
        }
        return result
    }

    /// The row holding UTF-16 `offset` (the end of a line belongs to that line).
    static func row(containing offset: Int, in lines: [NSRange]) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].location <= offset { low = mid } else { high = mid - 1 }
        }
        return max(0, low)
    }

    // MARK: Whitespace

    /// Removes the trailing spaces and tabs of `rows` (every row when `nil`), except on
    /// `keepingRows`. A carriage return before a line feed is a line break, not whitespace.
    static func trailingWhitespaceReplacements(
        in text: String, rows: Set<Int>?, keepingRows: Set<Int> = []
    ) -> [Replacement] {
        let ns = text as NSString
        let lines = IDEDiffText(text).lines
        var replacements: [Replacement] = []
        for (row, line) in lines.enumerated() {
            if let rows, !rows.contains(row) { continue }
            if keepingRows.contains(row) { continue }
            var end = NSMaxRange(line)
            while end > line.location {
                let unit = ns.character(at: end - 1)
                guard unit == 0x20 || unit == 0x09 else { break }
                end -= 1
            }
            if end < NSMaxRange(line) {
                replacements.append((NSRange(location: end, length: NSMaxRange(line) - end), ""))
            }
        }
        return replacements
    }

    /// A line break at the end of `text` when it has none, in the file's own style. An empty file
    /// stays empty.
    static func finalNewlineReplacement(in text: String) -> Replacement? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let last = ns.character(at: ns.length - 1)
        guard last != 0x0A, last != 0x0D else { return nil }
        let lineBreak = text.contains("\r\n") ? "\r\n" : "\n"
        return (NSRange(location: ns.length, length: 0), lineBreak)
    }
}
