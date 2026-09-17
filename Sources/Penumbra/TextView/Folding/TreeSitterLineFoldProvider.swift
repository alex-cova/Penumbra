import Foundation

/// Fold provider that derives regions from tree-sitter syntax nodes.
final class TreeSitterLineFoldProvider: LineFoldProvider {
    weak var languageMode: TreeSitterInternalLanguageMode?

    private var cachedLineCount = -1
    private var eventsByLine: [[LineFoldEvent]] = []
    private var regions: [(Int, Int)] = []
    private var needsFullRebuild = true
    private var dirtyRows: ClosedRange<Int>?

    func invalidate() {
        cachedLineCount = -1
        eventsByLine = []
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

    func foldEvents(
        atLine lineIndex: Int,
        previousDepth: Int,
        in lineManager: LineManager,
        stringView: StringView
    ) -> [LineFoldEvent] {
        rebuildIfNeeded(lineCount: lineManager.lineCount)
        guard lineIndex < eventsByLine.count else {
            return []
        }
        return eventsByLine[lineIndex]
    }
}

private extension TreeSitterLineFoldProvider {
    private static func merge(_ lhs: ClosedRange<Int>, _ rhs: ClosedRange<Int>) -> ClosedRange<Int> {
        min(lhs.lowerBound, rhs.lowerBound) ... max(lhs.upperBound, rhs.upperBound)
    }

    private func rebuildIfNeeded(lineCount: Int) {
        if needsFullRebuild {
            fullRebuild(lineCount: lineCount)
            return
        }
        if let dirtyRows {
            incrementalRebuild(lineCount: lineCount, dirtyRows: dirtyRows)
            self.dirtyRows = nil
            return
        }
        if eventsByLine.count != lineCount {
            fullRebuild(lineCount: lineCount)
        }
    }

    private func fullRebuild(lineCount: Int) {
        cachedLineCount = lineCount
        regions = []
        needsFullRebuild = false
        dirtyRows = nil
        guard let languageMode, let rootNode = languageMode.rootSyntaxNode, lineCount > 0 else {
            eventsByLine = Array(repeating: [], count: max(lineCount, 0))
            return
        }
        collectFoldRegions(from: rootNode, overlapping: nil, into: &regions)
        rebuildEvents(lineCount: lineCount)
    }

    private func incrementalRebuild(lineCount: Int, dirtyRows: ClosedRange<Int>) {
        guard lineCount > 0 else {
            regions = []
            eventsByLine = []
            cachedLineCount = 0
            return
        }
        let start = max(0, dirtyRows.lowerBound)
        let end = min(lineCount - 1, dirtyRows.upperBound)
        guard start <= end else {
            rebuildEvents(lineCount: lineCount)
            return
        }
        let query = start ... end
        regions.removeAll { regionOverlaps($0, query) }
        if let languageMode, let rootNode = languageMode.rootSyntaxNode {
            collectFoldRegions(from: rootNode, overlapping: query, into: &regions)
        }
        rebuildEvents(lineCount: lineCount)
    }

    private func rebuildEvents(lineCount: Int) {
        cachedLineCount = lineCount
        eventsByLine = Array(repeating: [], count: max(lineCount, 0))
        guard lineCount > 0 else {
            return
        }
        var depthAtLine = Array(repeating: 0, count: lineCount)
        for region in regions where region.1 > region.0 {
            let last = min(region.1, lineCount - 1)
            if last > region.0 {
                for line in (region.0 + 1)...last {
                    depthAtLine[line] += 1
                }
            }
        }
        var currentDepth = 0
        for line in 0..<lineCount {
            let lineDepth = depthAtLine[line]
            var events: [LineFoldEvent] = []
            if lineDepth < currentDepth {
                events.append(.endFold(depth: lineDepth))
            }
            let nextDepth = line + 1 < lineCount ? depthAtLine[line + 1] : 0
            if nextDepth > lineDepth {
                events.append(.startFold(depth: nextDepth))
            }
            eventsByLine[line] = events
            currentDepth = lineDepth
        }
    }

    private func shiftRegions(afterRow row: Int, by delta: Int) {
        guard delta != 0 else {
            return
        }
        var shifted: [(Int, Int)] = []
        shifted.reserveCapacity(regions.count)
        for (start, end) in regions {
            var newStart = start
            var newEnd = end
            if start >= row {
                newStart += delta
            }
            if end >= row {
                newEnd += delta
            }
            if newEnd > newStart, newStart >= 0 {
                shifted.append((newStart, newEnd))
            }
        }
        regions = shifted
    }

    private func regionOverlaps(_ region: (Int, Int), _ rows: ClosedRange<Int>) -> Bool {
        region.1 >= rows.lowerBound && region.0 <= rows.upperBound
    }

    private func collectFoldRegions(from node: TreeSitterNode, overlapping rows: ClosedRange<Int>?, into regions: inout [(Int, Int)]) {
        let startRow = Int(node.startPoint.row)
        let endRow = Int(node.endPoint.row)
        if let rows, endRow < rows.lowerBound || startRow > rows.upperBound {
            return
        }
        if isFoldable(node), endRow > startRow {
            regions.append((startRow, max(startRow, endRow - 1)))
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
}
