import EditorIntelligence
import Foundation

/// Folds the unchanged runs between changes for "Collapse Unchanged Fragments", keeping
/// `context` lines next to each change. Each fold keeps its first line visible as the header.
struct IDEDiffUnchangedFoldingProvider: FoldingProviding {
    let changedLines: [Range<Int>]
    let context: Int
    let name = "diff-unchanged"

    func foldRegions(for document: EditorIntelligence.Document) async -> [FoldingDescriptor] {
        let text = IDEDiffText(document.text)
        var descriptors: [FoldingDescriptor] = []
        var start = 0
        for range in changedLines + [text.lineCount + context ..< text.lineCount + context] {
            let end = min(range.lowerBound - context, text.lineCount) - 1
            let first = start == 0 ? 0 : start + context
            if end - first >= 2 {
                let lower = text.lines[first].location
                let upper = NSMaxRange(text.lines[end])
                descriptors.append(FoldingDescriptor(
                    range: EditorIntelligence.TextRange(
                        start: TextPosition(line: first, column: 0, utf16Offset: lower),
                        end: TextPosition(line: end, column: 0, utf16Offset: upper)
                    ),
                    placeholder: "\(end - first) unchanged lines",
                    collapsedByDefault: true
                ))
            }
            start = max(start, range.upperBound)
        }
        return descriptors
    }
}
