import Foundation

/// Internal form of one manual injection: the content `byteRange` (for overlap tests) plus the
/// `textRanges` the injected parser actually reads (content minus quotes and host interpolation
/// spans — never empty).
struct ManualInjectionContent {
    /// Stable-ish label for debugging; reconciliation matches by language and overlap, not by key.
    let key: String
    let languageName: String
    let byteRange: ByteRange
    let textRanges: [TreeSitterTextRange]
}

/// Discovers `language=ID` comment injections and carves string-content ranges.
///
/// All reads go through `readText`, which must serve bounded `StringView.substring(in:)` reads —
/// never `textView.text`. Comment enumeration walks the tree pruned to `window` (`nil` means the
/// whole document on a full parse), so a document with no directive pays one node-type check per
/// node in the window and no text reads at all.
final class ManualLanguageInjectionDiscovery {
    /// Host comment syntax, for stripping delimiters before looking for the directive.
    var lineCommentPrefix: String?
    var blockCommentDelimiters: BlockCommentDelimiters?

    /// Reads UTF-16 text for `range`, or `nil` when out of bounds.
    var readText: ((NSRange) -> String?)?

    /// Comment directives found under `root` inside `window`, attached to their string literals.
    /// `fullText` lazily materializes the document text and is only invoked when at least one
    /// directive comment was found (attachment needs line layout).
    func commentInjections(
        under root: TreeSitterNode,
        window: ByteRange?,
        fullText: () -> String?
    ) -> [ManualInjectionContent] {
        var result: [ManualInjectionContent] = []
        var directiveComments: [(node: TreeSitterNode, languageName: String)] = []
        collectComments(under: root, window: window) { node in
            if let languageName = self.languageNameDirective(in: node) {
                directiveComments.append((node, languageName))
            }
        }
        guard !directiveComments.isEmpty, let text = fullText() else {
            return result
        }
        let lines = LineTable(text: text)
        for (node, languageName) in directiveComments {
            guard let stringNode = attachmentTarget(forCommentEndingAt: node.endByte,
                                                    endPoint: node.endPoint,
                                                    under: root,
                                                    lines: lines) else {
                continue
            }
            let pieces = Self.contentTextRanges(of: stringNode, readText: readText)
            guard !pieces.isEmpty else {
                continue
            }
            let byteRange = ByteRange(from: pieces.map(\.startByte).min()!,
                                      to: pieces.map(\.endByte).max()!)
            result.append(ManualInjectionContent(
                key: "comment:\(node.startByte.value)",
                languageName: languageName,
                byteRange: byteRange,
                textRanges: pieces))
        }
        return result
    }

    /// Content ranges of `stringNode`: quotes (and Python-style `f`/`r` prefixes) stripped, host
    /// interpolation child subtrees (`template_substitution`, `interpolation`, …) excluded.
    /// Empty when nothing parseable remains (a string holding only an interpolation).
    static func contentTextRanges(
        of stringNode: TreeSitterNode,
        readText: ((NSRange) -> String?)?
    ) -> [TreeSitterTextRange] {
        let nodeByteRange = stringNode.byteRange
        guard let text = readText?(NSRange(nodeByteRange)), !text.isEmpty else {
            return [stringNode.textRange]
        }
        let units = Array(text.utf16)
        guard let inner = innerContentUTF16Range(of: units) else {
            return [stringNode.textRange]
        }
        let baseByte = nodeByteRange.lowerBound.value
        var pieces = [ByteRange(from: ByteCount(baseByte + inner.location * 2),
                                to: ByteCount(baseByte + inner.upperBound * 2))]
        // Subtract interpolation children (direct children only — a nested template inside a
        // substitution is removed with the whole substitution).
        for index in 0 ..< stringNode.childCount {
            guard let child = stringNode.child(at: index),
                  let type = child.type,
                  type.contains("substitut") || type.contains("interpolat") else {
                continue
            }
            pieces = subtract(child.byteRange, from: pieces)
            guard !pieces.isEmpty else {
                return []
            }
        }
        return textRanges(for: pieces,
                          scanning: units,
                          baseByte: baseByte,
                          basePoint: stringNode.startPoint)
    }

