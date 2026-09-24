import Foundation

/// IntelliJ-style completion matching: case-insensitive prefix, camel-hump (`gN` → `getName`,
/// `ArrLi` → `ArrayList`, `aL` → `ArrayList`), and matching from a later word start
/// (`Name` → `getName`). Anything else, such as an arbitrary substring, does not match.
public enum CompletionMatcher {
    /// How well a candidate matched; ordered worst to best.
    public enum Tier: Int, Comparable, Sendable {
        /// The query was empty: everything matches equally.
        case any = 0
        /// Matched starting at a later word start, e.g. `Name` in `getName`.
        case wordStart = 1
        /// Camel-hump match anchored at the first character.
        case camelHump = 2
        /// Case-insensitive prefix.
        case prefix = 3
        /// Case-insensitive equality.
        case exactIgnoringCase = 4
        /// Exact equality.
        case exact = 5

        public static func < (lhs: Tier, rhs: Tier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public struct Match: Sendable, Equatable {
        public let tier: Tier
        /// Whether the first query character has the same case as the candidate's.
        public let firstCharacterCaseMatches: Bool
        /// UTF-16 offsets of the matched candidate characters, ascending.
        public let matchedOffsets: [Int]

        /// A match anchored at the first character. A later word start (`Name` in `getName`) is not.
        public var isStartMatch: Bool {
            switch tier {
            case .camelHump, .prefix, .exactIgnoringCase, .exact: return true
            case .any, .wordStart: return false
            }
        }

        /// Higher is a tighter match, used to gate non-imported classes against the best in-scope item.
        public var degree: Int {
            let base: Int
            switch tier {
            case .exact: base = 10_000
            case .exactIgnoringCase: base = 8_000
            case .prefix: base = 5_000
            case .camelHump: base = 2_000
            case .wordStart: base = 100
            case .any: base = 0
            }
            return base + matchedOffsets.count * 10 + (firstCharacterCaseMatches ? 5 : 0)
        }

        /// Contiguous matched runs, for highlighting.
        public var matchedRanges: [NSRange] {
            var ranges: [NSRange] = []
            for offset in matchedOffsets {
                if let last = ranges.last, last.upperBound == offset {
                    ranges[ranges.count - 1] = NSRange(location: last.location, length: last.length + 1)
                } else {
                    ranges.append(NSRange(location: offset, length: 1))
                }
            }
            return ranges
        }
    }

    /// Match `query` against `candidate`. Returns `nil` when it doesn't match.
    public static func match(_ query: String, in candidate: String) -> Match? {
        let q = Array(query.utf16)
        let c = Array(candidate.utf16)
        guard !q.isEmpty else {
            return Match(tier: .any, firstCharacterCaseMatches: true, matchedOffsets: [])
        }
        guard q.count <= c.count else { return nil }
        let firstCaseMatches = q[0] == c[0]

        if q == c {
            return Match(tier: .exact, firstCharacterCaseMatches: true, matchedOffsets: Array(0..<c.count))
        }
        let lowerQ = q.map(lower)
        let lowerC = c.map(lower)
        if lowerQ.count == lowerC.count, lowerQ == lowerC {
            // Only a whole-word match when the first letter's case agrees (`users` for `Users`
            // is not the same name, it is a prefix match like any other).
            return Match(tier: firstCaseMatches ? .exactIgnoringCase : .prefix, firstCharacterCaseMatches: firstCaseMatches, matchedOffsets: Array(0..<c.count))
        }
        if Array(lowerC.prefix(lowerQ.count)) == lowerQ {
            return Match(tier: .prefix, firstCharacterCaseMatches: firstCaseMatches, matchedOffsets: Array(0..<q.count))
        }

        let starts = wordStarts(c)
        if lowerQ[0] == lowerC[0], let offsets = humpMatch(query: q, lowerQuery: lowerQ, candidate: c, lowerCandidate: lowerC, starts: starts, from: 0) {
            return Match(tier: .camelHump, firstCharacterCaseMatches: firstCaseMatches, matchedOffsets: offsets)
        }
        for start in starts where start > 0 && lowerC[start] == lowerQ[0] {
            if let offsets = humpMatch(query: q, lowerQuery: lowerQ, candidate: c, lowerCandidate: lowerC, starts: starts, from: start) {
                return Match(tier: .wordStart, firstCharacterCaseMatches: q[0] == c[start], matchedOffsets: offsets)
            }
        }
        return nil
    }

    /// Whether `candidate` matches `query` at all.
    public static func matches(_ query: String, _ candidate: String) -> Bool {
        match(query, in: candidate) != nil
    }

    /// Cheap pre-filter for providers with large candidate sets: a candidate can only match when
    /// its first character or one of its word starts equals the query's first character.
    public static func couldMatch(_ query: String, _ candidate: String) -> Bool {
        guard let first = query.utf16.first.map(lower) else { return true }
        let c = Array(candidate.utf16)
        return wordStarts(c).contains { lower(c[$0]) == first }
    }

    // MARK: - Internals

    /// Anchors query[0] at `from`, then each following query character either continues the
    /// current run or jumps to a later word start. Prefers continuing (greedy), backtracking when
    /// that fails. An uppercase query character must land on a word start unless it continues a
    /// run whose candidate character is also uppercase.
    private static func humpMatch(
        query: [UInt16], lowerQuery: [UInt16], candidate: [UInt16], lowerCandidate: [UInt16], starts: [Int], from: Int
    ) -> [Int]? {
        var isStart = [Bool](repeating: false, count: candidate.count)
        for start in starts { isStart[start] = true }
        var result: [Int] = [from]

        func solve(_ qi: Int, _ last: Int) -> Bool {
            if qi == query.count { return true }
            let wanted = lowerQuery[qi]
            let queryIsUpper = isUpper(query[qi])
            // Continue the run.
            let next = last + 1
            if next < candidate.count, lowerCandidate[next] == wanted,
               !queryIsUpper || isStart[next] || isUpper(candidate[next]) {
                result.append(next)
                if solve(qi + 1, next) { return true }
                result.removeLast()
            }
            // Jump to a later word start.
            var index = last + 2
            while index < candidate.count {
                if isStart[index], lowerCandidate[index] == wanted {
                    result.append(index)
                    if solve(qi + 1, index) { return true }
                    result.removeLast()
                }
                index += 1
            }
            return false
        }
        return solve(1, from) ? result : nil
    }

    /// Word starts: index 0, an uppercase letter after a lowercase letter or digit, the last
    /// uppercase letter of an acronym followed by lowercase (`C` in `URLConnection`), a letter
    /// or digit after `_`, `$`, `.`, `-` or a space, and a digit run after letters.
    static func wordStarts(_ c: [UInt16]) -> [Int] {
        guard !c.isEmpty else { return [] }
        var starts = [0]
        for i in 1..<c.count {
            let previous = c[i - 1]
            let current = c[i]
            if isSeparator(previous), !isSeparator(current) {
                starts.append(i)
            } else if isUpper(current), isLower(previous) || isDigit(previous) {
                starts.append(i)
            } else if isUpper(current), isUpper(previous), i + 1 < c.count, isLower(c[i + 1]) {
                starts.append(i)
            } else if isDigit(current), !isDigit(previous), !isSeparator(previous) {
                starts.append(i)
            }
        }
        return starts
    }

    private static func lower(_ unit: UInt16) -> UInt16 {
        (65...90).contains(unit) ? unit + 32 : unit
    }

    private static func isUpper(_ unit: UInt16) -> Bool {
        (65...90).contains(unit)
    }

    private static func isLower(_ unit: UInt16) -> Bool {
        (97...122).contains(unit)
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        (48...57).contains(unit)
    }

    private static func isSeparator(_ unit: UInt16) -> Bool {
        unit == 95 || unit == 36 || unit == 46 || unit == 45 || unit == 32 // _ $ . - space
    }
}
