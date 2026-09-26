import EditorIntelligence
import Foundation

/// Indentation-based folding fallback for plain text and languages without a tree-sitter provider.
final class IndentationFoldingProvider: FoldingProviding, @unchecked Sendable {
    let name = "indentation"
    let columnsPerIndentLevel: Int

    init(columnsPerIndentLevel: Int = 4) {
        self.columnsPerIndentLevel = columnsPerIndentLevel
    }

    func foldRegions(for document: Document) async -> [FoldingDescriptor] {
        let text = document.text
        guard !text.isEmpty else {
            return []
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else {
            return []
        }

        var descriptors: [FoldingDescriptor] = []
        var lineStartOffsets: [Int] = []
        lineStartOffsets.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            lineStartOffsets.append(offset)
            offset += line.utf16.count + 1
        }

        var depthStack: [(depth: Int, startRow: Int)] = []
        var previousDepth = 0

        for (row, line) in lines.enumerated() {
            guard let depth = indentDepth(in: String(line)) else {
                continue
            }
            if depth < previousDepth {
                while let top = depthStack.last, top.depth > depth {
                    depthStack.removeLast()
                    let endRow = row - 1
                    if endRow > top.startRow, let descriptor = makeDescriptor(
                        startRow: top.startRow,
                        endRow: endRow,
                        lineStartOffsets: lineStartOffsets,
                        textLength: (text as NSString).length
                    ) {
                        descriptors.append(descriptor)
                    }
                }
            }
            if let nextDepth = nextNonBlankIndentDepth(afterRow: row, in: lines), nextDepth > depth {
                depthStack.append((depth: nextDepth, startRow: row))
            }
            previousDepth = depth
        }

        let lastRow = lines.count - 1
        for top in depthStack {
            if lastRow > top.startRow, let descriptor = makeDescriptor(
                startRow: top.startRow,
                endRow: lastRow,
                lineStartOffsets: lineStartOffsets,
                textLength: (text as NSString).length
            ) {
                descriptors.append(descriptor)
            }
        }

        return descriptors.sorted {
            $0.range.start.utf16Offset < $1.range.start.utf16Offset
        }
    }

    private func indentDepth(in line: String) -> Int? {
        var leadingWhitespaceCount = 0
        var hasContent = false
        for character in line {
            if character.isWhitespace {
                leadingWhitespaceCount += 1
            } else {
                hasContent = true
                break
            }
        }
        guard hasContent else {
            return nil
        }
        return leadingWhitespaceCount / max(columnsPerIndentLevel, 1)
    }

    private func nextNonBlankIndentDepth(
        afterRow row: Int,
        in lines: [Substring]
    ) -> Int? {
        var candidateRow = row + 1
        while candidateRow < lines.count {
            if let depth = indentDepth(in: String(lines[candidateRow])) {
                return depth
            }
            candidateRow += 1
        }
        return nil
    }

    private func makeDescriptor(
        startRow: Int,
        endRow: Int,
        lineStartOffsets: [Int],
        textLength: Int
    ) -> FoldingDescriptor? {
        guard startRow >= 0, endRow >= startRow, startRow < lineStartOffsets.count else {
            return nil
        }
        let startOffset = lineStartOffsets[startRow]
        let endOffset = min(
            endRow + 1 < lineStartOffsets.count ? lineStartOffsets[endRow + 1] : textLength,
            textLength
        )
        guard endOffset > startOffset else {
            return nil
        }
        return FoldingDescriptor(
            range: EditorIntelligence.TextRange(
                start: TextPosition(line: startRow, column: 0, utf16Offset: startOffset),
                end: TextPosition(line: endRow, column: 0, utf16Offset: endOffset)
            ),
            placeholder: "..."
        )
    }
}
