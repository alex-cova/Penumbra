import EditorIntelligence
import Foundation

enum FoldingDescriptorConversion {
    static func lineRange(
        for descriptor: FoldingDescriptor,
        in lineManager: LineManager
    ) -> ClosedRange<Int>? {
        let startOffset = descriptor.range.start.utf16Offset
        let endOffset = descriptor.range.end.utf16Offset
        guard endOffset > startOffset else {
            return nil
        }
        guard let startRow = lineManager.row(containingCharacterAt: startOffset) else {
            return nil
        }
        let endCharacter = max(endOffset - 1, startOffset)
        guard let endRow = lineManager.row(containingCharacterAt: endCharacter) else {
            return nil
        }
        guard endRow >= startRow else {
            return nil
        }
        return startRow ... endRow
    }

    static func textRange(
        for lineRange: ClosedRange<Int>,
        in lineManager: LineManager
    ) -> EditorIntelligence.TextRange? {
        guard lineRange.lowerBound >= 0, lineRange.upperBound < lineManager.lineCount else {
            return nil
        }
        let start = lineManager.location(ofRow: lineRange.lowerBound)
        let endLine = lineManager.contentRange(atRow: lineRange.upperBound)
        let end = endLine.upperBound
        return EditorIntelligence.TextRange(
            start: TextPosition(line: lineRange.lowerBound, column: 0, utf16Offset: start),
            end: TextPosition(line: lineRange.upperBound, column: 0, utf16Offset: end)
        )
    }

    static func makePosition(line: Int, utf16Offset: Int, in text: String) -> TextPosition {
        let ns = text as NSString
        var column = 0
        var currentLine = 0
        var index = 0
        while index < ns.length && currentLine < line {
            if ns.character(at: index) == 10 {
                currentLine += 1
            }
            index += 1
        }
        column = utf16Offset - index
        return TextPosition(line: line, column: max(0, column), utf16Offset: utf16Offset)
    }
}
