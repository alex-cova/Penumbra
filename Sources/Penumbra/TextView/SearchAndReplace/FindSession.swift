import Foundation

/// Stateful find/replace session driving ``FindSearchEngine`` — the headless counterpart to the
/// `TextView`-bound find panel (`showFindPanel`/`FindPanelController`). Holds the query and its
/// options, the current match, and the capped highlight window, and exposes navigation over a
/// ``FindTextSource`` (or `String` wrappers) rather than reading a live text view.
///
/// ```swift
/// let session = FindSession()
/// session.query = "foo"
/// let outcome = FindSearchEngine.search(options: session.searchOptions(), in: text, anchorLocation: 0)
/// session.applySearchOutcome(outcome)
/// session.selectNext(in: text)
/// ```
///
/// Pair with ``FindSearchScheduler`` for debounced, off-main-thread searching as the query or
/// document text changes. ``replaceCurrent(in:)`` / ``replaceAll(in:)`` stay `String`-only
/// because they return a whole new document string.
@MainActor
public final class FindSession {
    public var query = ""
    public var replacement = ""
    public var matchCase = false
    public var wholeWord = false
    public var useRegex = false
    public var isReplaceMode = false

    public private(set) var isPresented = false
    public private(set) var matchCount = 0
    public private(set) var currentIndex: Int?
    public private(set) var currentRange: NSRange?
    public private(set) var highlightRanges: [NSRange] = []
    public private(set) var errorMessage: String?
    /// `false` while a long scan is still running and the counts above are a progress snapshot.
    public private(set) var isComplete = true

    /// Snapshot of the options a search outcome was computed for, used to discard stale results
    /// from a search that's still in flight when the query changes underneath it.
    public struct SearchSnapshot: Sendable, Equatable {
        public let query: String
        public let matchCase: Bool
        public let wholeWord: Bool
        public let useRegex: Bool
    }

    public init() {}

    public var matchCountLabel: String {
        if query.isEmpty { return "" }
        if let errorMessage { return errorMessage }
        guard matchCount > 0 else { return "No matches" }
        if let currentIndex {
            if isComplete {
                return "\(currentIndex + 1) of \(matchCount)"
            }
            return "\(currentIndex + 1) of \(matchCount)+"
        }
        if isComplete {
            return "\(matchCount) matches"
        }
        return "\(matchCount)+ matches"
    }

    public func showFind() {
        isReplaceMode = false
        isPresented = true
    }

    public func showReplace() {
        isReplaceMode = true
        isPresented = true
    }

    public func hide() {
        isPresented = false
        clearHighlights()
    }

    public func clearHighlights() {
        matchCount = 0
        currentIndex = nil
        currentRange = nil
        highlightRanges = []
        errorMessage = nil
        isComplete = true
    }

    public func searchOptions() -> FindSearchOptions {
        FindSearchOptions(query: query, matchCase: matchCase, wholeWord: wholeWord, useRegex: useRegex)
    }

    public func matchesSnapshot(_ snapshot: SearchSnapshot) -> Bool {
        query == snapshot.query
            && matchCase == snapshot.matchCase
            && wholeWord == snapshot.wholeWord
            && useRegex == snapshot.useRegex
    }

    public func applySearchOutcome(_ outcome: FindSearchOutcome) {
        if let errorMessage = outcome.errorMessage {
            matchCount = 0
            currentIndex = nil
            currentRange = nil
            highlightRanges = []
            self.errorMessage = errorMessage
            isComplete = true
            return
        }
        errorMessage = nil
        matchCount = outcome.matchCount
        currentIndex = outcome.currentIndex
        currentRange = outcome.currentRange
        highlightRanges = outcome.highlightRanges
        isComplete = outcome.isComplete
    }

    public func selectNext(in text: String) {
        selectNext(in: StringFindTextSource(text))
    }

    public func selectNext(in source: any FindTextSource) {
        guard matchCount > 0 else { return }
        let options = searchOptions()
        let after = currentRange.map { $0.location + max($0.length, 1) } ?? 0
        if let next = FindSearchEngine.findNext(options: options, in: source, after: after) {
            currentRange = next
            currentIndex = ((currentIndex ?? -1) + 1) % matchCount
            scheduleHighlightRefresh(in: source)
            return
        }
        if let first = FindSearchEngine.findNext(options: options, in: source, after: 0) {
            currentRange = first
            currentIndex = 0
            scheduleHighlightRefresh(in: source)
        }
    }

    public func selectPrevious(in text: String) {
        selectPrevious(in: StringFindTextSource(text))
    }