    /// Deepest string-typed node under `root` containing `byteRange`, or `nil`.
    static func stringNode(containing byteRange: ByteRange, under root: TreeSitterNode) -> TreeSitterNode? {
        guard root.byteRange.contains(byteRange) || root.byteRange.overlaps(byteRange) else {
            return nil
        }
        for index in 0 ..< root.childCount {
            guard let child = root.child(at: index), child.byteRange.overlaps(byteRange) else {
                continue
            }
            if let found = stringNode(containing: byteRange, under: child) {
                return found
            }
        }
        if isStringNodeType(root.type) {
            return root
        }
        return nil
    }
}

// MARK: - Comment enumeration

private extension ManualLanguageInjectionDiscovery {
    /// Pre-order walk pruned to `window`, invoking `visit` for every comment-typed node.
    func collectComments(under node: TreeSitterNode, window: ByteRange?, visit: (TreeSitterNode) -> Void) {
        if let window, !node.byteRange.overlaps(window) {
            return
        }
        if let type = node.type, isCommentNodeType(type) {
            visit(node)
        }
        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }
            // Siblings are laid out in byte order, but keep the pruning check inside the
            // recursion so error nodes and extras cannot break the walk.
            collectComments(under: child, window: window, visit: visit)
        }
    }

    func isCommentNodeType(_ type: String) -> Bool {
        type.lowercased().contains("comment")
    }

    /// `language=ID` value in a comment node's text, or `nil`.
    func languageNameDirective(in commentNode: TreeSitterNode) -> String? {
        guard let text = readText?(NSRange(commentNode.byteRange)) else {
            return nil
        }
        var body = text
        if let prefix = lineCommentPrefix, let stripped = stripLinePrefix(prefix, from: body) {
            body = stripped
        } else if let delimiters = blockCommentDelimiters {
            body = stripBlockDelimiters(delimiters, from: body)
        }
        // `prefix=`/`suffix=` ride along in the same comment for later evaluation; only the
        // `language` key matters here.
        for token in body.split(whereSeparator: { $0.isWhitespace }) {
            let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[0].lowercased() == "language" else {
                continue
            }
            var value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !value.isEmpty else {
                return nil
            }
            // Same tokenizing as fences (` ```python {highlight=1} `): first token wins, so
            // `language=js extra` resolves like a ```js fence.
            value = FenceLanguageName.normalize(value) ?? value
            return value
        }
        return nil
    }

    func stripLinePrefix(_ prefix: String, from text: String) -> String? {
        let trimmed = text.drop(while: { $0.isWhitespace })
        guard trimmed.hasPrefix(prefix) else {
            return nil
        }
        return String(trimmed.dropFirst(prefix.count))
    }

    func stripBlockDelimiters(_ delimiters: BlockCommentDelimiters, from text: String) -> String {
        var body = text
        if body.hasPrefix(delimiters.open) {
            body = String(body.dropFirst(delimiters.open.count))
        }
        if body.hasSuffix(delimiters.close), body.count >= delimiters.close.count {
            body = String(body.dropLast(delimiters.close.count))
        }
        return body
    }
}

// MARK: - Attachment

