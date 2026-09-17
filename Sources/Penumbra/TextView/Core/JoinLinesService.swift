import Foundation

/// Pure computation for "join lines" (⌃⇧J): merges a line with the one below it, collapsing
/// the line break and the next line's leading indentation into (usually) a single space.
/// Mirrors `MoveLinesService`'s shape — computes an edit, mutates nothing.
struct JoinLinesService {
    let stringView: StringView
    let lineManager: LineManager

    struct JoinOperation {
        /// The span to replace — from the end of the first line's trimmed content through the
        /// start of the second line's trimmed content.
        let range: NSRange
        /// What to insert in its place (`""` or `" "`).
        let replacement: String
        /// Where the caret should land afterwards (the join point).
        let caretLocation: Int
    }

    /// Joins the line at `row` with `row + 1`. Returns `nil` if `row` is the last line.
    func joinOperation(atRow row: Int) -> JoinOperation? {
        guard row >= 0, row + 1 < lineManager.lineCount else {
            return nil
        }
        let firstLine = lineManager.line(atRow: row)
        let secondLine = lineManager.line(atRow: row + 1)

        let firstContentRange = NSRange(location: firstLine.location, length: firstLine.data.length)
        let secondContentRange = NSRange(location: secondLine.location, length: secondLine.data.length)
        let firstContent = stringView.substring(in: firstContentRange) ?? ""
        let secondContent = stringView.substring(in: secondContentRange) ?? ""

        let firstTrimmedLength = firstContent.count - trailingWhitespaceCount(firstContent)
        let joinStart = firstLine.location + firstTrimmedLength

        let secondLeading = leadingWhitespaceCount(secondContent)
        var joinEnd = secondLine.location + secondLeading

        let firstTrimmed = String(firstContent.prefix(firstTrimmedLength))
        var secondTrimmed = String(secondContent.dropFirst(secondLeading))

        // Two adjacent `//` line comments: drop the second `//` so the text reads as one comment.
        if firstTrimmed.hasPrefix("//"), secondTrimmed.hasPrefix("//") {
            let afterSlashes = secondTrimmed.dropFirst(2)
            let extraLeading = afterSlashes.prefix { $0 == " " || $0 == "\t" }.count
            joinEnd += 2 + extraLeading
            secondTrimmed = String(afterSlashes.dropFirst(extraLeading))
        }

        let replacement = separator(firstTrimmed: firstTrimmed, secondTrimmed: secondTrimmed)
        let range = NSRange(location: joinStart, length: max(0, joinEnd - joinStart))
        return JoinOperation(range: range, replacement: replacement, caretLocation: joinStart)
    }

    private func separator(firstTrimmed: String, secondTrimmed: String) -> String {
        if firstTrimmed.isEmpty || secondTrimmed.isEmpty {
            return ""
        }
        if let opener = firstTrimmed.last, "([{".contains(opener) {
            return ""
        }
        if let closer = secondTrimmed.first, ")]},;".contains(closer) {
            return ""
        }
        return " "
    }

    private func leadingWhitespaceCount(_ string: String) -> Int {
        string.prefix { $0 == " " || $0 == "\t" }.count
    }

    private func trailingWhitespaceCount(_ string: String) -> Int {
        string.reversed().prefix { $0 == " " || $0 == "\t" }.count
    }
}
