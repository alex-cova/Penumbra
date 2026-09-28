import Foundation

public extension WorkspaceSearchQuery {
    /// The regular expression this query searches with: the text as typed in regex mode, otherwise
    /// the text matched literally, optionally as a whole word; case-insensitive unless
    /// ``isCaseSensitive``. `nil` for an invalid pattern. Search and replace both use it, so what
    /// Replace changes is exactly what the search listed.
    func compiledRegularExpression() -> NSRegularExpression? {
        let pattern: String
        if useRegularExpression {
            pattern = text
        } else {
            let escaped = NSRegularExpression.escapedPattern(for: text)
            pattern = matchWholeWord ? "\\b\(escaped)\\b" : escaped
        }
        return try? NSRegularExpression(pattern: pattern, options: isCaseSensitive ? [] : [.caseInsensitive])
    }
}

/// Turns a search query and a replacement into the edits "Replace in Files" would make, without
/// touching anything, so they can be previewed first.
public enum ProjectReplacePlanner {
    /// The replacement as a `NSRegularExpression` template: what was typed in regex mode (so `$1`
    /// and `$0` name capture groups), and the text taken literally otherwise.
    public static func template(for query: WorkspaceSearchQuery, replacement: String) -> String {
        query.useRegularExpression ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
    }

    /// One entry per match in `text` that the replacement would actually change, in document order.
    /// A match that would be replaced by itself is left out.
    public static func entries(
        for query: WorkspaceSearchQuery,
        replacement: String,
        in text: String,
        url: URL
    ) -> [WorkspaceEditPlanEntry] {
        guard !query.text.isEmpty, let regex = query.compiledRegularExpression() else {
            return []
        }
        let nsText = text as NSString
        let template = template(for: query, replacement: replacement)
        let lineStarts = Self.lineStarts(in: nsText)
        var entries: [WorkspaceEditPlanEntry] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let range = match.range
            let oldText = nsText.substring(with: range)
            let newText = regex.replacementString(for: match, in: text, offset: 0, template: template)
            guard newText != oldText else { continue }
            let start = position(of: range.location, lineStarts: lineStarts)
            let end = position(of: range.location + range.length, lineStarts: lineStarts)
            // `\r\n` is one Character in Swift, so trim by character set rather than by suffix.
            let lineText = nsText.substring(with: nsText.lineRange(for: NSRange(location: range.location, length: 0)))
                .trimmingCharacters(in: .newlines)
            entries.append(WorkspaceEditPlanEntry(
                url: url,
                range: TextRange(start: start, end: end),
                oldText: oldText,
                newText: newText,
                lineText: lineText
            ))
        }
        return entries
    }

    /// UTF-16 offsets at which each line starts (lines end at `\n`).
    private static func lineStarts(in text: NSString) -> [Int] {
        var starts = [0]
        var index = 0
        let length = text.length
        while index < length {
            if text.character(at: index) == 0x0A { starts.append(index + 1) }
            index += 1
        }
        return starts
    }

    private static func position(of offset: Int, lineStarts: [Int]) -> TextPosition {
        // The last line start at or before `offset`.
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return TextPosition(line: low, column: offset - lineStarts[low], utf16Offset: offset)
    }
}
