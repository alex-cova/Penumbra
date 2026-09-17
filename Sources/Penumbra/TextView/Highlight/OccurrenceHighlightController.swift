import Foundation

/// Highlights other occurrences of the current selection (or the word under the caret when the
/// selection is empty), IntelliJ-style, via ``EmphasisManager`` under
/// ``EmphasisGroup/occurrences``.
///
/// Modeled on ``DiagnosticEmphasisController``. Driven from `TextInputView`'s selection-change
/// path. Small documents are scanned synchronously; large ones use ``FindSearchEngine`` on a
/// detached task. Either way the work is debounced and generation-guarded so rapid caret moves
/// don't pile up.
@MainActor
final class OccurrenceHighlightController {
    weak var emphasisManager: EmphasisManager?
    var stringView: StringView
    var tokenizer: UITextInputTokenizer?

    /// Master switch. When `false`, existing occurrence emphases are cleared.
    var isEnabled = false {
        didSet {
            if isEnabled != oldValue, !isEnabled {
                clear()
            }
        }
    }

    /// Resolved ``LanguageConfiguration`` — gates on `highlightsOccurrences` and supplies
    /// `minimumOccurrenceLength`. `nil` disables the feature.
    var configuration: LanguageConfiguration?

    var theme: Theme {
        didSet { refreshFromLastRequest() }
    }

    /// Above this many UTF-16 units the scan runs on a detached task.
    static let offMainThreshold = 50_000
    /// Never emphasize more than this — `HighlightService` rebuilds every fragment on each set.
    static let maxMatches = 200

    /// Coalesces rapid caret moves. Instance-level so tests can zero it.
    var debounceInterval: TimeInterval = 0.12

    private var generation = 0
    private var debounceWorkItem: DispatchWorkItem?
    private var searchTask: Task<Void, Never>?
    private var lastRequest: (range: NSRange?, isMultiCaret: Bool)?

    init(stringView: StringView, theme: Theme) {
        self.stringView = stringView
        self.theme = theme
    }

    /// Call whenever the selection changes.
    /// - Parameters:
    ///   - selectedRange: The primary selection, or `nil`.
    ///   - isMultiCaret: `true` when more than one caret/selection is active (feature bails).
    func selectionDidChange(selectedRange: NSRange?, isMultiCaret: Bool) {
        lastRequest = (selectedRange, isMultiCaret)
        generation &+= 1
        let generation = generation
        debounceWorkItem?.cancel()
        searchTask?.cancel()

        guard isEnabled,
              let configuration,
              configuration.highlightsOccurrences,
              !isMultiCaret,
              let term = term(for: selectedRange, minimumLength: configuration.minimumOccurrenceLength) else {
            clear()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.runSearch(term: term, generation: generation)
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    func clear() {
        debounceWorkItem?.cancel()
        searchTask?.cancel()
        emphasisManager?.removeEmphases(for: EmphasisGroup.occurrences)
    }
}

private extension OccurrenceHighlightController {
    struct Term {
        var text: String
        /// The occurrence the caret is currently on — rendered non-inactive.
        var currentRange: NSRange
        /// `true` when derived from the word under the caret (whole-word matching).
        var wholeWord: Bool
    }

    func term(for selectedRange: NSRange?, minimumLength: Int) -> Term? {
        // Bounded: only `stringView.length` (O(1)) plus a windowed `substring(in:)` around the
        // caret/selection. Must not touch `stringView.string` — this runs synchronously on every
        // keystroke (before the debounce below), so a full materialization here would make typing
        // O(document size) on a file-backed document whenever occurrence highlighting is enabled.
        let documentLength = stringView.length
        guard let selectedRange, selectedRange.location <= documentLength else {
            return nil
        }
        if selectedRange.length == 0 {
            guard let tokenizer,
                  let wordRange = SelectNextOccurrence.wordRange(at: selectedRange.location, documentLength: documentLength, tokenizer: tokenizer),
                  wordRange.length >= minimumLength,
                  let word = stringView.substring(in: wordRange),
                  isHighlightable(word) else {
                return nil
            }
            return Term(text: word, currentRange: wordRange, wholeWord: true)
        }
        guard selectedRange.length >= minimumLength,
              NSMaxRange(selectedRange) <= documentLength,
              let text = stringView.substring(in: selectedRange),
              isHighlightable(text) else {
            return nil
        }
        return Term(text: text, currentRange: selectedRange, wholeWord: false)
    }

    func isHighlightable(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return false
        }
        return text.contains { !$0.isWhitespace }
    }

    func runSearch(term: Term, generation: Int) {
        guard generation == self.generation else { return }
        let documentLength = stringView.length
        if documentLength < Self.offMainThreshold {
            let matches = matchRanges(for: term, in: stringView.string)
            apply(matches: matches, current: term.currentRange, generation: generation)
            return
        }
        // Large document: avoid materializing UTF-16 on the main thread. A piece-tree buffer
        // hands `FindSearchEngine` a `Sendable`, non-materializing snapshot — the same source
        // `TextView.makeFindTextSource()` uses for Find. Only contiguous storage (bounded to
        // `StringView.pieceTreeUntitledThreshold`, i.e. small/untitled buffers) falls back to a
        // materialized source, matching `makeFindTextSource()`'s own fallback.
        let source: any FindTextSource = stringView.contentSnapshot() ?? StringFindTextSource(stringView.string as String)
        let options = FindSearchOptions(query: term.text, matchCase: true, wholeWord: term.wholeWord, useRegex: false)
        let cap = Self.maxMatches
        let anchor = term.currentRange.location
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = FindSearchEngine.search(options: options, in: source, anchorLocation: anchor, maxHighlights: cap)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, generation == self.generation else { return }
                self.apply(matches: outcome.highlightRanges, current: term.currentRange, generation: generation)
            }
        }
    }

    func matchRanges(for term: Term, in string: NSString) -> [NSRange] {
        var matches = SelectNextOccurrence.allMatches(for: term.text, in: string, caseSensitive: true)
        if term.wholeWord {
            matches = matches.filter { isWholeWord($0, in: string) }
        }
        if matches.count > Self.maxMatches {
            matches = Array(matches.prefix(Self.maxMatches))
        }
        return matches
    }

    func isWholeWord(_ range: NSRange, in string: NSString) -> Bool {
        let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        if range.location > 0 {
            let scalar = string.character(at: range.location - 1)
            if let unicodeScalar = Unicode.Scalar(scalar), wordCharacters.contains(unicodeScalar) {
                return false
            }
        }
        let after = NSMaxRange(range)
        if after < string.length {
            let scalar = string.character(at: after)
            if let unicodeScalar = Unicode.Scalar(scalar), wordCharacters.contains(unicodeScalar) {
                return false
            }
        }
        return true
    }

    func apply(matches: [NSRange], current: NSRange, generation: Int) {
        guard generation == self.generation, let emphasisManager else { return }
        // A lone match (only the caret's own occurrence) isn't worth highlighting.
        let meaningful = matches.filter { $0.length > 0 }
        guard meaningful.count > 1 else {
            emphasisManager.removeEmphases(for: EmphasisGroup.occurrences)
            return
        }
        let emphases = meaningful.map { range in
            Emphasis(range: range, style: .standard, flash: false, inactive: range != current, selectInDocument: false)
        }
        emphasisManager.replaceEmphases(emphases, for: EmphasisGroup.occurrences, color: theme.occurrenceHighlightColor)
    }

    func refreshFromLastRequest() {
        guard let lastRequest else { return }
        selectionDidChange(selectedRange: lastRequest.range, isMultiCaret: lastRequest.isMultiCaret)
    }
}
