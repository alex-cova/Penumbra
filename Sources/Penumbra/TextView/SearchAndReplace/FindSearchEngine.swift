import Foundation

/// Outcome of a single ``FindSearchEngine`` search.
public struct FindSearchOutcome: Sendable, Equatable {
    public let matchCount: Int
    public let currentIndex: Int?
    public let currentRange: NSRange?
    public let highlightRanges: [NSRange]
    public let errorMessage: String?
    /// `false` while a long scan is still running and this snapshot is a progress update.
    public let isComplete: Bool

    public init(
        matchCount: Int,
        currentIndex: Int?,
        currentRange: NSRange?,
        highlightRanges: [NSRange],
        errorMessage: String?,
        isComplete: Bool = true
    ) {
        self.matchCount = matchCount
        self.currentIndex = currentIndex
        self.currentRange = currentRange
        self.highlightRanges = highlightRanges
        self.errorMessage = errorMessage
        self.isComplete = isComplete
    }

    public static let empty = FindSearchOutcome(
        matchCount: 0,
        currentIndex: nil,
        currentRange: nil,
        highlightRanges: [],
        errorMessage: nil,
        isComplete: true
    )
}

/// Per-match replacement produced by ``FindSearchEngine/replaceAllMatches(options:in:replacement:)``.
public struct FindReplaceMatch: Sendable, Equatable {
    public let range: NSRange
    public let replacementText: String

    public init(range: NSRange, replacementText: String) {
        self.range = range
        self.replacementText = replacementText
    }
}

/// Options for a ``FindSearchEngine`` search. Unlike ``SearchQuery``, which is bound to a live
/// `TextView`, this is a plain value type — the search engine driven by it operates purely over
/// ``FindTextSource`` / `String` / `NSRange` and has no dependency on a text view.
public struct FindSearchOptions: Sendable, Equatable {
    public var query: String
    public var matchCase: Bool
    public var wholeWord: Bool
    public var useRegex: Bool

    public init(query: String, matchCase: Bool = false, wholeWord: Bool = false, useRegex: Bool = false) {
        self.query = query
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.useRegex = useRegex
    }

    /// Bridges from the `TextView`-oriented ``SearchQuery``, so callers already using
    /// `TextView.search(for:)` can adopt ``FindSearchEngine`` without a second query model.
    ///
    /// Lossy one way: `SearchQuery.MatchMethod.startsWith`/`.endsWith` have no boolean equivalent
    /// here and collapse to plain "contains" (`wholeWord: false, useRegex: false`).
    public init(_ searchQuery: SearchQuery) {
        self.query = searchQuery.text
        self.matchCase = searchQuery.isCaseSensitive
        switch searchQuery.matchMethod {
        case .fullWord:
            self.wholeWord = true
            self.useRegex = false
        case .regularExpression:
            self.wholeWord = false
            self.useRegex = true
        case .contains, .startsWith, .endsWith:
            self.wholeWord = false
            self.useRegex = false
        }
    }

    /// Converts to a ``SearchQuery`` usable with `TextView.search(for:)`.
    public var searchQuery: SearchQuery {
        let matchMethod: SearchQuery.MatchMethod = useRegex ? .regularExpression : (wholeWord ? .fullWord : .contains)
        return SearchQuery(text: query, matchMethod: matchMethod, isCaseSensitive: matchCase)
    }
}

/// Headless find/replace engine operating over ``FindTextSource`` or `String`/`NSRange`,
/// independent of any `TextView`. Pairs with ``FindSession`` (stateful navigation/replace) and
/// ``FindSearchScheduler`` (debounced, off-main-thread search) for a complete find-bar
/// implementation that doesn't require a live text view — useful for e.g. previewing search
/// results before text is loaded into an editor, or driving find/replace UI backed by a different
/// text-storage mechanism entirely.
///
/// This is a separate, parallel implementation to ``SearchQuery``/`TextView.search(for:)` rather
/// than a replacement for it — that API stays exactly as it is. Regular expressions use
/// `.anchorsMatchLines`, so `^`/`$` match at line boundaries (same as ``SearchQuery``).
///
/// On a non-contiguous ``FindTextSource``, regex and whole-word search walk 1 MiB unique windows.
/// The matcher region is unique plus a 64 KiB right pad so a match that starts in unique and ends
/// in the pad is found. A left pad is visible only via `.withTransparentBounds` /
/// `.withoutAnchoringBounds` when the unique start is past document start, so lookbehind / `\b` /
/// `^` see prior context without matching at a mid-file unique cut. Accept a match iff
/// `offset <= start < offset + unique`, or `start == utf16Length` on the last window. A successful
/// match longer than unique + right pad (for example `foo.*bar` with `bar` 2 MiB past `foo`) is
/// missed; there is no extend-on-touch heuristic. Contiguous `NSString` documents keep whole-string
/// `enumerateMatches`.
public enum FindSearchEngine {
    public static let maxHighlightedMatches = 100
    /// Literal/regex scans above this size run off the main actor when possible (see
    /// ``FindSearchScheduler``).
    public static let offMainCharacterThreshold = 50_000
    /// Unique UTF-16 units per literal window. Matcher region is unique plus a right pad.
    public static let literalWindowUTF16 = 64 * 1024
    /// Unique UTF-16 units per regex window.
    public static let regexWindowUTF16 = 1_048_576
    /// Left and right pad for regex windows.
    public static let regexOverlapUTF16 = 64 * 1024

    /// Overridable in tests so a match can be forced across a unique/right-pad cut without a 64 KB fixture.
    nonisolated(unsafe) static var debugLiteralWindowUTF16: Int?
    /// Overridable in tests so a regex match can be forced across a unique cut without a 1 MiB fixture.
    /// 2 MiB `^`/`$` tests must leave this `nil` so they use ``regexWindowUTF16``.
    nonisolated(unsafe) static var debugRegexWindowUTF16: Int?
    /// UTF-16 length of each windowed-literal substring, for tests that extend-1 actually widened the first window.
    nonisolated(unsafe) static var debugLiteralWindowSubstringUTF16Lengths: [Int]?

