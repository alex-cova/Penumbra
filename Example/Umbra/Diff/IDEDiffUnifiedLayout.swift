import Foundation

/// One text for the unified viewer: unchanged lines once (as the right side has them), and for
/// each change its left lines followed by its right lines.
struct IDEDiffUnifiedLayout: Equatable, Sendable {
    enum LineKind: Equatable, Sendable {
        case unchanged
        case deleted
        case inserted
    }

    /// Where one chunk ended up, in 0-based rows of ``text``.
    struct ChunkRows: Equatable, Sendable {
        var deleted: Range<Int>
        var inserted: Range<Int>

        var all: Range<Int> { deleted.lowerBound ..< inserted.upperBound }
    }

    let text: String
    let kinds: [LineKind]
    /// 1-based line on the left side, nil for an inserted line.
    let oldNumbers: [Int?]
    /// 1-based line on the right side, nil for a deleted line.
    let newNumbers: [Int?]
    let chunkRows: [ChunkRows]
    /// Changed words, as UTF-16 ranges into ``text``.
    let deletedFragments: [NSRange]
    let insertedFragments: [NSRange]

    init(left: IDEDiffText, right: IDEDiffText, chunks: [IDEDiffChunk]) {
        var lines: [String] = []
        var kinds: [LineKind] = []
        var oldNumbers: [Int?] = []
        var newNumbers: [Int?] = []
        var chunkRows: [ChunkRows] = []
        /// Unified row of each left / right line copied into a chunk, to place its fragments.
        var leftRows: [Int: Int] = [:]
        var rightRows: [Int: Int] = [:]
        var leftLine = 0
        var rightLine = 0

        func copyUnchanged(until rightEnd: Int) {
            while rightLine < rightEnd {
                lines.append(right.line(rightLine))
                kinds.append(.unchanged)
                oldNumbers.append(leftLine < left.lineCount ? leftLine + 1 : nil)
                newNumbers.append(rightLine + 1)
                leftLine += 1
                rightLine += 1
            }
        }

        for chunk in chunks {
            copyUnchanged(until: chunk.right.lowerBound)
            leftLine = chunk.left.lowerBound
            let deletedStart = lines.count
            for index in chunk.left {
                leftRows[index] = lines.count
                lines.append(left.line(index))
                kinds.append(.deleted)
                oldNumbers.append(index + 1)
                newNumbers.append(nil)
            }
            let insertedStart = lines.count
            for index in chunk.right {
                rightRows[index] = lines.count
                lines.append(right.line(index))
                kinds.append(.inserted)
                oldNumbers.append(nil)
                newNumbers.append(index + 1)
            }
            chunkRows.append(ChunkRows(deleted: deletedStart ..< insertedStart, inserted: insertedStart ..< lines.count))
            leftLine = chunk.left.upperBound
            rightLine = chunk.right.upperBound
        }
        copyUnchanged(until: right.lineCount)

        var lineStarts: [Int] = []
        lineStarts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            lineStarts.append(offset)
            offset += (line as NSString).length + 1
        }
        text = lines.joined(separator: "\n")
        self.kinds = kinds
        self.oldNumbers = oldNumbers
        self.newNumbers = newNumbers
        self.chunkRows = chunkRows
        deletedFragments = Self.place(chunks.flatMap(\.leftFragments), from: left, rows: leftRows, lineStarts: lineStarts)
        insertedFragments = Self.place(chunks.flatMap(\.rightFragments), from: right, rows: rightRows, lineStarts: lineStarts)
    }

    /// Moves fragments from one side's text into the unified text, split at line breaks since the
    /// two texts' line breaks may differ ("\r\n" there, "\n" here).
    private static func place(_ fragments: [NSRange], from side: IDEDiffText, rows: [Int: Int], lineStarts: [Int]) -> [NSRange] {
        var placed: [NSRange] = []
        for fragment in fragments {
            var line = side.lineIndex(containing: fragment.location)
            while line < side.lineCount {
                let content = side.lines[line]
                let start = max(fragment.location, content.location)
                let end = min(NSMaxRange(fragment), NSMaxRange(content))
                if end > start, let row = rows[line] {
                    placed.append(NSRange(location: lineStarts[row] + start - content.location, length: end - start))
                }
                guard NSMaxRange(fragment) > NSMaxRange(content) else { break }
                line += 1
            }
        }
        return placed
    }
}
