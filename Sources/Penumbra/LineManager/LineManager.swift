import CoreGraphics
import Foundation

struct LineMetric: Equatable {
    var totalLength: Int
    var delimiterLength: Int
}

/// Stable identity for a line within a document's lifetime.
///
/// This is a plain `UInt32` counter minted by ``PackedLineIndex`` (it used to be a `UUID`). The
/// counter is monotonic for the life of a `PackedLineIndex` and is **not** reset by
/// `LineManager.rebuild()`, so an id issued before a rebuild can never collide with one issued
/// after. Code that caches per-line data keyed by this id across a wholesale line rebuild
/// (`TextView.text =`, `setState`) must still drop those caches explicitly — see the `string`
/// setter in `TextInputView` and `ContentSizeService.reset()`.
struct DocumentLineNodeID: Hashable {
    let value: UInt32
    var rawValue: String {
        String(value)
    }
}

extension DocumentLineNodeID: CustomDebugStringConvertible {
    var debugDescription: String {
        rawValue
    }
}

/// Per-line handle into ``PackedLineIndex``. Identity is a stable ``DocumentLineNodeID``; `row` is
/// refreshed when lines are inserted or removed above it.
final class DocumentLineNode: Hashable {
    let id: DocumentLineNodeID
    var row: Int
    unowned let lineManager: LineManager
    let data: DocumentLineNodeData

    var location: Int {
        lineManager.location(ofRow: row)
    }

    var index: Int {
        row
    }

    var yPosition: CGFloat {
        lineManager.yPosition(ofRow: row)
    }

    var value: Int {
        data.totalLength
    }

    var next: DocumentLineNode {
        lineManager.line(atRow: min(row + 1, lineManager.lineCount - 1))
    }

    var previous: DocumentLineNode {
        lineManager.line(atRow: max(row - 1, 0))
    }

    var range: ClosedRange<Int> {
        let start = location
        return start ... start + data.totalLength
    }

    init(id: DocumentLineNodeID, row: Int, lineManager: LineManager, data: DocumentLineNodeData) {
        self.id = id
        self.row = row
        self.lineManager = lineManager
        self.data = data
        data.node = self
    }