    public static func literalCaseInsensitiveOverlapUTF16(_ query: String) -> Int {
        max(query.utf16.count * 3, 16)
    }

    public static func search(
        options: FindSearchOptions,
        in text: String,
        anchorLocation: Int,
        maxHighlights: Int = maxHighlightedMatches,
        onProgress: (@Sendable (FindSearchOutcome) -> Void)? = nil
    ) -> FindSearchOutcome {
        search(
            options: options,
            in: StringFindTextSource(text),
            anchorLocation: anchorLocation,
            maxHighlights: maxHighlights,
            onProgress: onProgress
        )
    }

    public static func search(
        options: FindSearchOptions,
        in source: any FindTextSource,
        anchorLocation: Int,
        maxHighlights: Int = maxHighlightedMatches,
        onProgress: (@Sendable (FindSearchOutcome) -> Void)? = nil
    ) -> FindSearchOutcome {
        guard !options.query.isEmpty else { return .empty }
        do {
            if options.useRegex || options.wholeWord {
                return try regexSearch(
                    options: options,
                    in: source,
                    anchorLocation: anchorLocation,
                    maxHighlights: maxHighlights,
                    onProgress: onProgress
                )
            }
            return literalSearch(
                options: options,
                in: source,
                anchorLocation: anchorLocation,
                maxHighlights: maxHighlights,
                onProgress: onProgress
            )
        } catch {
            return FindSearchOutcome(
                matchCount: 0,
                currentIndex: nil,
                currentRange: nil,
                highlightRanges: [],
                errorMessage: error.localizedDescription
            )
        }
    }

    public static func findNext(options: FindSearchOptions, in text: String, after location: Int) -> NSRange? {
        findNext(options: options, in: StringFindTextSource(text), after: location)
    }

    public static func findNext(options: FindSearchOptions, in source: any FindTextSource, after location: Int) -> NSRange? {
        guard !options.query.isEmpty else { return nil }
        if options.useRegex || options.wholeWord {
            return try? regexNext(options: options, in: source, after: location)
        }
        let start = min(max(location, 0), source.utf16Length)
        var found: NSRange?
        _ = enumerateLiteralMatches(options: options, in: source, from: start) { range in
            found = range
            return false
        }
        return found
    }

    public static func findPrevious(options: FindSearchOptions, in text: String, before location: Int) -> NSRange? {
        findPrevious(options: options, in: StringFindTextSource(text), before: location)
    }

    public static func findPrevious(options: FindSearchOptions, in source: any FindTextSource, before location: Int) -> NSRange? {
        guard !options.query.isEmpty else { return nil }
        if options.useRegex || options.wholeWord {
            return try? regexPrevious(options: options, in: source, before: location)
        }
        if let ns = source.contiguousNSString {
            let limit = min(max(location, 0), ns.length)
            return contiguousLiteralPrevious(options: options, in: ns, before: limit)
        }
        return windowedLiteralPrevious(options: options, in: source, before: location)
    }

    public static func replaceAll(options: FindSearchOptions, in text: String, replacement: String) throws -> String {
        guard !options.query.isEmpty else { return text }
        if options.useRegex || options.wholeWord {
            let regex = try FindRegexCache.regex(pattern: regexPattern(for: options), options: regexOptions(for: options))
            let full = NSRange(location: 0, length: (text as NSString).length)
            return regex.stringByReplacingMatches(in: text, options: [], range: full, withTemplate: replacement)
        }
        let compare = NSString.CompareOptions(options.matchCase ? [] : [.caseInsensitive])
        return (text as NSString).replacingOccurrences(
            of: options.query,
            with: replacement,
            options: compare,
            range: NSRange(location: 0, length: (text as NSString).length)
        )
    }

    /// Expands a replacement string for a single match range (VS Code `$0`/`$1` placeholders).
    public static func replacementText(
        options: FindSearchOptions,
        in text: String,
        matching range: NSRange,
        replacement: String
    ) throws -> String {
        try replacementText(options: options, in: StringFindTextSource(text), matching: range, replacement: replacement)
    }

    public static func replacementText(
        options: FindSearchOptions,
        in source: any FindTextSource,
        matching range: NSRange,
        replacement: String
    ) throws -> String {
        guard options.useRegex || options.wholeWord else {
            return replacement
        }
        if let ns = source.contiguousNSString {
            let text = ns as String
            guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else {
                return replacement
            }
            let parsed = ReplacementStringParser(string: replacement).parse()
            guard parsed.containsPlaceholder else {
                return replacement
            }
            let regex = try FindRegexCache.regex(pattern: regexPattern(for: options), options: regexOptions(for: options))
            guard let result = regex.firstMatch(in: text, options: [], range: range), result.range == range else {
                return replacement
            }
            return parsed.string(byMatching: result, in: ns)
        }
        return try windowedReplacementText(
            options: options,
            in: source,
            matching: range,
            replacement: replacement
        )
    }

    /// Per-match ranges and replacement strings for building a ``BatchReplaceSet``.
    ///
    /// Unlike ``replaceAll(options:in:replacement:)``, which returns a whole new `String` and
    /// expands ICU `$n` templates, this keeps VS Code-style capture groups (`$0`, `$1`, `\u$1`,
    /// …) so Replace All can apply the same edits as
    /// ``TextView/search(for:replacingMatchesWith:)`` without replacing the entire buffer (and
    /// without a whole-document undo snapshot).
    public static func replaceAllMatches(
        options: FindSearchOptions,
        in text: String,
        replacement: String
    ) throws -> [FindReplaceMatch] {
        try replaceAllMatches(options: options, in: StringFindTextSource(text), replacement: replacement)
    }

