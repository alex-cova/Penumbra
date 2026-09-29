import Foundation
import NaturalLanguage

/// Resolves the ranges that Focus Mode keeps at full opacity.
///
/// A paragraph is a run of non-blank lines, so a wrapped Markdown paragraph is one unit; a
/// structural block (a fenced code block) reported by `blockRange` is one unit too. Sentence
/// tokenization runs on the paragraph with line breaks read as spaces, so a sentence continues
/// across hard line breaks up to its terminator. Both are bounded by `maxParagraphLines` per
/// direction and cached by paragraph contents, so a caret move never scans the whole document.
final class TextSegmenter {
    private struct SentenceRange {
        let range: NSRange
    }

    /// Lines a paragraph may extend from the caret line in each direction.
    static let maxParagraphLines = 200
    /// Longest paragraph range tokenized for a non-empty selection.
    static let maxSelectionTokenizationLength = 20_000

    private var sentenceCache: [String: [NSRange]] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 64

    /// - Parameter blockRange: The structural block (e.g. a fenced code block) containing a UTF-16
    ///   location, if any. It replaces the paragraph or sentence as the focus unit.
    func focusRanges(for selections: [NSRange],
                     granularity: FocusGranularity,
                     lineManager: LineManager,
                     stringView: StringView,
                     blockRange: ((Int) -> NSRange?)? = nil) -> [NSRange] {
        var allRanges: [NSRange] = []
        for selection in selections {
            let paragraphs = paragraphRanges(for: selection,
                                             lineManager: lineManager,
                                             stringView: stringView,
                                             blockRange: blockRange)
            switch granularity {
            case .paragraph:
                allRanges += paragraphs
            case .sentence:
                allRanges += sentenceRanges(in: paragraphs,
                                            for: selection,
                                            stringView: stringView,
                                            blockRange: blockRange)
            }
        }
        let documentRange = NSRange(location: 0, length: stringView.length)
        return MultiSelectionController.normalize(allRanges).map { $0.capped(to: documentRange) }
    }

    /// One range from the start of the first touched paragraph to the end of the last one. Empty
    /// when the caret sits on a blank line.
    private func paragraphRanges(for selection: NSRange,
                                 lineManager: LineManager,
                                 stringView: StringView,
                                 blockRange: ((Int) -> NSRange?)?) -> [NSRange] {
        let documentLength = stringView.length
        guard lineManager.lineCount > 0 else {
            return []
        }
        let safeSelection = selection.capped(to: NSRange(location: 0, length: documentLength))
        let startLocation = min(safeSelection.location, documentLength)
        // A selection ending right after a line break belongs to the line before it.
        let endLocation = safeSelection.length > 0 ? max(startLocation, safeSelection.upperBound - 1) : startLocation
        guard let startRow = lineManager.row(containingCharacterAt: startLocation),
              let endRow = lineManager.row(containingCharacterAt: endLocation) else {
            return []
        }

        var first = paragraphBounds(aroundRow: startRow, lineManager: lineManager, stringView: stringView,
                                    blockRange: blockRange)
        var last = endRow == startRow
            ? first
            : paragraphBounds(aroundRow: endRow, lineManager: lineManager, stringView: stringView,
                              blockRange: blockRange)
        if first == nil, endRow != startRow {
            first = last
        }
        if last == nil {
            last = first
        }
        guard let first, let last else {
            return []
        }
        let lower = min(first.lowerBound, last.lowerBound)
        let upper = max(first.upperBound, last.upperBound)
        return upper > lower ? [NSRange(location: lower, length: upper - lower)] : []
    }

