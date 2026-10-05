import Foundation

/// Which whitespace differences the diff viewer treats as changes (IntelliJ's "Ignore" menu).
enum IDEDiffWhitespacePolicy: String, CaseIterable, Identifiable, Sendable {
    /// Every space counts.
    case none
    /// Leading and trailing whitespace on a line is ignored.
    case trim
    /// All whitespace is ignored.
    case ignoreAll
    /// All whitespace is ignored, and so are lines with nothing else on them.
    case ignoreAllAndEmptyLines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Do Not Ignore"
        case .trim: "Trim Whitespaces"
        case .ignoreAll: "Ignore Whitespaces"
        case .ignoreAllAndEmptyLines: "Ignore Whitespaces and Empty Lines"
        }
    }
}

/// How much of a changed chunk is highlighted inside its lines (IntelliJ's "Highlight" menu).
enum IDEDiffHighlightMode: String, CaseIterable, Identifiable, Sendable {
    case words
    case lines
    case chars
    /// Words, and a changed block with as many lines on each side is split into one change per line.
    case split
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .words: "Highlight Words"
        case .lines: "Highlight Lines"
        case .chars: "Highlight Characters"
        case .split: "Highlight Split Changes"
        case .none: "Do Not Highlight"
        }
    }
}

/// A text split into lines the way the editor counts them: a final line break leaves an empty
/// last line, so line `i` here is line `i + 1` in a `TextView` showing the same text.
struct IDEDiffText: Sendable, Equatable {
    let string: String
    /// UTF-16 range of each line, without its line break.
    let lines: [NSRange]

    init(_ string: String) {
        self.string = string
        var ranges: [NSRange] = []
        var start = 0
        var offset = 0
        var previousWasCR = false
        for unit in string.utf16 {
            if unit == 10, previousWasCR {
                // The second half of "\r\n": the line already ended at the "\r".
                start = offset + 1
            } else if unit == 10 || unit == 13 {
                ranges.append(NSRange(location: start, length: offset - start))
                start = offset + 1
            }
            previousWasCR = unit == 13
            offset += 1
        }
        ranges.append(NSRange(location: start, length: offset - start))
        lines = ranges
    }

    var lineCount: Int { lines.count }
    var utf16Length: Int { (string as NSString).length }

    func line(_ index: Int) -> String {
        (string as NSString).substring(with: lines[index])
    }

    /// From the start of `range.lowerBound` to the start of `range.upperBound` (or the end of the
    /// text): the lines with their line breaks, as an edit replacing them needs.
    func range(ofLines range: Range<Int>) -> NSRange {
        let start = range.lowerBound < lines.count ? lines[range.lowerBound].location : utf16Length
        let end = range.upperBound < lines.count ? lines[range.upperBound].location : utf16Length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// From the start of the first line to the end of the last one's text, without its line break.
    func contentRange(ofLines range: Range<Int>) -> NSRange {
        guard !range.isEmpty else { return NSRange(location: self.range(ofLines: range).location, length: 0) }
        let start = lines[range.lowerBound].location
        return NSRange(location: start, length: NSMaxRange(lines[range.upperBound - 1]) - start)
    }

    /// The line holding UTF-16 offset `location` (the last line for the end of the text).
    func lineIndex(containing location: Int) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].location <= location {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}

/// One change between the two sides: line ranges (0-based, as ``IDEDiffText`` counts them) and
/// the changed parts inside those lines, as UTF-16 ranges into each side's whole text.
struct IDEDiffChunk: Equatable, Sendable {
    enum Kind: Sendable {
        case inserted
        case deleted
        case modified
    }

    var left: Range<Int>
    var right: Range<Int>
    var leftFragments: [NSRange] = []
    var rightFragments: [NSRange] = []

    var kind: Kind {
        if left.isEmpty { return .inserted }
        if right.isEmpty { return .deleted }
        return .modified
    }
}

/// Line diff of two texts, then the changed words or characters inside each changed block.
/// Pure and synchronous: callers run it off the main actor.
enum IDEDiffComputer {
    /// Above this many UTF-16 units on a side, a block is shown changed as a whole.
    static let maximumInlineLength = 20_000