    public static func replaceAllMatches(
        options: FindSearchOptions,
        in source: any FindTextSource,
        replacement: String
    ) throws -> [FindReplaceMatch] {
        guard !options.query.isEmpty else { return [] }
        if options.useRegex || options.wholeWord {
            return try regexReplaceAllMatches(options: options, in: source, replacement: replacement)
        }
        return try literalReplaceAllMatches(options: options, in: source, replacement: replacement)
    }

    // MARK: - Literal

    private static func literalSearch(
        options: FindSearchOptions,
        in source: any FindTextSource,
        anchorLocation: Int,
        maxHighlights: Int,
        onProgress: (@Sendable (FindSearchOutcome) -> Void)?
    ) -> FindSearchOutcome {
        let progress = SearchProgress(
            maxHighlights: maxHighlights,
            anchorLocation: anchorLocation,
            onProgress: onProgress
        )
        let result = enumerateLiteralMatches(options: options, in: source) { found in
            progress.add(found)
            return true
        }

        if result == .cancelled {
            return .empty
        }
        if progress.matchCount == 0 {
            return .empty
        }
        progress.wrapCurrentIfNeeded()

        let highlights = collectLiteralHighlights(
            options: options,
            in: source,
            around: progress.currentIndex ?? 0,
            matchCount: progress.matchCount,
            maxHighlights: maxHighlights
        )

        return progress.completeOutcome(highlights: highlights)
    }

    private static func collectLiteralHighlights(
        options: FindSearchOptions,
        in source: any FindTextSource,
        around index: Int,
        matchCount: Int,
        maxHighlights: Int
    ) -> [NSRange] {
        let half = maxHighlights / 2
        let startIndex = max(0, min(index - half, max(0, matchCount - maxHighlights)))
        let endIndex = min(matchCount, startIndex + maxHighlights)
        var ranges: [NSRange] = []
        var matchIndex = 0
        _ = enumerateLiteralMatches(options: options, in: source) { found in
            if matchIndex >= endIndex {
                return false
            }
            if matchIndex >= startIndex {
                ranges.append(found)
            }
            matchIndex += 1
            return true
        }
        return ranges
    }

    private static func literalReplaceAllMatches(
        options: FindSearchOptions,
        in source: any FindTextSource,
        replacement: String
    ) throws -> [FindReplaceMatch] {
        var matches: [FindReplaceMatch] = []
        let result = enumerateLiteralMatches(options: options, in: source) { found in
            guard found.length > 0 else {
                return false
            }
            matches.append(FindReplaceMatch(range: found, replacementText: replacement))
            return true
        }
        if result == .cancelled {
            throw CancellationError()
        }
        return matches
    }

    private enum LiteralEnumerateResult {
        case completed
        case cancelled
        case stopped
    }

    /// Invokes `body` for each accepted literal match in document coordinates.
    /// `body` returns `false` to stop.
    private static func enumerateLiteralMatches(
        options: FindSearchOptions,
        in source: any FindTextSource,
        from startOffset: Int = 0,
        body: (NSRange) -> Bool
    ) -> LiteralEnumerateResult {
        if let ns = source.contiguousNSString {
            return enumerateContiguousLiteralMatches(options: options, in: ns, from: startOffset, body: body)
        }
        return enumerateWindowedLiteralMatches(options: options, in: source, from: startOffset, body: body)
    }

