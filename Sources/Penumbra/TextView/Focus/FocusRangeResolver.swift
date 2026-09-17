import Foundation
import NaturalLanguage

/// Resolves the ranges that Focus Mode keeps at full opacity.
///
/// Paragraphs are hard-line-delimited, matching the public Focus Mode contract. Sentence
/// tokenization is scoped to those paragraphs and cached by paragraph contents, so a caret move
/// never tokenizes the whole document.
final class TextSegmenter {
    private struct SentenceRange {
        let range: NSRange
    }

    private var sentenceCache: [String: [NSRange]] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 64

    func focusRanges(for selections: [NSRange],
                     granularity: FocusGranularity,
                     lineManager: LineManager,
                     stringView: StringView) -> [NSRange] {
        var allRanges: [NSRange] = []
        for selection in selections {
            switch granularity {
            case .paragraph:
                allRanges += paragraphRanges(for: selection, lineManager: lineManager, stringView: stringView)
            case .sentence:
                allRanges += sentenceRanges(for: selection, lineManager: lineManager, stringView: stringView)
            }
        }
        let documentRange = NSRange(location: 0, length: stringView.length)
        return MultiSelectionController.normalize(allRanges).map { $0.capped(to: documentRange) }
    }

    private func paragraphRanges(for selection: NSRange,
                                 lineManager: LineManager,
                                 stringView: StringView) -> [NSRange] {
        let documentLength = stringView.length
        guard lineManager.lineCount > 0 else {
            return []
        }
        if selection.length == 0 {
            guard let line = lineManager.line(containingCharacterAt: min(selection.location, documentLength)) else {
                return []
            }
            let range = contentRange(of: line)
            return range.length > 0 ? [range] : []
        }

        let safeSelection = selection.capped(to: NSRange(location: 0, length: documentLength))
        guard safeSelection.length > 0 else {
            return []
        }
        return lineManager.lines(in: safeSelection).compactMap { line in
            let range = contentRange(of: line)
            return range.length > 0 ? range : nil
        }
    }

    private func sentenceRanges(for selection: NSRange,
                                lineManager: LineManager,
                                stringView: StringView) -> [NSRange] {
        let paragraphs = paragraphRanges(for: selection, lineManager: lineManager, stringView: stringView)
        guard !paragraphs.isEmpty else {
            return []
        }

        if selection.length == 0, let paragraph = paragraphs.first {
            let sentences = tokenizedSentences(in: paragraph, stringView: stringView)
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

        var touched: [NSRange] = []
        for paragraph in paragraphs {
            let sentences = tokenizedSentences(in: paragraph, stringView: stringView)
            touched += sentences.lazy.map(\.range).filter { $0.overlaps(selection) }
        }
        guard let first = touched.first, let last = touched.last else {
            return paragraphs
        }
        return [NSRange(location: first.location, length: last.upperBound - first.location)]
    }

    private func contentRange(of line: DocumentLineNode) -> NSRange {
        NSRange(location: line.location, length: line.data.length)
    }

    private func tokenizedSentences(in paragraph: NSRange, stringView: StringView) -> [SentenceRange] {
        guard paragraph.length > 0, let text = stringView.substring(in: paragraph) else {
            return []
        }
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