    public func selectPrevious(in source: any FindTextSource) {
        guard matchCount > 0 else { return }
        let options = searchOptions()
        let before = currentRange?.location ?? source.utf16Length
        if let previous = FindSearchEngine.findPrevious(options: options, in: source, before: before) {
            currentRange = previous
            currentIndex = ((currentIndex ?? 0) - 1 + matchCount) % matchCount
            scheduleHighlightRefresh(in: source)
            return
        }
        let nsLength = source.utf16Length
        if let last = FindSearchEngine.findPrevious(options: options, in: source, before: nsLength + 1) {
            currentRange = last
            currentIndex = matchCount - 1
            scheduleHighlightRefresh(in: source)
        }
    }

    private var highlightRefreshTask: Task<Void, Never>?

    private func scheduleHighlightRefresh(in source: any FindTextSource) {
        highlightRefreshTask?.cancel()
        let options = searchOptions()
        let anchor = currentRange?.location ?? 0
        if source.utf16Length < FindSearchEngine.offMainCharacterThreshold {
            refreshHighlightWindow(in: source)
            return
        }
        highlightRefreshTask = Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) {
                FindSearchEngine.search(options: options, in: source, anchorLocation: anchor)
            }.value
            guard !Task.isCancelled else { return }
            highlightRanges = outcome.highlightRanges
        }
    }

    private func refreshHighlightWindow(in source: any FindTextSource) {
        guard matchCount > 0 else {
            highlightRanges = []
            return
        }
        let outcome = FindSearchEngine.search(options: searchOptions(), in: source, anchorLocation: currentRange?.location ?? 0)
        highlightRanges = outcome.highlightRanges
    }

    /// Replaces the current match in `text`. Returns the new text and the selection covering the
    /// inserted replacement, or `nil` if there's no current match.
    public func replaceCurrent(in text: String) -> (text: String, selection: NSRange)? {
        guard let range = currentRange else { return nil }
        let ns = text as NSString
        guard NSMaxRange(range) <= ns.length else { return nil }
        let newText = ns.replacingCharacters(in: range, with: replacement)
        let selection = NSRange(location: range.location, length: (replacement as NSString).length)
        let outcome = FindSearchEngine.search(options: searchOptions(), in: newText, anchorLocation: range.location)
        applySearchOutcome(outcome)
        return (newText, selection)
    }

    public func replaceAll(in text: String) -> String? {
        guard matchCount > 0 else { return nil }
        do {
            let newText = try FindSearchEngine.replaceAll(options: searchOptions(), in: text, replacement: replacement)
            applySearchOutcome(FindSearchEngine.search(options: searchOptions(), in: newText, anchorLocation: 0))
            return newText
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Centers up to `maxCount` ranges from `matches` around `currentIndex`, for callers that
    /// already have a full match list and just need a capped highlight window (mirrors the
    /// windowing ``FindSearchEngine`` applies internally).
    public nonisolated static func cappedHighlightRanges(
        matches: [NSRange],
        currentIndex: Int?,
        maxCount: Int = FindSearchEngine.maxHighlightedMatches
    ) -> [NSRange] {
        guard matches.count > maxCount else { return matches }
        guard let currentIndex, matches.indices.contains(currentIndex) else {
            return Array(matches.prefix(maxCount))
        }
        let half = maxCount / 2
        var start = max(0, currentIndex - half)
        let end = min(matches.count, start + maxCount)
        if end - start < maxCount {
            start = max(0, end - maxCount)
        }
        return Array(matches[start..<end])
    }

    /// Enumerates every match, throwing if the pattern is invalid rather than silently returning
    /// an empty list.
    public nonisolated static func findRanges(
        query: String,
        in text: String,
        matchCase: Bool,
        wholeWord: Bool,
        useRegex: Bool
    ) throws -> [NSRange] {
        try findRanges(
            query: query,
            in: StringFindTextSource(text),
            matchCase: matchCase,
            wholeWord: wholeWord,
            useRegex: useRegex
        )
    }

    public nonisolated static func findRanges(
        query: String,
        in source: any FindTextSource,
        matchCase: Bool,
        wholeWord: Bool,
        useRegex: Bool
    ) throws -> [NSRange] {
        let options = FindSearchOptions(query: query, matchCase: matchCase, wholeWord: wholeWord, useRegex: useRegex)
        if useRegex || wholeWord {
            let probe = FindSearchEngine.search(options: options, in: source, anchorLocation: 0)
            if let errorMessage = probe.errorMessage {
                throw NSError(domain: "FindSession", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
        }
        var ranges: [NSRange] = []
        var location = 0
        let nsLength = source.utf16Length
        while location <= nsLength {
            guard let next = FindSearchEngine.findNext(options: options, in: source, after: location) else {
                break
            }
            ranges.append(next)
            location = next.location + max(next.length, 1)
            if location > nsLength { break }
        }
        return ranges
    }
}