    private static func enumerateContiguousLiteralMatches(
        options: FindSearchOptions,
        in ns: NSString,
        from startOffset: Int,
        body: (NSRange) -> Bool
    ) -> LiteralEnumerateResult {
        let compare = NSString.CompareOptions(options.matchCase ? [] : [.caseInsensitive])
        let origin = min(max(startOffset, 0), ns.length)
        var searchRange = NSRange(location: origin, length: ns.length - origin)
        while searchRange.length > 0 {
            if Task.isCancelled {
                return .cancelled
            }
            let found = ns.range(of: options.query, options: compare, range: searchRange)
            guard found.location != NSNotFound else { break }
            if !body(found) {
                return .stopped
            }
            let next = NSMaxRange(found)
            guard next > searchRange.location else { break }
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        return .completed
    }

    private static func enumerateWindowedLiteralMatches(
        options: FindSearchOptions,
        in source: any FindTextSource,
        from startOffset: Int,
        body: (NSRange) -> Bool
    ) -> LiteralEnumerateResult {
        let utf16Length = source.utf16Length
        var offset = min(max(startOffset, 0), utf16Length)
        let window = effectiveLiteralWindowUTF16()
        let rightPadWanted = literalRightPadUTF16(query: options.query, matchCase: options.matchCase)
        let compare = NSString.CompareOptions(options.matchCase ? [] : [.caseInsensitive])

        while offset < utf16Length {
            if Task.isCancelled {
                return .cancelled
            }
            let plannedUnique = min(window, utf16Length - offset)
            let uniqueEnd = offset + plannedUnique
            var rightPad = min(rightPadWanted, utf16Length - uniqueEnd)
            let searchEnd = uniqueEnd + rightPad
            if searchEnd < utf16Length,
               let unit = utf16Unit(in: source, at: searchEnd), isHighSurrogate(unit),
               let next = utf16Unit(in: source, at: searchEnd + 1), isLowSurrogate(next) {
                rightPad += 1
            }

            var substrStart = offset
            var leftPad = 0
            if offset > 0, let unit = utf16Unit(in: source, at: offset), isLowSurrogate(unit) {
                substrStart = offset - 1
                leftPad = 1
            }

            let windowString = source.substring(utf16Offset: substrStart, length: leftPad + plannedUnique + rightPad)
            let ns = windowString as NSString
            if var lengths = debugLiteralWindowSubstringUTF16Lengths {
                lengths.append(ns.length)
                debugLiteralWindowSubstringUTF16Lengths = lengths
            }
            let searchLength = min(plannedUnique + rightPad, max(0, ns.length - leftPad))
            var localSearch = NSRange(location: leftPad, length: searchLength)
            while localSearch.length > 0 {
                if Task.isCancelled {
                    return .cancelled
                }
                let found = ns.range(of: options.query, options: compare, range: localSearch)
                guard found.location != NSNotFound else { break }
                let docStart = substrStart + found.location
                if docStart >= uniqueEnd {
                    break
                }
                if docStart >= offset {
                    let docRange = NSRange(location: docStart, length: found.length)
                    if !body(docRange) {
                        return .stopped
                    }
                }
                let next = NSMaxRange(found)
                guard next > localSearch.location else { break }
                localSearch = NSRange(location: next, length: NSMaxRange(localSearch) - next)
            }

            prefetchNextLiteralWindow(
                in: source,
                from: uniqueEnd,
                unique: window,
                rightPad: rightPadWanted
            )
            offset = uniqueEnd
        }
        return .completed
    }

    private static func windowedLiteralPrevious(
        options: FindSearchOptions,
        in source: any FindTextSource,
        before location: Int
    ) -> NSRange? {
        let utf16Length = source.utf16Length
        guard utf16Length > 0, location > 0 else {
            return nil
        }
        let window = effectiveLiteralWindowUTF16()
        let rightPadWanted = literalRightPadUTF16(query: options.query, matchCase: options.matchCase)
        let compare = NSString.CompareOptions(options.matchCase ? [] : [.caseInsensitive])
        var cursor = min(location, utf16Length)

        while cursor > 0 {
            if Task.isCancelled {
                return nil
            }
            let plannedUnique = min(window, cursor)
            let uniqueStart = cursor - plannedUnique
            var rightPad = min(rightPadWanted, utf16Length - cursor)
            let searchEnd = cursor + rightPad
            if searchEnd < utf16Length,
               let unit = utf16Unit(in: source, at: searchEnd), isHighSurrogate(unit),
               let next = utf16Unit(in: source, at: searchEnd + 1), isLowSurrogate(next) {
                rightPad += 1
            }

            var substrStart = uniqueStart
            var leftPad = 0
            if uniqueStart > 0, let unit = utf16Unit(in: source, at: uniqueStart), isLowSurrogate(unit) {
                substrStart = uniqueStart - 1
                leftPad = 1
            }

            let windowString = source.substring(utf16Offset: substrStart, length: leftPad + plannedUnique + rightPad)
            let ns = windowString as NSString
            let searchLength = min(plannedUnique + rightPad, max(0, ns.length - leftPad))
            var localSearch = NSRange(location: leftPad, length: searchLength)
            var last: NSRange?
            while localSearch.length > 0 {
                if Task.isCancelled {
                    return nil
                }
                let found = ns.range(of: options.query, options: compare, range: localSearch)
                guard found.location != NSNotFound else { break }
                let docStart = substrStart + found.location
                if docStart >= cursor {
                    break
                }
                if docStart >= uniqueStart, docStart < location {
                    last = NSRange(location: docStart, length: found.length)
                }
                let next = NSMaxRange(found)
                guard next > localSearch.location else { break }
                localSearch = NSRange(location: next, length: NSMaxRange(localSearch) - next)
            }
            if let last {
                return last
            }
            cursor = uniqueStart
        }
        return nil
    }

    private static func contiguousLiteralPrevious(options: FindSearchOptions, in ns: NSString, before location: Int) -> NSRange? {
        let compare = NSString.CompareOptions(options.matchCase ? [] : [.caseInsensitive])
        var last: NSRange?
        var searchRange = NSRange(location: 0, length: min(location, ns.length))
        while searchRange.length > 0 {
            if Task.isCancelled {
                return nil
            }
            let found = ns.range(of: options.query, options: compare, range: searchRange)
            guard found.location != NSNotFound else { break }
            last = found
            searchRange = NSRange(location: NSMaxRange(found), length: location - NSMaxRange(found))
        }
        return last
    }

    private static func effectiveLiteralWindowUTF16() -> Int {
        max(debugLiteralWindowUTF16 ?? literalWindowUTF16, 1)
    }

    private static func literalRightPadUTF16(query: String, matchCase: Bool) -> Int {
        if matchCase {
            return max(query.utf16.count, 1)
        }
        return literalCaseInsensitiveOverlapUTF16(query)
    }

    private static func prefetchNextLiteralWindow(
        in source: any FindTextSource,
        from offset: Int,
        unique: Int,
        rightPad: Int
    ) {
        guard let snapshot = source as? PieceTreeContentSnapshot, offset < snapshot.utf16Length else {
            return
        }
        let nextUnique = min(unique, snapshot.utf16Length - offset)
        let nextPad = min(rightPad, max(0, snapshot.utf16Length - offset - nextUnique))
        snapshot.prefetch(utf16Range: NSRange(location: offset, length: nextUnique + nextPad))
    }

    private static func utf16Unit(in source: any FindTextSource, at offset: Int) -> unichar? {
        guard offset >= 0, offset < source.utf16Length else {
            return nil
        }
        let slice = source.substring(utf16Offset: offset, length: 1)
        let ns = slice as NSString
        guard ns.length > 0 else {
            return nil
        }
        return ns.character(at: 0)
    }

    private static func isHighSurrogate(_ unit: unichar) -> Bool {
        unit >= 0xD800 && unit <= 0xDBFF
    }

    private static func isLowSurrogate(_ unit: unichar) -> Bool {
        unit >= 0xDC00 && unit <= 0xDFFF
    }

    // MARK: - Regex

    private static func regexSearch(
        options: FindSearchOptions,
        in source: any FindTextSource,
        anchorLocation: Int,
        maxHighlights: Int,
        onProgress: (@Sendable (FindSearchOutcome) -> Void)?
    ) throws -> FindSearchOutcome {
        if let ns = source.contiguousNSString {
            return try contiguousRegexSearch(
                options: options,
                in: ns as String,
                anchorLocation: anchorLocation,
                maxHighlights: maxHighlights,
                onProgress: onProgress
            )
        }
        return try windowedRegexSearch(
            options: options,
            in: source,
            anchorLocation: anchorLocation,
            maxHighlights: maxHighlights,
            onProgress: onProgress
        )
    }

    private static func contiguousRegexSearch(
        options: FindSearchOptions,
        in text: String,
        anchorLocation: Int,
        maxHighlights: Int,
        onProgress: (@Sendable (FindSearchOutcome) -> Void)?
    ) throws -> FindSearchOutcome {
        let regex = try FindRegexCache.regex(pattern: regexPattern(for: options), options: regexOptions(for: options))
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        let progress = SearchProgress(
            maxHighlights: maxHighlights,
            anchorLocation: anchorLocation,
            onProgress: onProgress
        )
        var wasCancelled = false

        regex.enumerateMatches(in: text, options: [], range: full) { result, _, stop in
            if Task.isCancelled {
                wasCancelled = true
                stop.pointee = true
                return
            }
            guard let range = result?.range, range.location != NSNotFound else { return }
            progress.add(range)
        }

        if wasCancelled {
            return .empty
        }
        if progress.matchCount == 0 {
            return .empty
        }
        if progress.currentIndex == nil {
            progress.currentIndex = 0
            progress.currentRange = regex.firstMatch(in: text, options: [], range: full)?.range
        }

        let highlights = try collectContiguousRegexHighlights(
            regex: regex,
            in: text,
            around: progress.currentIndex ?? 0,
            matchCount: progress.matchCount,
            maxHighlights: maxHighlights
        )

        return progress.completeOutcome(highlights: highlights)
    }

    private static func collectContiguousRegexHighlights(
        regex: NSRegularExpression,
        in text: String,
        around index: Int,
        matchCount: Int,
        maxHighlights: Int
    ) throws -> [NSRange] {
        let half = maxHighlights / 2
        let startIndex = max(0, min(index - half, max(0, matchCount - maxHighlights)))
        let endIndex = min(matchCount, startIndex + maxHighlights)
        let full = NSRange(location: 0, length: (text as NSString).length)

        var ranges: [NSRange] = []
        var matchIndex = 0
        regex.enumerateMatches(in: text, options: [], range: full) { result, _, stop in
            if Task.isCancelled {
                stop.pointee = true
                return
            }
            guard let range = result?.range, range.location != NSNotFound else { return }
            if matchIndex >= endIndex {
                stop.pointee = true
                return
            }
            if matchIndex >= startIndex {
                ranges.append(range)
            }
            matchIndex += 1
        }
        return ranges
    }

    private static func regexNext(
        options: FindSearchOptions,
        in source: any FindTextSource,
        after location: Int
    ) throws -> NSRange? {
        if let ns = source.contiguousNSString {
            let text = ns as String
            let regex = try FindRegexCache.regex(pattern: regexPattern(for: options), options: regexOptions(for: options))
            let start = min(max(location, 0), ns.length)
            let range = NSRange(location: start, length: ns.length - start)
            guard range.length > 0 else { return nil }
            return regex.firstMatch(in: text, options: [], range: range)?.range
        }
        return try windowedRegexNext(options: options, in: source, after: location)
    }

    private static func regexPrevious(
        options: FindSearchOptions,
        in source: any FindTextSource,
        before location: Int
    ) throws -> NSRange? {
        if let ns = source.contiguousNSString {
            let text = ns as String
            let regex = try FindRegexCache.regex(pattern: regexPattern(for: options), options: regexOptions(for: options))
            let limit = min(max(location, 0), ns.length)
            let full = NSRange(location: 0, length: limit)
            var last: NSRange?
            regex.enumerateMatches(in: text, options: [], range: full) { result, _, stop in
                if Task.isCancelled {
                    stop.pointee = true
                    return
                }
                guard let range = result?.range, range.location != NSNotFound else { return }
                last = range
            }
            return last
        }
        return try windowedRegexPrevious(options: options, in: source, before: location)
    }

    private static func regexReplaceAllMatches(
        options: FindSearchOptions,
        in source: any FindTextSource,
        replacement: String
    ) throws -> [FindReplaceMatch] {
        if let ns = source.contiguousNSString {
            return try contiguousRegexReplaceAllMatches(options: options, in: ns as String, replacement: replacement)
        }
        return try windowedRegexReplaceAllMatches(options: options, in: source, replacement: replacement)
    }

    private static func contiguousRegexReplaceAllMatches(
        options: FindSearchOptions,
        in text: String,
        replacement: String
    ) throws -> [FindReplaceMatch] {
        let regex = try FindRegexCache.regex(pattern: regexPattern(for: options), options: regexOptions(for: options))
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let parsed = ReplacementStringParser(string: replacement).parse()
        var matches: [FindReplaceMatch] = []
        var wasCancelled = false
        regex.enumerateMatches(in: text, options: [], range: full) { result, _, stop in
            if Task.isCancelled {
                wasCancelled = true
                stop.pointee = true
                return
            }
            guard let result, result.range.location != NSNotFound else { return }
            let replacementText = parsed.containsPlaceholder
                ? parsed.string(byMatching: result, in: ns)
                : replacement
            matches.append(FindReplaceMatch(range: result.range, replacementText: replacementText))
        }
        if wasCancelled {
            throw CancellationError()
        }
        return matches
    }

    // MARK: - Windowed regex

    private static func windowedRegexSearch(
        options: FindSearchOptions,
        in source: any FindTextSource,
        anchorLocation: Int,
        maxHighlights: Int,
        onProgress: (@Sendable (FindSearchOutcome) -> Void)?
    ) throws -> FindSearchOutcome {
        let regex = try FindRegexCache.regex(pattern: regexPattern(for: options), options: regexOptions(for: options))
        let progress = SearchProgress(
            maxHighlights: maxHighlights,
            anchorLocation: anchorLocation,
            onProgress: onProgress
        )
        let result = enumerateWindowedRegexMatches(regex: regex, in: source) { found, _, _ in
            progress.add(found)
            return true
        }
        if result == .cancelled {
            return .empty
        }
        if progress.matchCount == 0 {
            return .empty
        }
        progress.wrapCurrentIfNeeded()
        let highlights = collectWindowedRegexHighlights(
            regex: regex,
            in: source,
            around: progress.currentIndex ?? 0,
            matchCount: progress.matchCount,
            maxHighlights: maxHighlights
        )
        return progress.completeOutcome(highlights: highlights)
    }

    private static func collectWindowedRegexHighlights(
        regex: NSRegularExpression,
        in source: any FindTextSource,
        around index: Int,
        matchCount: Int,
        maxHighlights: Int
    ) -> [NSRange] {
        let half = maxHighlights / 2
        let startIndex = max(0, min(index - half, max(0, matchCount - maxHighlights)))
        let endIndex = min(matchCount, startIndex + maxHighlights)
        var ranges: [NSRange] = []
        var matchIndex = 0
        _ = enumerateWindowedRegexMatches(regex: regex, in: source) { found, _, _ in
            if matchIndex >= endIndex {
                return false
            }
            if matchIndex >= startIndex {
                ranges.append(found)
            }
            matchIndex += 1
            return true
        }
        return ranges
    }

    private static func windowedRegexNext(
        options: FindSearchOptions,
        in source: any FindTextSource,
        after location: Int
    ) throws -> NSRange? {
        let regex = try FindRegexCache.regex(pattern: regexPattern(for: options), options: regexOptions(for: options))
        let after = max(location, 0)
        var found: NSRange?
        _ = enumerateWindowedRegexMatches(regex: regex, in: source, from: after) { range, _, _ in
            if range.location > source.utf16Length {
                return true
            }
            if range.location >= after || (range.location == source.utf16Length && after <= source.utf16Length) {
                found = range
                return false
            }
            return true
        }
        return found
    }

    private static func windowedRegexPrevious(
        options: FindSearchOptions,
        in source: any FindTextSource,
        before location: Int
    ) throws -> NSRange? {
        let utf16Length = source.utf16Length
        guard utf16Length > 0, location > 0 else {
            return nil
        }
        let regex = try FindRegexCache.regex(pattern: regexPattern(for: options), options: regexOptions(for: options))
        let windowSize = effectiveRegexWindowUTF16()
        // Geometry only; do not clamp `before` before the accept test (wrap-around uses length + 1).
        var cursor = min(location, utf16Length)

        while cursor > 0 {
            if Task.isCancelled {
                return nil
            }
            let plannedUnique = min(windowSize, cursor)
            let uniqueStart = cursor - plannedUnique
            let geometry = makeRegexWindow(
                uniqueStart: uniqueStart,
                plannedUnique: plannedUnique,
                utf16Length: utf16Length,
                source: source
            )
            let windowString = source.substring(utf16Offset: geometry.substrStart, length: geometry.substrLength)
            let ns = windowString as NSString
            var searchRange = geometry.localSearchRange
            if NSMaxRange(searchRange) > ns.length {
                searchRange.length = max(0, ns.length - searchRange.location)
            }
            var last: NSRange?
            var wasCancelled = false
            regex.enumerateMatches(
                in: ns as String,
                options: geometry.matchingOptions,
                range: searchRange
            ) { result, _, stop in
                if Task.isCancelled {
                    wasCancelled = true
                    stop.pointee = true
                    return
                }
                guard let result, result.range.location != NSNotFound else { return }
                let docStart = geometry.substrStart + result.range.location
                if !geometry.accepts(docStart: docStart, utf16Length: utf16Length) {
                    if docStart >= geometry.uniqueEnd {
                        stop.pointee = true
                    }
                    return
                }
                let beforeCaller = docStart < location
                    || (docStart == utf16Length && location >= utf16Length)
                guard beforeCaller else { return }
                let candidate = NSRange(location: docStart, length: result.range.length)
                if let current = last {
                    if candidate.location > current.location
                        || (candidate.location == current.location && candidate.length >= current.length) {
                        last = candidate
                    }
                } else {
                    last = candidate
                }
            }
            if wasCancelled {
                return nil
            }
            if let last {
                return last
            }
            cursor = uniqueStart
        }
        return nil
    }

    private static func windowedRegexReplaceAllMatches(
        options: FindSearchOptions,
        in source: any FindTextSource,
        replacement: String
    ) throws -> [FindReplaceMatch] {
        let regex = try FindRegexCache.regex(pattern: regexPattern(for: options), options: regexOptions(for: options))
        let parsed = ReplacementStringParser(string: replacement).parse()
        var matches: [FindReplaceMatch] = []
        let result = enumerateWindowedRegexMatches(regex: regex, in: source) { range, checkingResult, window in
            let replacementText = parsed.containsPlaceholder
                ? parsed.string(byMatching: checkingResult, in: window)
                : replacement
            matches.append(FindReplaceMatch(range: range, replacementText: replacementText))
            return true
        }
        if result == .cancelled {
            throw CancellationError()
        }
        return matches
    }

    private static func windowedReplacementText(
        options: FindSearchOptions,
        in source: any FindTextSource,
        matching range: NSRange,
        replacement: String
    ) throws -> String {
        let utf16Length = source.utf16Length
        guard range.location != NSNotFound, range.location >= 0, NSMaxRange(range) <= utf16Length else {
            return replacement
        }
        let parsed = ReplacementStringParser(string: replacement).parse()
        guard parsed.containsPlaceholder else {
            return replacement
        }
        let regex = try FindRegexCache.regex(pattern: regexPattern(for: options), options: regexOptions(for: options))
        let pad = regexOverlapUTF16
        var substrStart = max(0, range.location - pad)
        var substrEnd = min(utf16Length, NSMaxRange(range) + pad)
        if substrStart > 0, let unit = utf16Unit(in: source, at: substrStart), isLowSurrogate(unit) {
            substrStart -= 1
        }
        if substrEnd < utf16Length,
           let unit = utf16Unit(in: source, at: substrEnd), isHighSurrogate(unit),
           let next = utf16Unit(in: source, at: substrEnd + 1), isLowSurrogate(next) {
            substrEnd += 1
        }
        let windowString = source.substring(utf16Offset: substrStart, length: substrEnd - substrStart)
        let ns = windowString as NSString
        let local = NSRange(location: range.location - substrStart, length: range.length)
        guard local.location >= 0, NSMaxRange(local) <= ns.length else {
            return replacement
        }
        var matchingOptions: NSRegularExpression.MatchingOptions = [.withTransparentBounds]
        if substrStart > 0 {
            matchingOptions.insert(.withoutAnchoringBounds)
        }
        guard let result = regex.firstMatch(in: ns as String, options: matchingOptions, range: local),
              result.range == local else {
            return replacement
        }
        return parsed.string(byMatching: result, in: ns)
    }

    /// Invokes `body` for each accepted regex match in document coordinates.
    /// `result` ranges are relative to `window`. `body` returns `false` to stop.
    private static func enumerateWindowedRegexMatches(
        regex: NSRegularExpression,
        in source: any FindTextSource,
        from startOffset: Int = 0,
        body: (NSRange, NSTextCheckingResult, NSString) -> Bool
    ) -> LiteralEnumerateResult {
        let utf16Length = source.utf16Length
        let windowSize = effectiveRegexWindowUTF16()
        var offset = min(max(startOffset, 0), utf16Length)

        while offset < utf16Length {
            if Task.isCancelled {
                return .cancelled
            }
            let plannedUnique = min(windowSize, utf16Length - offset)
            let geometry = makeRegexWindow(
                uniqueStart: offset,
                plannedUnique: plannedUnique,
                utf16Length: utf16Length,
                source: source
            )
            let windowString = source.substring(utf16Offset: geometry.substrStart, length: geometry.substrLength)
            let ns = windowString as NSString
            var searchRange = geometry.localSearchRange
            if NSMaxRange(searchRange) > ns.length {
                searchRange.length = max(0, ns.length - searchRange.location)
            }
            var stopped = false
            var cancelled = false
            regex.enumerateMatches(
                in: ns as String,
                options: geometry.matchingOptions,
                range: searchRange
            ) { result, _, stop in
                if Task.isCancelled {
                    cancelled = true
                    stop.pointee = true
                    return
                }
                guard let result, result.range.location != NSNotFound else { return }
                let docStart = geometry.substrStart + result.range.location
                if !geometry.accepts(docStart: docStart, utf16Length: utf16Length) {
                    if docStart >= geometry.uniqueEnd {
                        stop.pointee = true
                    }
                    return
                }
                let docRange = NSRange(location: docStart, length: result.range.length)
                if !body(docRange, result, ns) {
                    stopped = true
                    stop.pointee = true
                }
            }
            if cancelled {
                return .cancelled
            }
            if stopped {
                return .stopped
            }
            prefetchNextRegexWindow(in: source, from: geometry.uniqueEnd, unique: windowSize)
            offset = geometry.uniqueEnd
        }
        return .completed
    }

    private struct RegexWindowGeometry {
        let uniqueStart: Int
        let plannedUnique: Int
        let uniqueEnd: Int
        let includesEOF: Bool
        let leftPad: Int
        let rightPad: Int
        let substrStart: Int
        let substrLength: Int
        let localSearchRange: NSRange
        let matchingOptions: NSRegularExpression.MatchingOptions

        func accepts(docStart: Int, utf16Length: Int) -> Bool {
            if uniqueStart <= docStart && docStart < uniqueEnd {
                return true
            }
            return includesEOF && docStart == utf16Length
        }
    }

    private static func makeRegexWindow(
        uniqueStart: Int,
        plannedUnique: Int,
        utf16Length: Int,
        source: any FindTextSource
    ) -> RegexWindowGeometry {
        let uniqueEnd = uniqueStart + plannedUnique
        let includesEOF = uniqueEnd == utf16Length
        let leftPad = regexLeftPad(uniqueStart: uniqueStart, source: source)
        var rightPad = includesEOF ? 0 : min(regexOverlapUTF16, utf16Length - uniqueEnd)
        let searchEnd = uniqueEnd + rightPad
        if searchEnd < utf16Length,
           let unit = utf16Unit(in: source, at: searchEnd), isHighSurrogate(unit),
           let next = utf16Unit(in: source, at: searchEnd + 1), isLowSurrogate(next) {
            rightPad += 1
        }
        let matchingOptions: NSRegularExpression.MatchingOptions = uniqueStart > 0
            ? [.withTransparentBounds, .withoutAnchoringBounds]
            : []
        return RegexWindowGeometry(
            uniqueStart: uniqueStart,
            plannedUnique: plannedUnique,
            uniqueEnd: uniqueEnd,
            includesEOF: includesEOF,
            leftPad: leftPad,
            rightPad: rightPad,
            substrStart: uniqueStart - leftPad,
            substrLength: leftPad + plannedUnique + rightPad,
            localSearchRange: NSRange(location: leftPad, length: plannedUnique + rightPad),
            matchingOptions: matchingOptions
        )
    }

    /// Left pad starts at ``regexOverlapUTF16`` (or to document start), then grows to include the
    /// preceding line delimiter and a leading-low-surrogate snap. Not part of the matcher region.
    private static func regexLeftPad(uniqueStart: Int, source: any FindTextSource) -> Int {
        guard uniqueStart > 0 else {
            return 0
        }
        var leftPad = min(regexOverlapUTF16, uniqueStart)
        let start = uniqueStart - leftPad
        if start > 0, let unit = utf16Unit(in: source, at: start - 1) {
            if unit == 0x000A {
                leftPad += 1
                if start - 1 > 0, let prev = utf16Unit(in: source, at: start - 2), prev == 0x000D {
                    leftPad += 1
                }
            } else if unit == 0x000D || unit == 0x0085 || unit == 0x2028 || unit == 0x2029 {
                leftPad += 1
            }
        }
        let snappedStart = uniqueStart - leftPad
        if snappedStart > 0, let unit = utf16Unit(in: source, at: snappedStart), isLowSurrogate(unit) {
            leftPad += 1
        }
        return leftPad
    }

    private static func prefetchNextRegexWindow(
        in source: any FindTextSource,
        from offset: Int,
        unique: Int
    ) {
        guard let snapshot = source as? PieceTreeContentSnapshot, offset < snapshot.utf16Length else {
            return
        }
        let nextUnique = min(unique, snapshot.utf16Length - offset)
        let nextPad = min(regexOverlapUTF16, max(0, snapshot.utf16Length - offset - nextUnique))
        snapshot.prefetch(utf16Range: NSRange(location: offset, length: nextUnique + nextPad))
    }

    private static func effectiveRegexWindowUTF16() -> Int {
        max(debugRegexWindowUTF16 ?? regexWindowUTF16, 1)
    }

    private static func regexPattern(for options: FindSearchOptions) -> String {
        if options.useRegex {
            return options.query
        }
        var escaped = NSRegularExpression.escapedPattern(for: options.query)
        if options.wholeWord {
            escaped = "\\b\(escaped)\\b"
        }
        return escaped
    }

    private static func regexOptions(for options: FindSearchOptions) -> NSRegularExpression.Options {
        var regexOptions: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.matchCase {
            regexOptions.insert(.caseInsensitive)
        }
        return regexOptions
    }
}

/// Accumulates matches during a scan and emits incomplete ``FindSearchOutcome`` snapshots so the
/// find panel can fill in as the search runs. Progress fires on the first match and then at most
/// every ``progressInterval``.
private final class SearchProgress {
    static let progressInterval: CFAbsoluteTime = 0.05

