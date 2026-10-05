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

    /// The tier ``match(_:in:)`` would report, without building matched offsets.
    ///
    /// Class-name completion ranks by tier and decodes stubs only for the names it keeps, so it
    /// never needs the offset arrays `match` allocates per candidate. ASCII names (every ordinary
    /// Java identifier) stay on the stack; anything else delegates to `match`.
    public static func tier(_ query: String, in candidate: String) -> Tier? {
        if query.isEmpty { return .any }
        if query.utf8.contains(where: { $0 >= 128 }) {
            return match(query, in: candidate)?.tier
        }
        // `withUTF8` may make the storage contiguous, so the copies have to be mutable. A non-ASCII
        // byte in the candidate is handled only if the ASCII path actually reads it; a prefix
        // decision does not depend on bytes after the query.
        var queryUTF8 = query
        var candidateUTF8 = candidate
        let scanned = queryUTF8.withUTF8 { queryBytes in
            candidateUTF8.withUTF8 { candidateBytes -> (Tier?, Bool) in
                var fallback = false
                let tier = asciiTier(queryBytes, candidateBytes, fallback: &fallback)
                return (tier, fallback)
            }
        }
        if scanned.1 { return match(query, in: candidate)?.tier }
        return scanned.0
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

    /// Same decisions as ``match(_:in:)`` for ASCII, which is one UTF-16 unit per byte.
    /// Sets `fallback` when a byte at or above 128 is read; the caller then uses ``match(_:in:)``.
    private static func asciiTier(
        _ q: UnsafeBufferPointer<UInt8>, _ c: UnsafeBufferPointer<UInt8>, fallback: inout Bool
    ) -> Tier? {
        if q.count > c.count || q.isEmpty { return q.isEmpty ? .any : nil }
        // One character is the first keystroke. It is a prefix when the name starts with it, and a
        // later word start otherwise — never a camel-hump, because a single character at index 0
        // is the prefix tier.
        if q.count == 1 {
            if q[0] >= 128 { fallback = true; return nil }
            let wanted = asciiLower(q[0])
            if c.isEmpty { return nil }
            if c[0] >= 128 { fallback = true; return nil }
            if c.count == 1 {
                if q[0] == c[0] { return .exact }
                return asciiLower(c[0]) == wanted ? .prefix : nil
            }
            if asciiLower(c[0]) == wanted { return .prefix }
            for index in 1..<c.count {
                if !isAsciiWordStart(c, index, fallback: &fallback) { continue }
                if fallback { return nil }
                if c[index] >= 128 { fallback = true; return nil }
                if asciiLower(c[index]) == wanted { return .wordStart }
            }
            return nil
        }
        if q.count == c.count {
            var identical = true
            for index in 0..<q.count {
                if q[index] >= 128 || c[index] >= 128 { fallback = true; return nil }
                if q[index] != c[index] { identical = false }
            }
            if identical { return .exact }
            var sameLower = true
            for index in 0..<q.count where asciiLower(q[index]) != asciiLower(c[index]) {
                sameLower = false
                break
            }
            if sameLower { return q[0] == c[0] ? .exactIgnoringCase : .prefix }
        } else {
            var prefix = true
            for index in 0..<q.count {
                if q[index] >= 128 || c[index] >= 128 { fallback = true; return nil }
                if asciiLower(q[index]) != asciiLower(c[index]) { prefix = false; break }
            }
            if prefix { return .prefix }
        }
        if q[0] >= 128 || c[0] >= 128 { fallback = true; return nil }
        if asciiLower(q[0]) == asciiLower(c[0]), asciiHumpSucceeds(q, c, from: 0, fallback: &fallback) { return .camelHump }
        if fallback { return nil }
        var index = 1
        while index < c.count {
            if isAsciiWordStart(c, index, fallback: &fallback),
               !fallback,
               c[index] < 128,
               asciiLower(c[index]) == asciiLower(q[0]),
               asciiHumpSucceeds(q, c, from: index, fallback: &fallback) {
                return .wordStart
            }
            if fallback { return nil }
            index += 1
        }
        return nil
    }

    /// ``humpMatch`` without the offset list: success is the only result the tier needs.
    private static func asciiHumpSucceeds(
        _ query: UnsafeBufferPointer<UInt8>, _ candidate: UnsafeBufferPointer<UInt8>, from: Int, fallback: inout Bool
    ) -> Bool {
        func solve(_ qi: Int, _ last: Int) -> Bool {
            if qi == query.count { return true }
            if query[qi] >= 128 { fallback = true; return false }
            let wanted = asciiLower(query[qi])
            let queryIsUpper = isUpper(UInt16(query[qi]))
            let next = last + 1
            if next < candidate.count {
                if candidate[next] >= 128 { fallback = true; return false }
                if asciiLower(candidate[next]) == wanted,
                   !queryIsUpper || isAsciiWordStart(candidate, next, fallback: &fallback) || isUpper(UInt16(candidate[next])) {
                    if fallback { return false }
                    if solve(qi + 1, next) { return true }
                }
            }
            var index = last + 2
            while index < candidate.count {
                if isAsciiWordStart(candidate, index, fallback: &fallback) {
                    if fallback { return false }
                    if candidate[index] >= 128 { fallback = true; return false }
                    if asciiLower(candidate[index]) == wanted {
                        if solve(qi + 1, index) { return true }
                    }
                }
                if fallback { return false }
                index += 1
            }
            return false
        }
        return solve(1, from)
    }

    /// ``wordStarts(_:)`` for one ASCII byte. Index 0 is a word start; callers pass `i > 0`.
    private static func isAsciiWordStart(_ c: UnsafeBufferPointer<UInt8>, _ i: Int, fallback: inout Bool) -> Bool {
        guard i > 0, i < c.count else { return false }
        let previous = c[i - 1]
        let current = c[i]
        if previous >= 128 || current >= 128 { fallback = true; return false }
        if isSeparator(UInt16(previous)), !isSeparator(UInt16(current)) { return true }
        if isUpper(UInt16(current)), isLower(UInt16(previous)) || isDigit(UInt16(previous)) { return true }
        if isUpper(UInt16(current)), isUpper(UInt16(previous)), i + 1 < c.count {
            if c[i + 1] >= 128 { fallback = true; return false }
            if isLower(UInt16(c[i + 1])) { return true }
        }
        if isDigit(UInt16(current)), !isDigit(UInt16(previous)), !isSeparator(UInt16(previous)) { return true }
        return false
    }

    private static func asciiLower(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte &+ 32 : byte
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