    static func chunks(
        left: IDEDiffText,
        right: IDEDiffText,
        whitespace: IDEDiffWhitespacePolicy,
        highlight: IDEDiffHighlightMode
    ) -> [IDEDiffChunk] {
        let leftKeys = keys(of: left, whitespace: whitespace)
        let rightKeys = keys(of: right, whitespace: whitespace)
        let skipsEmpty = whitespace == .ignoreAllAndEmptyLines
        let leftIndices = leftKeys.indices.filter { !skipsEmpty || !leftKeys[$0].isEmpty }
        let rightIndices = rightKeys.indices.filter { !skipsEmpty || !rightKeys[$0].isEmpty }
        let pairs = matchedPairs(leftIndices.map { leftKeys[$0] }, rightIndices.map { rightKeys[$0] })
            .map { (leftIndices[$0.0], rightIndices[$0.1]) }

        var result: [IDEDiffChunk] = []
        var previous = (-1, -1)
        for anchor in pairs + [(left.lineCount, right.lineCount)] {
            var leftRange = (previous.0 + 1) ..< anchor.0
            var rightRange = (previous.1 + 1) ..< anchor.1
            previous = anchor
            if skipsEmpty {
                leftRange = trimmed(leftRange) { leftKeys[$0].isEmpty }
                rightRange = trimmed(rightRange) { rightKeys[$0].isEmpty }
            }
            guard !leftRange.isEmpty || !rightRange.isEmpty else { continue }
            result.append(IDEDiffChunk(left: leftRange, right: rightRange))
        }
        return result.flatMap { refine($0, left: left, right: right, leftKeys: leftKeys, rightKeys: rightKeys, whitespace: whitespace, highlight: highlight) }
    }

    /// Line chunks only, with no word-level refine. When the uncommon middle is longer than
    /// `maximumMiddle` lines on either side, Myers is skipped and that middle is one chunk, so a
    /// file that differs throughout stays bounded.
    static func lineChunks(left: IDEDiffText, right: IDEDiffText, maximumMiddle: Int) -> [IDEDiffChunk] {
        let leftKeys = (0 ..< left.lineCount).map { left.line($0) }
        let rightKeys = (0 ..< right.lineCount).map { right.line($0) }
        var head = 0
        while head < leftKeys.count, head < rightKeys.count, leftKeys[head] == rightKeys[head] {
            head += 1
        }
        var tail = 0
        while tail < leftKeys.count - head, tail < rightKeys.count - head,
              leftKeys[leftKeys.count - 1 - tail] == rightKeys[rightKeys.count - 1 - tail] {
            tail += 1
        }
        let leftMiddle = leftKeys.count - head - tail
        let rightMiddle = rightKeys.count - head - tail
        if leftMiddle > maximumMiddle || rightMiddle > maximumMiddle {
            let leftRange = head ..< (leftKeys.count - tail)
            let rightRange = head ..< (rightKeys.count - tail)
            guard !leftRange.isEmpty || !rightRange.isEmpty else { return [] }
            return [IDEDiffChunk(left: leftRange, right: rightRange)]
        }
        let pairs = matchedPairs(leftKeys, rightKeys)
        var result: [IDEDiffChunk] = []
        var previous = (-1, -1)
        for anchor in pairs + [(left.lineCount, right.lineCount)] {
            let leftRange = (previous.0 + 1) ..< anchor.0
            let rightRange = (previous.1 + 1) ..< anchor.1
            previous = anchor
            guard !leftRange.isEmpty || !rightRange.isEmpty else { continue }
            result.append(IDEDiffChunk(left: leftRange, right: rightRange))
        }
        return result
    }

    // MARK: - Lines