    let maxHighlights: Int
    let anchorLocation: Int
    let onProgress: (@Sendable (FindSearchOutcome) -> Void)?
    var matchCount = 0
    var currentIndex: Int?
    var currentRange: NSRange?
    var firstRange: NSRange?
    private var progressHighlights: [NSRange] = []
    private var lastProgressTime = CFAbsoluteTimeGetCurrent()

    init(
        maxHighlights: Int,
        anchorLocation: Int,
        onProgress: (@Sendable (FindSearchOutcome) -> Void)?
    ) {
        self.maxHighlights = maxHighlights
        self.anchorLocation = anchorLocation
        self.onProgress = onProgress
    }

    func add(_ found: NSRange) {
        if firstRange == nil {
            firstRange = found
        }
        let index = matchCount
        matchCount += 1
        if currentIndex == nil, found.location >= anchorLocation {
            currentIndex = index
            currentRange = found
        }
        if progressHighlights.count < maxHighlights {
            progressHighlights.append(found)
        }
        emitProgressIfNeeded(force: matchCount == 1)
    }

    func wrapCurrentIfNeeded() {
        if currentIndex == nil {
            currentIndex = 0
            currentRange = firstRange
        }
    }

    func completeOutcome(highlights: [NSRange]) -> FindSearchOutcome {
        FindSearchOutcome(
            matchCount: matchCount,
            currentIndex: currentIndex,
            currentRange: currentRange,
            highlightRanges: highlights,
            errorMessage: nil,
            isComplete: true
        )
    }

