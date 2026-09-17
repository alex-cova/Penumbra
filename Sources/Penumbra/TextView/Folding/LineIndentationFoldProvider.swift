import Foundation

/// A fold provider that derives fold regions purely from leading-whitespace indentation, with no
/// awareness of language syntax. This is a reasonable default for any language and is used
/// automatically unless a more precise provider (e.g. a tree-sitter-backed one) is installed.
final class LineIndentationFoldProvider: LineFoldProvider {
    /// Number of leading whitespace characters that make up one indentation level.
    var columnsPerIndentLevel: Int

    init(columnsPerIndentLevel: Int = 4) {
        self.columnsPerIndentLevel = columnsPerIndentLevel
    }

    func foldEvents(atLine lineIndex: Int,
                     previousDepth: Int,
                     in lineManager: LineManager,
                     stringView: StringView) -> [LineFoldEvent] {
        guard lineIndex < lineManager.lineCount, let (depth, _) = indentDepth(atRow: lineIndex, in: lineManager, stringView: stringView) else {
            // Blank or fully-whitespace lines don't affect fold depth.
            return []
        }
        var events: [LineFoldEvent] = []
        if depth < previousDepth {
            events.append(.endFold(depth: depth))
        }
        if let nextDepth = nextNonBlankIndentDepth(afterRow: lineIndex, in: lineManager, stringView: stringView), nextDepth > depth {
            events.append(.startFold(depth: nextDepth))
        }
        return events
    }
}

private extension LineIndentationFoldProvider {
    /// Returns the indentation depth of the given row, along with its leading-whitespace
    /// character count, or `nil` if the row is empty or entirely whitespace.
    private func indentDepth(atRow row: Int, in lineManager: LineManager, stringView: StringView) -> (depth: Int, leadingWhitespaceCount: Int)? {
        let line = lineManager.line(atRow: row)
        let range = NSRange(location: line.location, length: line.data.length)
        guard range.length > 0, let text = stringView.substring(in: range) else {
            return nil
        }
        var leadingWhitespaceCount = 0
        for character in text {
            if character.isWhitespace {
                leadingWhitespaceCount += 1
            } else {
                break
            }
        }
        guard leadingWhitespaceCount < text.count else {
            // Entirely whitespace.
            return nil
        }
        let depth = leadingWhitespaceCount / max(columnsPerIndentLevel, 1)
        return (depth, leadingWhitespaceCount)
    }

    private func nextNonBlankIndentDepth(afterRow row: Int, in lineManager: LineManager, stringView: StringView) -> Int? {
        var candidateRow = row + 1
        while candidateRow < lineManager.lineCount {
            if let (depth, _) = indentDepth(atRow: candidateRow, in: lineManager, stringView: stringView) {
                return depth
            }
            candidateRow += 1
        }
        return nil
    }
}