    static func == (lhs: DocumentLineNode, rhs: DocumentLineNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

final class LineIterator: IteratorProtocol {
    private let lineManager: LineManager
    private var row = 0

    init(lineManager: LineManager) {
        self.lineManager = lineManager
    }

    func next() -> DocumentLineNode? {
        guard row < lineManager.lineCount else {
            return nil
        }
        defer { row += 1 }
        return lineManager.line(atRow: row)
    }
}

final class LineManager {
    var stringView: StringView
    var lineCount: Int {
        packed.lineCount
    }
    var contentHeight: CGFloat {
        packed.contentHeight
    }
    var estimatedLineHeight: CGFloat = 12 {
        didSet {
            packed.estimatedLineHeight = estimatedLineHeight
        }
    }
    var firstLine: DocumentLineNode {
        line(atRow: 0)
    }
    var lastLine: DocumentLineNode {
        line(atRow: lineCount - 1)
    }
    private(set) weak var initialLongestLine: DocumentLineNode?

    private let packed: PackedLineIndex
    private var handles: [UInt32: DocumentLineNode] = [:]

    init(stringView: StringView, packedIndex: PackedLineIndex? = nil) {
        self.stringView = stringView
        packed = packedIndex ?? PackedLineIndex(estimatedLineHeight: 12)
        if packedIndex != nil, packed.lineCount > 0 {
            initialLongestLine = line(atRow: packed.longestRow)
        }
    }

    func rebuild() {
        PenumbraSignposts.interval("LineManager.rebuild") {
            // Piece-tree storage can report line metrics straight from its UTF-8 bytes. The
            // `rangeOfNextNewLine` walk below reads one UTF-16 unit at a time, which on a piece
            // tree costs an array allocation plus a byte walk from the nearest checkpoint for
            // *every* unit in the document.
            if let metrics = stringView.lineMetrics() {
                rebuild(fromLineMetrics: metrics)
                return
            }
            var metrics: [LineMetric] = []
            var lastDelimiterEnd = 0
            var workingNewLineRange = stringView.rangeOfNextNewLine(startingAt: 0)
            while let newLineRange = workingNewLineRange {
                let totalLength = newLineRange.location + newLineRange.length - lastDelimiterEnd
                metrics.append(LineMetric(totalLength: totalLength, delimiterLength: newLineRange.length))
                lastDelimiterEnd = newLineRange.location + newLineRange.length
                workingNewLineRange = stringView.rangeOfNextNewLine(startingAt: lastDelimiterEnd)
            }
            metrics.append(LineMetric(totalLength: stringView.length - lastDelimiterEnd, delimiterLength: 0))
            rebuild(fromLineMetrics: metrics)
        }
    }

    /// Rebuilds the line tree from precomputed per-line UTF-16 lengths, skipping a second newline scan.
    func rebuild(fromLineMetrics metrics: [LineMetric]) {
        handles.removeAll(keepingCapacity: false)
        packed.rebuild(from: metrics, estimatedLineHeight: estimatedLineHeight)
        if packed.lineCount > 0 {
            initialLongestLine = line(atRow: packed.longestRow)
        } else {
            initialLongestLine = nil
        }
    }

    @discardableResult
    func removeCharacters(in range: NSRange) -> LineChangeSet {
        guard range.length > 0 else {
            return LineChangeSet()
        }
        guard let startRow = packed.row(containingUTF16: range.location) else {
            return LineChangeSet()
        }
        let startLine = line(atRow: startRow)
        let startLocation = startLine.location
        if range.location > startLocation + startLine.data.length {
            let changeSet = LineChangeSet()
            let otherChangeSetA = setLength(of: startLine, to: startLine.value - 1)
            changeSet.union(with: otherChangeSetA)
            let otherChangeSetB = removeCharacters(in: NSRange(location: range.location, length: range.length - 1))
            changeSet.union(with: otherChangeSetB)
            return changeSet
        } else if range.location + range.length < startLocation + startLine.value {
            return setLength(of: startLine, to: startLine.value - range.length)
        } else {
            let charactersRemovedInStartLine = startLocation + startLine.value - range.location
            assert(charactersRemovedInStartLine > 0)
            guard let endRow = packed.row(containingUTF16: range.location + range.length) else {
                return LineChangeSet()
            }
            let endLine = line(atRow: endRow)
            if endLine.id == startLine.id {
                return setLength(of: startLine, to: startLine.value - range.length)
            } else {
                let changeSet = LineChangeSet()
                let charactersLeftInEndLine = endLine.location + endLine.value - (range.location + range.length)
                return finishRemoveAcrossLines(
                    startLine: startLine,
                    startRow: startRow,
                    endRow: endRow,
                    charactersRemovedInStartLine: charactersRemovedInStartLine,
                    charactersLeftInEndLine: charactersLeftInEndLine,
                    changeSet: changeSet
                )
            }
        }
    }

    @discardableResult
    func insert(_ string: NSString, at location: Int) -> LineChangeSet {
        let changeSet = LineChangeSet()
        guard packed.row(containingUTF16: location) != nil else {
            return LineChangeSet()
        }
        var line = self.line(containingCharacterAt: location)!
        var lineLocation = line.location
        assert(location <= lineLocation + line.value)
        if location > lineLocation + line.data.length {
            let otherChangeSetA = setLength(of: line, to: line.value - 1)
            changeSet.union(with: otherChangeSetA)
            line = insertLine(ofLength: 1, after: line)
            changeSet.markLineInserted(line)
            let otherChangeSetB = setLength(of: line, to: 1, newLine: &line)
            changeSet.union(with: otherChangeSetB)
        }
        if let rangeOfFirstNewLine = NewLineFinder.rangeOfNextNewLine(in: string, startingAt: 0) {
            var lastDelimiterEnd = 0
            var rangeOfNewLine = rangeOfFirstNewLine
            var hasReachedEnd = false
            while !hasReachedEnd {
                let lineBreakLocation = location + rangeOfNewLine.location + rangeOfNewLine.length
                lineLocation = line.location
                let lengthAfterInsertionPos = lineLocation + line.value - (location + lastDelimiterEnd)
                let otherChangeSetA = setLength(of: line, to: lineBreakLocation - lineLocation, newLine: &line)
                changeSet.union(with: otherChangeSetA)
                var newLine = insertLine(ofLength: lengthAfterInsertionPos, after: line)
                changeSet.markLineInserted(newLine)
                let otherChangeSetB = setLength(of: newLine, to: lengthAfterInsertionPos, newLine: &newLine)
                changeSet.union(with: otherChangeSetB)
                line = newLine
                lastDelimiterEnd = rangeOfNewLine.location + rangeOfNewLine.length
                if let rangeOfNextNewLine = NewLineFinder.rangeOfNextNewLine(in: string, startingAt: lastDelimiterEnd) {
                    rangeOfNewLine = rangeOfNextNewLine
                } else {
                    hasReachedEnd = true
                }
            }
            if lastDelimiterEnd != string.length {
                let otherChangeSet = setLength(of: line, to: line.value + string.length - lastDelimiterEnd)
                changeSet.union(with: otherChangeSet)
            }
        } else {
            let otherChangeSet = setLength(of: line, to: line.value + string.length)
            changeSet.union(with: otherChangeSet)
        }
        return changeSet
    }

    func linePosition(at location: Int) -> LinePosition? {
        if let line = line(containingCharacterAt: location) {
            let column = location - line.location
            return LinePosition(row: line.index, column: column)
        } else {
            return nil
        }
    }

    func line(containingCharacterAt location: Int) -> DocumentLineNode? {
        guard let row = packed.row(containingUTF16: location) else {
            return nil
        }
        return line(atRow: row)
    }

    func line(containingYOffset yOffset: CGFloat) -> DocumentLineNode? {
        guard let row = packed.row(containingYOffset: yOffset) else {
            return nil
        }
        return line(atRow: row)
    }

    func line(containingByteAt byteIndex: ByteCount) -> DocumentLineNode? {
        guard let row = packed.row(containingByte: byteIndex) else {
            return nil
        }
        return line(atRow: row)
    }

    func line(atRow row: Int) -> DocumentLineNode {
        let (packedLine, location) = packed.lineAndLocation(atRow: row)
        if let existing = handles[packedLine.id] {
            existing.row = row
            refreshData(existing, line: packedLine, location: location)
            return existing
        }
        let data = packed.dataSnapshot(atRow: row, location: location, estimatedFallbackHeight: estimatedLineHeight)
        let node = DocumentLineNode(
            id: DocumentLineNodeID(value: packedLine.id),
            row: row,
            lineManager: self,
            data: data
        )
        handles[packedLine.id] = node
        return node
    }

    func location(ofRow row: Int) -> Int {
        packed.location(ofRow: row)
    }

    func yPosition(ofRow row: Int) -> CGFloat {
        packed.yPosition(ofRow: row)
    }

    @discardableResult
    func setHeight(of line: DocumentLineNode, to newHeight: CGFloat) -> Bool {
        if abs(newHeight - line.data.lineHeight) < CGFloat.ulpOfOne {
            return false
        }
        line.data.lineHeight = newHeight
        return packed.setHeight(row: line.row, to: newHeight)
    }

    func lines(in range: NSRange) -> [DocumentLineNode] {
        guard let firstLine = line(containingCharacterAt: range.location) else {
            return []
        }
        var lines: [DocumentLineNode] = [firstLine]
        if range.length > 0, let lastLine = line(containingCharacterAt: range.location + range.length - 1), lastLine !== firstLine {
            let startLineIndex = firstLine.index + 1
            let endLineIndex = lastLine.index - 1
            if startLineIndex <= endLineIndex {
                lines += (startLineIndex ... endLineIndex).map(line(atRow:))
            }
            lines.append(lastLine)
        }
        return lines
    }

    func startAndEndLine(in range: NSRange) -> (startLine: DocumentLineNode, endLine: DocumentLineNode)? {
        if range.length == 0 {
            if let line = line(containingCharacterAt: range.lowerBound) {
                return (line, line)
            }
            return nil
        } else if let startLine = line(containingCharacterAt: range.lowerBound),
                  let endLine = line(containingCharacterAt: range.upperBound - 1) {
            return (startLine, endLine)
        }
        return nil
    }

    func createLineIterator() -> LineIterator {
        LineIterator(lineManager: self)
    }
}

private extension LineManager {
    private func finishRemoveAcrossLines(
        startLine: DocumentLineNode,
        startRow: Int,
        endRow: Int,
        charactersRemovedInStartLine: Int,
        charactersLeftInEndLine: Int,
        changeSet: LineChangeSet
    ) -> LineChangeSet {
        let linesToRemove = endRow - startRow
        for _ in 0..<linesToRemove {
            let row = startRow + 1
            let removed = line(atRow: row)
            changeSet.markLineRemoved(removed)
            _ = packed.removeLine(atRow: row)
            shiftHandlesAfterRemoval(atRow: row, removedID: removed.id.value)
        }
        let newLength = startLine.value - charactersRemovedInStartLine + charactersLeftInEndLine
        let otherChangeSet = setLength(of: startLine, to: newLength)
        changeSet.union(with: otherChangeSet)
        return changeSet
    }

    private func setLength(of line: DocumentLineNode, to newTotalLength: Int) -> LineChangeSet {
        var newLine: DocumentLineNode = line
        return setLength(of: line, to: newTotalLength, newLine: &newLine)
    }

    private func setLength(of line: DocumentLineNode, to newTotalLength: Int, newLine: inout DocumentLineNode) -> LineChangeSet {
        let changeSet = LineChangeSet()
        changeSet.markLineEdited(line)
        let newByteCount = ByteCount(newTotalLength * 2)
        if newTotalLength != line.value || newTotalLength != line.data.totalLength || newByteCount != line.data.byteCount {
            line.data.totalLength = newTotalLength
            line.data.byteCount = newByteCount
            packed.setLength(row: line.row, utf16Length: newTotalLength, delimiterLength: line.data.delimiterLength)
        }
        if newTotalLength == 0 {
            line.data.delimiterLength = 0
            packed.setLength(row: line.row, utf16Length: 0, delimiterLength: 0)
        } else {
            let lastChar = getCharacter(at: Int(line.location) + newTotalLength - 1)
            if lastChar == Symbol.Character.carriageReturn {
                line.data.delimiterLength = 1
                packed.setLength(row: line.row, utf16Length: newTotalLength, delimiterLength: 1)
            } else if lastChar == Symbol.Character.lineFeed {
                if newTotalLength >= 2 && getCharacter(at: Int(line.location) + newTotalLength - 2) == Symbol.Character.carriageReturn {
                    line.data.delimiterLength = 2
                    packed.setLength(row: line.row, utf16Length: newTotalLength, delimiterLength: 2)
                } else if newTotalLength == 1 && line.location > 0 && getCharacter(at: Int(line.location) - 1) == Symbol.Character.carriageReturn {
                    let previousLine = line.previous
                    changeSet.markLineRemoved(line)
                    _ = packed.removeLine(atRow: line.row)
                    shiftHandlesAfterRemoval(atRow: line.row, removedID: line.id.value)
                    let otherChangeSet = setLength(of: previousLine, to: previousLine.value + 1, newLine: &newLine)
                    changeSet.union(with: otherChangeSet)
                } else {
                    line.data.delimiterLength = 1
                    packed.setLength(row: line.row, utf16Length: newTotalLength, delimiterLength: 1)
                }
            } else {
                line.data.delimiterLength = 0
                packed.setLength(row: line.row, utf16Length: newTotalLength, delimiterLength: 0)
            }
        }
        newLine = line
        return changeSet
    }

    @discardableResult
    private func insertLine(ofLength length: Int, after otherLine: DocumentLineNode) -> DocumentLineNode {
        let id = packed.insertLine(afterRow: otherLine.row, utf16Length: length, delimiterLength: 0)
        shiftHandlesAfterInsert(atRow: otherLine.row + 1)
        let inserted = line(atRow: otherLine.row + 1)
        inserted.data.totalLength = length
        inserted.data.byteCount = ByteCount(length * 2)
        _ = id
        return inserted
    }

    private func getCharacter(at location: Int) -> Character? {
        stringView.character(at: location)
    }

    private func refreshData(_ node: DocumentLineNode, line packedLine: PackedLine, location: Int) {
        node.data.totalLength = Int(packedLine.utf16Length)
        node.data.delimiterLength = Int(packedLine.delimiterLength)
        node.data.lineHeight = CGFloat(packedLine.height)
        node.data.byteCount = ByteCount(utf16Length: Int(packedLine.utf16Length))
        node.data.cachedStartByte = ByteCount(utf16Length: location)
    }

    private func shiftHandlesAfterInsert(atRow row: Int) {
        for handle in handles.values where handle.row >= row {
            handle.row += 1
        }
    }

    private func shiftHandlesAfterRemoval(atRow row: Int, removedID: UInt32) {
        handles.removeValue(forKey: removedID)
        for handle in handles.values where handle.row > row {
            handle.row -= 1
        }
    }
}