    private static func keys(of text: IDEDiffText, whitespace: IDEDiffWhitespacePolicy) -> [String] {
        (0 ..< text.lineCount).map { index in
            let line = text.line(index)
            switch whitespace {
            case .none:
                return line
            case .trim:
                return line.trimmingCharacters(in: .whitespaces)
            case .ignoreAll, .ignoreAllAndEmptyLines:
                return String(line.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) })
            }
        }
    }

    /// Index pairs of a longest common subsequence: the common head and tail first, then Myers
    /// (`CollectionDifference`) on what is left.
    static func matchedPairs<T: Hashable>(_ left: [T], _ right: [T]) -> [(Int, Int)] {
        var head = 0
        while head < left.count, head < right.count, left[head] == right[head] {
            head += 1
        }
        var tail = 0
        while tail < left.count - head, tail < right.count - head,
              left[left.count - 1 - tail] == right[right.count - 1 - tail] {
            tail += 1
        }
        var pairs = (0 ..< head).map { ($0, $0) }
        let leftMiddle = Array(left[head ..< left.count - tail])
        let rightMiddle = Array(right[head ..< right.count - tail])
        if !leftMiddle.isEmpty, !rightMiddle.isEmpty {
            let difference = rightMiddle.difference(from: leftMiddle)
            var removed = Set<Int>()
            var inserted = Set<Int>()
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            var i = 0
            var j = 0
            while i < leftMiddle.count, j < rightMiddle.count {
                if removed.contains(i) {
                    i += 1
                } else if inserted.contains(j) {
                    j += 1
                } else {
                    pairs.append((head + i, head + j))
                    i += 1
                    j += 1
                }
            }
        }
        pairs += (0 ..< tail).map { (left.count - tail + $0, right.count - tail + $0) }
        return pairs
    }

    private static func trimmed(_ range: Range<Int>, isBlank: (Int) -> Bool) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, isBlank(lower) { lower += 1 }
        while upper > lower, isBlank(upper - 1) { upper -= 1 }
        return lower ..< upper
    }

    // MARK: - Inside a block

    private static func refine(
        _ chunk: IDEDiffChunk,
        left: IDEDiffText,
        right: IDEDiffText,
        leftKeys: [String],
        rightKeys: [String],
        whitespace: IDEDiffWhitespacePolicy,
        highlight: IDEDiffHighlightMode
    ) -> [IDEDiffChunk] {
        guard chunk.kind == .modified else { return [chunk] }
        switch highlight {
        case .lines, .none:
            return [chunk]
        case .words, .chars:
            return [withFragments(chunk, left: left, right: right, whitespace: whitespace, chars: highlight == .chars)]
        case .split:
            guard chunk.left.count == chunk.right.count, chunk.left.count > 1 else {
                return [withFragments(chunk, left: left, right: right, whitespace: whitespace, chars: false)]
            }
            return zip(chunk.left, chunk.right).compactMap { leftLine, rightLine in
                guard leftKeys[leftLine] != rightKeys[rightLine] else { return nil }
                let line = IDEDiffChunk(left: leftLine ..< leftLine + 1, right: rightLine ..< rightLine + 1)
                return withFragments(line, left: left, right: right, whitespace: whitespace, chars: false)
            }
        }
    }

    private static func withFragments(
        _ chunk: IDEDiffChunk,
        left: IDEDiffText,
        right: IDEDiffText,
        whitespace: IDEDiffWhitespacePolicy,
        chars: Bool
    ) -> IDEDiffChunk {
        let leftRange = left.contentRange(ofLines: chunk.left)
        let rightRange = right.contentRange(ofLines: chunk.right)
        guard leftRange.length <= maximumInlineLength, rightRange.length <= maximumInlineLength else {
            return chunk
        }
        let ignoresWhitespace = whitespace != .none
        let leftTokens = tokens(in: left.string, range: leftRange, chars: chars).filter { !ignoresWhitespace || !$0.isWhitespace }
        let rightTokens = tokens(in: right.string, range: rightRange, chars: chars).filter { !ignoresWhitespace || !$0.isWhitespace }
        let pairs = matchedPairs(leftTokens.map(\.key), rightTokens.map(\.key))
        // Nothing in common but spaces: the whole block is the change, as the band already shows.
        guard pairs.contains(where: { !leftTokens[$0.0].isWhitespace }) else { return chunk }
        let leftMatched = Set(pairs.map(\.0))
        let rightMatched = Set(pairs.map(\.1))
        var refined = chunk
        refined.leftFragments = merged(
            leftTokens.indices.filter { !leftMatched.contains($0) }.map { leftTokens[$0].range },
            in: left.string
        )
        refined.rightFragments = merged(
            rightTokens.indices.filter { !rightMatched.contains($0) }.map { rightTokens[$0].range },
            in: right.string
        )
        return refined
    }

    struct Token: Equatable {
        var range: NSRange
        var key: String
        var isWhitespace: Bool
    }

    /// Words (letters, digits and `_`), runs of spaces, line breaks and single other characters;
    /// with `chars`, every character on its own.
    static func tokens(in string: String, range: NSRange, chars: Bool) -> [Token] {
        let substring = (string as NSString).substring(with: range)
        var tokens: [Token] = []
        var offset = range.location
        enum Class { case word, space, newline, other }
        var current: (start: Int, length: Int, kind: Class, text: String.UnicodeScalarView)?

        func flush() {
            guard let run = current else { return }
            let text = String(run.text)
            let key = run.kind == .newline ? "\n" : text
            tokens.append(Token(range: NSRange(location: run.start, length: run.length), key: key,
                                isWhitespace: run.kind == .space || run.kind == .newline))
            current = nil
        }

        for scalar in substring.unicodeScalars {
            let kind: Class
            if scalar == "\n" || scalar == "\r" {
                kind = .newline
            } else if CharacterSet.whitespaces.contains(scalar) {
                kind = .space
            } else if scalar == "_" || CharacterSet.alphanumerics.contains(scalar) {
                kind = .word
            } else {
                kind = .other
            }
            let length = scalar.utf16.count
            let joinsRun = !chars && (kind == .word || kind == .space) && current?.kind == kind
            let joinsCRLF = scalar == "\n" && current?.kind == .newline && current?.length == 1 && current?.text.last == "\r"
            let joins = joinsRun || joinsCRLF
            if joins, var run = current {
                run.length += length
                run.text.append(scalar)
                current = run
            } else {
                flush()
                current = (offset, length, kind, String.UnicodeScalarView([scalar]))
            }
            offset += length
        }
        flush()
        return tokens
    }

    /// Sorted, with neighbours joined when only spaces or tabs separate them on one line.
    private static func merged(_ ranges: [NSRange], in string: String) -> [NSRange] {
        let text = string as NSString
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            guard var last = result.last else {
                result.append(range)
                continue
            }
            let gap = NSRange(location: NSMaxRange(last), length: max(0, range.location - NSMaxRange(last)))
            let onlySpaces = gap.length == 0 || text.substring(with: gap).allSatisfy { $0 == " " || $0 == "\t" }
            if onlySpaces {
                last.length = NSMaxRange(range) - last.location
                result[result.count - 1] = last
            } else {
                result.append(range)
            }
        }
        // Spaces at either end are not part of the change, and a line break alone is not worth a highlight.
        return result.compactMap { range in
            var lower = range.location
            var upper = NSMaxRange(range)
            while lower < upper, isSpaceOrTab(text.character(at: lower)) { lower += 1 }
            while upper > lower, isSpaceOrTab(text.character(at: upper - 1)) { upper -= 1 }
            let trimmed = NSRange(location: lower, length: upper - lower)
            guard trimmed.length > 0, !text.substring(with: trimmed).allSatisfy(\.isNewline) else { return nil }
            return trimmed
        }
    }

    private static func isSpaceOrTab(_ unit: unichar) -> Bool {
        unit == 32 || unit == 9
    }
}