    /// The paragraph (or structural block) containing the line at `row`, or `nil` for a blank line.
    private func paragraphBounds(aroundRow row: Int,
                                 lineManager: LineManager,
                                 stringView: StringView,
                                 blockRange: ((Int) -> NSRange?)?) -> Range<Int>? {
        let rowRange = lineManager.contentRange(atRow: row)
        if let blockRange, let block = blockRange(rowRange.location), block.length > 0 {
            return block.location..<block.upperBound
        }
        guard !isBlank(rowRange, stringView: stringView) else {
            return nil
        }
        var firstRow = row
        var lastRow = row
        let lastAllowedRow = lineManager.lineCount - 1
        while firstRow > 0,
              row - firstRow < Self.maxParagraphLines,
              !isBlank(lineManager.contentRange(atRow: firstRow - 1), stringView: stringView) {
            firstRow -= 1
        }
        while lastRow < lastAllowedRow,
              lastRow - row < Self.maxParagraphLines,
              !isBlank(lineManager.contentRange(atRow: lastRow + 1), stringView: stringView) {
            lastRow += 1
        }
        let lower = lineManager.contentRange(atRow: firstRow).location
        let upper = lineManager.contentRange(atRow: lastRow).upperBound
        return lower..<upper
    }

    /// `true` for an empty line or one holding only spaces and tabs.
    private func isBlank(_ contentRange: NSRange, stringView: StringView) -> Bool {
        guard contentRange.length > 0 else {
            return true
        }
        // A long line is never blank in practice; don't read it to find out.
        guard contentRange.length <= 64, let text = stringView.substring(in: contentRange) else {
            return false
        }
        return text.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private func sentenceRanges(in paragraphs: [NSRange],
                                for selection: NSRange,
                                stringView: StringView,
                                blockRange: ((Int) -> NSRange?)?) -> [NSRange] {
        guard let paragraph = paragraphs.first else {
            return []
        }
        // Code isn't prose: a structural block stays whole.
        if let blockRange, let block = blockRange(paragraph.location), block.length > 0 {
            return [paragraph]
        }

        // A huge selection (Select All) keeps its whole paragraph range rather than tokenizing it.
        if selection.length > 0, paragraph.length > Self.maxSelectionTokenizationLength {
            return paragraphs
        }
        let sentences = tokenizedSentences(in: paragraph, stringView: stringView)
        if selection.length == 0 {
            guard !sentences.isEmpty else {
                return [paragraph]
            }
            if let sentence = sentences.first(where: { $0.range.contains(selection.location) }) {
                return [sentence.range]
            }
            if let previous = sentences.last(where: { $0.range.upperBound <= selection.location }) {
                return [previous.range]
            }
            return [sentences[0].range]
        }

        let touched = sentences.lazy.map(\.range).filter { $0.overlaps(selection) }
        guard let first = touched.first, let last = touched.last else {
            return paragraphs
        }
        return [NSRange(location: first.location, length: last.upperBound - first.location)]
    }

    private func tokenizedSentences(in paragraph: NSRange, stringView: StringView) -> [SentenceRange] {
        guard paragraph.length > 0, let rawText = stringView.substring(in: paragraph) else {
            return []
        }
        // Line breaks read as spaces (same UTF-16 length, so ranges map back 1:1), letting a
        // sentence continue across hard-wrapped lines instead of ending at each one.
        var scalars = String.UnicodeScalarView()
        for scalar in rawText.unicodeScalars {
            scalars.append(scalar == "\n" || scalar == "\r" ? " " : scalar)
        }
        let text = String(scalars)
        if let cached = sentenceCache[text] {
            return cached.map {
                SentenceRange(range: NSRange(location: paragraph.location + $0.location, length: $0.length))
            }
        }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var localRanges: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            let location = tokenRange.lowerBound.utf16Offset(in: text)
            let length = tokenRange.upperBound.utf16Offset(in: text) - location
            if length > 0 {
                localRanges.append(NSRange(location: location, length: length))
            }
            return true
        }
        cache(localRanges, for: text)
        return localRanges.map {
            SentenceRange(range: NSRange(location: paragraph.location + $0.location, length: $0.length))
        }
    }

    private func cache(_ ranges: [NSRange], for text: String) {
        sentenceCache[text] = ranges
        cacheOrder.removeAll { $0 == text }
        cacheOrder.append(text)
        if cacheOrder.count > cacheLimit {
            sentenceCache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
