import EditorIntelligence
import Foundation

/// Tree-sitter folding provider that emits fold descriptors from syntax nodes.
final class TreeSitterFoldingProvider: FoldingProviding, @unchecked Sendable {
    let name = "tree-sitter"
    weak var languageMode: TreeSitterInternalLanguageMode?

    private var cachedLineCount = -1
    private var regions: [(startRow: Int, endRow: Int, placeholder: String)] = []
    private var needsFullRebuild = true
    private var dirtyRows: ClosedRange<Int>?

    func isPrimary(for languageIdentifier: String?) -> Bool {
        languageIdentifier != nil
    }

    func invalidate() {
        cachedLineCount = -1
        regions = []
        needsFullRebuild = true
        dirtyRows = nil
    }

    func invalidateForEdit(changedRows: ClosedRange<Int>?, lineCount: Int, previousLineCount: Int, spliceRow: Int) {
        if needsFullRebuild {
            return
        }
        let delta = lineCount - previousLineCount
        if delta != 0 {
            shiftRegions(afterRow: spliceRow, by: delta)
        }
        if let changedRows {
            dirtyRows = dirtyRows.map { Self.merge($0, changedRows) } ?? changedRows
        } else {
            needsFullRebuild = true
        }
    }

    func foldRegions(for document: Document) async -> [FoldingDescriptor] {
        let lineCount = lineCount(in: document)
        rebuildIfNeeded(document: document, lineCount: lineCount)
        return descriptors(from: regions, text: document.text)
    }
}

private extension TreeSitterFoldingProvider {
    private static func merge(_ lhs: ClosedRange<Int>, _ rhs: ClosedRange<Int>) -> ClosedRange<Int> {
        min(lhs.lowerBound, rhs.lowerBound) ... max(lhs.upperBound, rhs.upperBound)
    }

    private func lineCount(in document: Document) -> Int {
        let text = document.text
        guard !text.isEmpty else {
            return 0
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private func rebuildIfNeeded(document: Document, lineCount: Int) {
        if needsFullRebuild {
            fullRebuild(document: document, lineCount: lineCount)
            return
        }
        if let dirtyRows {
            incrementalRebuild(document: document, lineCount: lineCount, dirtyRows: dirtyRows)
            self.dirtyRows = nil
            return
        }
        if cachedLineCount != lineCount {
            fullRebuild(document: document, lineCount: lineCount)
        }
    }

    private func fullRebuild(document: Document, lineCount: Int) {
        cachedLineCount = lineCount
        regions = []
        needsFullRebuild = false
        dirtyRows = nil
        guard let languageMode, let rootNode = languageMode.rootSyntaxNode, lineCount > 0 else {
            return
        }
        collectFoldRegions(from: rootNode, overlapping: nil, into: &regions)
    }

    private func incrementalRebuild(document: Document, lineCount: Int, dirtyRows: ClosedRange<Int>) {
        guard lineCount > 0 else {
            regions = []
            cachedLineCount = 0
            return
        }
        let start = max(0, dirtyRows.lowerBound)
        let end = min(lineCount - 1, dirtyRows.upperBound)
        guard start <= end else {
            cachedLineCount = lineCount
            return
        }
        let query = start ... end
        regions.removeAll { regionOverlaps($0, query) }
        if let languageMode, let rootNode = languageMode.rootSyntaxNode {
            collectFoldRegions(from: rootNode, overlapping: query, into: &regions)
        }
        cachedLineCount = lineCount
    }

    private func shiftRegions(afterRow row: Int, by delta: Int) {
        guard delta != 0 else {
            return
        }
        var shifted: [(startRow: Int, endRow: Int, placeholder: String)] = []
        shifted.reserveCapacity(regions.count)
        for region in regions {
            var start = region.startRow
            var end = region.endRow
            if start >= row {
                start += delta
            }
            if end >= row {
                end += delta
            }
            if end > start, start >= 0 {
                shifted.append((start, end, region.placeholder))
            }
        }
        regions = shifted
    }

    private func regionOverlaps(_ region: (startRow: Int, endRow: Int, placeholder: String), _ rows: ClosedRange<Int>) -> Bool {
        region.endRow >= rows.lowerBound && region.startRow <= rows.upperBound
    }

    private func collectFoldRegions(
        from node: TreeSitterNode,
        overlapping rows: ClosedRange<Int>?,
        into regions: inout [(startRow: Int, endRow: Int, placeholder: String)]
    ) {
        let startRow = Int(node.startPoint.row)
        let endRow = Int(node.endPoint.row)
        if let rows, endRow < rows.lowerBound || startRow > rows.upperBound {
            return
        }
        if isFoldable(node), endRow > startRow {
            let placeholder = placeholder(for: node.type ?? "")
            regions.append((startRow, max(startRow, endRow - 1), placeholder))
        }
        for index in 0..<node.childCount {
            if let child = node.child(at: index) {
                collectFoldRegions(from: child, overlapping: rows, into: &regions)
            }
        }
    }

    private func isFoldable(_ node: TreeSitterNode) -> Bool {
        guard let type = node.type, node.childCount > 0 else {
            return false
        }
        if type.contains("comment") || type == "ERROR" || type == "program" {
            return false
        }
        let foldableHints = [
            "block", "body", "function", "class", "method", "struct", "enum",
            "interface", "namespace", "module", "switch", "try", "catch", "statement"
        ]
        return foldableHints.contains(where: { type.contains($0) })
    }

    private func placeholder(for nodeType: String) -> String {
        if nodeType.contains("comment") {
            return "/*...*/"
        }
        if nodeType.contains("import") || nodeType.contains("package") {
            return "import ..."
        }
        if nodeType.contains("block") || nodeType.contains("body") || nodeType.contains("class")
            || nodeType.contains("function") || nodeType.contains("method") {
            return "{...}"
        }
        return "..."
    }

    private func descriptors(
        from regions: [(startRow: Int, endRow: Int, placeholder: String)],
        text: String
    ) -> [FoldingDescriptor] {
        guard !text.isEmpty else {
            return []
        }
        let ns = text as NSString
        var lineStarts: [Int] = []
        var offset = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineStarts.append(offset)
            offset += line.utf16.count + 1
        }
        var descriptors: [FoldingDescriptor] = []
        descriptors.reserveCapacity(regions.count)
        for region in regions {
            guard region.startRow >= 0, region.startRow < lineStarts.count else {
                continue
            }
            let startOffset = lineStarts[region.startRow]
            let endOffset = region.endRow + 1 < lineStarts.count ? lineStarts[region.endRow + 1] : ns.length
            guard endOffset > startOffset else {
                continue
            }
            descriptors.append(
                FoldingDescriptor(
                    range: EditorIntelligence.TextRange(
                        start: TextPosition(line: region.startRow, column: 0, utf16Offset: startOffset),
                        end: TextPosition(line: region.endRow, column: 0, utf16Offset: endOffset)
                    ),
                    placeholder: region.placeholder
                )
            )
        }
        return descriptors.sorted { $0.range.start.utf16Offset < $1.range.start.utf16Offset }
    }
}