private extension ManualLanguageInjectionDiscovery {
    /// First string node starting in the rest of the comment's line, else in the next non-empty
    /// line (up to 8 lines ahead). A comment that attaches to nothing is ignored.
    func attachmentTarget(
        forCommentEndingAt endByte: ByteCount,
        endPoint: TreeSitterTextPoint,
        under root: TreeSitterNode,
        lines: LineTable
    ) -> TreeSitterNode? {
        let utf16Offset = endByte.value / 2
        guard let commentLine = lines.lineIndex(at: utf16Offset) else {
            return nil
        }
        let restOfLine = lines.lineRange(at: commentLine).clippedFrom(utf16Offset)
        if lines.isNonBlank(restOfLine),
           let found = firstStringNode(startingIn: restOfLine, under: root) {
            return found
        }
        // Same-line span had no string (or was blank): fall through to the next non-empty line.
        // A same-line string wins over a later line, matching "above or before".
        for ahead in 1 ... 8 {
            let index = commentLine + ahead
            guard index < lines.count else {
                return nil
            }
            let span = lines.lineRange(at: index)
            guard lines.isNonBlank(span) else {
                continue
            }
            return firstStringNode(startingIn: span, under: root)
        }
        return nil
    }

    /// First string-typed node (pre-order) whose start lies in `utf16Span`.
    func firstStringNode(startingIn utf16Span: NSRange, under root: TreeSitterNode) -> TreeSitterNode? {
        let span = ByteRange(utf16Range: utf16Span)
        return firstStringNode(startingIn: span, under: root)
    }

    func firstStringNode(startingIn span: ByteRange, under node: TreeSitterNode) -> TreeSitterNode? {
        guard node.byteRange.overlaps(span) || span.contains(node.byteRange) else {
            return nil
        }
        if Self.isStringNodeType(node.type),
           node.startByte >= span.lowerBound, node.startByte < span.upperBound {
            return node
        }
        for index in 0 ..< node.childCount {
            guard let child = node.child(at: index) else {
                continue
            }
            if let found = firstStringNode(startingIn: span, under: child) {
                return found
            }
        }
        return nil
    }

    static func isStringNodeType(_ type: String?) -> Bool {
        guard let type else {
            return false
        }
        // `string`, `template_string`, `string_literal`, `line_string_literal`, …
        return type.lowercased().contains("string")
    }
}

// MARK: - Content carving helpers

private extension ManualLanguageInjectionDiscovery {
    /// UTF-16 range of the string body: an optional ASCII-letter prefix (`f`, `rb`, …) plus an
    /// opening quote run (`"`, `'`, `` ` ``, triple-quoted) stripped from both ends. `nil` when no
    /// opening quote is found — the caller falls back to the whole node.
    static func innerContentUTF16Range(of units: [UInt16]) -> NSRange? {
        var start = 0
        while start < units.count, isASCIILetter(units[start]) {
            start += 1
        }
        guard start < units.count, isQuote(units[start]) else {
            return nil
        }
        let quote = units[start]
        var run = 0
        while start + run < units.count, units[start + run] == quote, run < 3 {
            run += 1
        }
        let contentStart = start + run
        var end = units.count
        var closing = 0
        while end > contentStart, units[end - 1] == quote, closing < run {
            end -= 1
            closing += 1
        }
        guard end >= contentStart else {
            return nil
        }
        return NSRange(location: contentStart, length: end - contentStart)
    }

    static func isASCIILetter(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
    }

    static func isQuote(_ unit: UInt16) -> Bool {
        unit == 34 || unit == 39 || unit == 96
    }

    static func subtract(_ range: ByteRange, from pieces: [ByteRange]) -> [ByteRange] {
        var result: [ByteRange] = []
        for piece in pieces {
            if !piece.overlaps(range) {
                result.append(piece)
                continue
            }
            if range.lowerBound > piece.lowerBound {
                result.append(ByteRange(from: piece.lowerBound, to: min(range.lowerBound, piece.upperBound)))
            }
            if range.upperBound < piece.upperBound {
                result.append(ByteRange(from: max(range.upperBound, piece.lowerBound), to: piece.upperBound))
            }
        }
        return result.filter { !$0.isEmpty }
    }

    static func subtractRange(_ range: ByteRange, from pieces: [ByteRange]) -> [ByteRange] {
        subtract(range, from: pieces)
    }
}

// MARK: - Shared range splitting