    private func emitProgressIfNeeded(force: Bool) {
        guard let onProgress, matchCount > 0 else {
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        if !force, now - lastProgressTime < Self.progressInterval {
            return
        }
        lastProgressTime = now
        var highlights = progressHighlights
        if let currentRange, !highlights.contains(where: { $0 == currentRange }) {
            if highlights.count >= maxHighlights, !highlights.isEmpty {
                highlights[highlights.count - 1] = currentRange
            } else {
                highlights.append(currentRange)
            }
        }
        onProgress(FindSearchOutcome(
            matchCount: matchCount,
            currentIndex: currentIndex ?? 0,
            currentRange: currentRange ?? firstRange,
            highlightRanges: highlights,
            errorMessage: nil,
            isComplete: false
        ))
    }
}

/// `NSRegularExpression` compile cache backing ``FindSearchEngine``'s regex/whole-word paths, so
/// repeated per-keystroke searches don't recompile the same pattern.
enum FindRegexCache {
    private struct Key: Hashable {
        let pattern: String
        let optionsRaw: UInt
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: NSRegularExpression] = [:]
    private static let maxEntries = 32

    static func regex(pattern: String, options: NSRegularExpression.Options) throws -> NSRegularExpression {
        let key = Key(pattern: pattern, optionsRaw: options.rawValue)
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let compiled = try NSRegularExpression(pattern: pattern, options: options)
        lock.lock()
        if cache[key] == nil {
            if cache.count >= maxEntries {
                cache.removeAll(keepingCapacity: true)
            }
            cache[key] = compiled
        }
        let result = cache[key] ?? compiled
        lock.unlock()
        return result
    }
}
