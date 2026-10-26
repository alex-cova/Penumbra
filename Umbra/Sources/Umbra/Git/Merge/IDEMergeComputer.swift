import Foundation

/// One region of a three-way merge: the base lines and what each side has in their place. Ranges are
/// 0-based line ranges as `IDEDiffText` counts them.
struct IDEMergeChunk: Equatable, Sendable {
    enum Kind: Sendable {
        /// Neither side changed it.
        case unchanged
        /// Only the left side ("ours") changed it.
        case leftOnly
        /// Only the right side ("theirs") changed it.
        case rightOnly
        /// Both made the same change.
        case bothSame
        /// Both changed it, differently: someone has to choose.
        case conflict
    }

    var kind: Kind
    var base: Range<Int>
    var left: Range<Int>
    var right: Range<Int>

    var isChange: Bool { kind != .unchanged }
}

/// Which side a conflict takes when the merged text is built.
enum IDEMergeResolution: Sendable {
    case base
    case left
    case right
    /// Left lines, then right lines.
    case both
}

/// A three-way line merge (diff3). Both sides are diffed against the base; changes that touch or
/// overlap in the base are one region, as git treats them (adjacent edits conflict). Pure and
/// synchronous: callers run it off the main actor.
enum IDEMergeComputer {
    static let defaultMaximumMiddle = 20_000

    static func chunks(
        base: IDEDiffText, left: IDEDiffText, right: IDEDiffText, maximumMiddle: Int = defaultMaximumMiddle
    ) -> [IDEMergeChunk] {
        let leftHunks = IDEDiffComputer.lineChunks(left: base, right: left, maximumMiddle: maximumMiddle)
        let rightHunks = IDEDiffComputer.lineChunks(left: base, right: right, maximumMiddle: maximumMiddle)

        var result: [IDEMergeChunk] = []
        var cursor = 0
        // Offsets from a base line to the same line on each side, before the region being built.
        var leftDelta = 0
        var rightDelta = 0
        var i = 0
        var j = 0
        while i < leftHunks.count || j < rightHunks.count {
            let leftStart = i < leftHunks.count ? leftHunks[i].left.lowerBound : Int.max
            let rightStart = j < rightHunks.count ? rightHunks[j].left.lowerBound : Int.max
            let start = min(leftStart, rightStart)
            if start > cursor {
                result.append(IDEMergeChunk(
                    kind: .unchanged,
                    base: cursor ..< start,
                    left: (cursor + leftDelta) ..< (start + leftDelta),
                    right: (cursor + rightDelta) ..< (start + rightDelta)
                ))
            }
            var end = start
            var usesLeft = false
            var usesRight = false
            var leftAfter = leftDelta
            var rightAfter = rightDelta
            while true {
                if i < leftHunks.count, leftHunks[i].left.lowerBound <= end {
                    end = max(end, leftHunks[i].left.upperBound)
                    leftAfter += leftHunks[i].right.count - leftHunks[i].left.count
                    usesLeft = true
                    i += 1
                } else if j < rightHunks.count, rightHunks[j].left.lowerBound <= end {
                    end = max(end, rightHunks[j].left.upperBound)
                    rightAfter += rightHunks[j].right.count - rightHunks[j].left.count
                    usesRight = true
                    j += 1
                } else {
                    break
                }
            }
            let leftRange = (start + leftDelta) ..< (end + leftAfter)
            let rightRange = (start + rightDelta) ..< (end + rightAfter)
            let kind: IDEMergeChunk.Kind
            switch (usesLeft, usesRight) {
            case (true, false): kind = .leftOnly
            case (false, true): kind = .rightOnly
            default:
                kind = sameLines(left, leftRange, right, rightRange) ? .bothSame : .conflict
            }
            result.append(IDEMergeChunk(kind: kind, base: start ..< end, left: leftRange, right: rightRange))
            cursor = end
            leftDelta = leftAfter
            rightDelta = rightAfter
        }
        if cursor < base.lineCount || result.isEmpty {
            result.append(IDEMergeChunk(
                kind: .unchanged,
                base: cursor ..< base.lineCount,
                left: (cursor + leftDelta) ..< (base.lineCount + leftDelta),
                right: (cursor + rightDelta) ..< (base.lineCount + rightDelta)
            ))
        }
        return result
    }

    /// The merged text: every change that is not a conflict applied, each conflict by `conflict`.
    static func merged(
        base: IDEDiffText, left: IDEDiffText, right: IDEDiffText, chunks: [IDEMergeChunk],
        conflict: IDEMergeResolution = .base
    ) -> String {
        var lines: [String] = []
        func append(_ text: IDEDiffText, _ range: Range<Int>) {
            for index in range { lines.append(text.line(index)) }
        }
        for chunk in chunks {
            switch chunk.kind {
            case .unchanged: append(base, chunk.base)
            case .leftOnly, .bothSame: append(left, chunk.left)
            case .rightOnly: append(right, chunk.right)
            case .conflict:
                switch conflict {
                case .base: append(base, chunk.base)
                case .left: append(left, chunk.left)
                case .right: append(right, chunk.right)
                case .both:
                    append(left, chunk.left)
                    append(right, chunk.right)
                }
            }
        }
        return lines.joined(separator: lineBreak(of: base, left: left, right: right))
    }

    static func conflictCount(_ chunks: [IDEMergeChunk]) -> Int {
        chunks.filter { $0.kind == .conflict }.count
    }

    /// `\r\n` when the base (else either side) uses it, so a merge does not rewrite line endings.
    static func lineBreak(of base: IDEDiffText, left: IDEDiffText, right: IDEDiffText) -> String {
        for text in [base, left, right] where text.string.contains("\r\n") { return "\r\n" }
        return "\n"
    }

    private static func sameLines(_ a: IDEDiffText, _ aRange: Range<Int>, _ b: IDEDiffText, _ bRange: Range<Int>) -> Bool {
        guard aRange.count == bRange.count else { return false }
        for offset in 0 ..< aRange.count where a.line(aRange.lowerBound + offset) != b.line(bRange.lowerBound + offset) {
            return false
        }
        return true
    }
}