extension ManualLanguageInjectionDiscovery {
    /// Splits absolute `pieces` (UTF-16 bytes) into text ranges by scanning `units` (UTF-16 text
    /// starting at `baseByte`/`basePoint`) once. Mirrors the parser's counting: one row per `\n`,
    /// columns in bytes (UTF-16 units × 2). Shared with temporary-injection conversion in the
    /// layer. Empty when a boundary falls outside the scanned text.
    static func textRanges(
        for pieces: [ByteRange],
        scanning units: [UInt16],
        baseByte: Int,
        basePoint: TreeSitterTextPoint
    ) -> [TreeSitterTextRange] {
        let sorted = pieces.sorted { $0.lowerBound.value < $1.lowerBound.value }
        // Absolute UTF-16 offsets of every boundary, in scan order.
        var boundaries: [Int] = []
        for piece in sorted {
            boundaries.append((piece.lowerBound.value - baseByte) / 2)
            boundaries.append((piece.upperBound.value - baseByte) / 2)
        }
        var points: [TreeSitterTextPoint] = []
        var row = basePoint.row
        var column = basePoint.column
        var scanned = 0
        var boundaryIndex = 0
        // Boundaries at 0 resolve to the base point without scanning.
        while boundaryIndex < boundaries.count, boundaries[boundaryIndex] <= 0 {
            points.append(TreeSitterTextPoint(row: row, column: column))
            boundaryIndex += 1
        }
        while scanned < units.count, boundaryIndex < boundaries.count {
            if units[scanned] == 10 {
                row += 1
                column = 0
            } else {
                column += 2
            }
            scanned += 1
            while boundaryIndex < boundaries.count, boundaries[boundaryIndex] <= scanned {
                points.append(TreeSitterTextPoint(row: row, column: column))
                boundaryIndex += 1
            }
        }
        guard points.count == boundaries.count else {
            return []
        }
        var ranges: [TreeSitterTextRange] = []
        for index in stride(from: 0, to: points.count, by: 2) {
            let piece = sorted[index / 2]
            ranges.append(TreeSitterTextRange(startPoint: points[index],
                                              endPoint: points[index + 1],
                                              startByte: piece.lowerBound,
                                              endByte: piece.upperBound))
        }
        return ranges
    }
}

// MARK: - Line table

/// UTF-16 line layout of a string, built once per discovery pass that found a directive.
private struct LineTable {
    /// UTF-16 offset where each line starts.
    let starts: [Int]
    let units: [UInt16]

    var count: Int {
        starts.count
    }

    var totalLength: Int {
        units.count
    }

    init(text: String) {
        var starts = [0]
        let units = Array(text.utf16)
        for (offset, unit) in units.enumerated() {
            if unit == 10 {
                starts.append(offset + 1)
            }
        }
        self.starts = starts
        self.units = units
    }

    func lineIndex(at utf16Offset: Int) -> Int? {
        guard utf16Offset >= 0, utf16Offset <= totalLength else {
            return nil
        }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= utf16Offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// Full UTF-16 span of line `index`, excluding the newline.
    func lineRange(at index: Int) -> NSRange {
        let start = starts[index]
        let next = index + 1 < starts.count ? starts[index + 1] : totalLength + 1
        // `next` points past the `\n` when there is one; drop it.
        let end = min(next - 1, totalLength)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// `true` when the span holds anything but spaces, tabs and carriage returns.
    func isNonBlank(_ range: NSRange) -> Bool {
        var offset = range.location
        let end = min(range.upperBound, units.count)
        while offset < end {
            let unit = units[offset]
            if unit != 32, unit != 9, unit != 13 {
                return true
            }
            offset += 1
        }
        return false
    }

    /// `true` when the span's text after the comment is only whitespace or nothing.
    func isBlank(_ range: NSRange) -> Bool {
        !isNonBlank(range)
    }
}

private extension NSRange {
    func clippedFrom(_ offset: Int) -> NSRange {
        let start = max(location, offset)
        let end = upperBound
        return NSRange(location: start, length: max(0, end - start))
    }
}
