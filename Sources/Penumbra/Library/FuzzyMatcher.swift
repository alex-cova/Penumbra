import Foundation

/// Sublime-style fuzzy scoring, useful for building quick-open pickers, command palettes,
/// and similar filtered-list UI on top of Penumbra.
public enum FuzzyMatcher {
    public struct Match: Sendable, Equatable {
        public let score: Int
        public let matchedIndices: [Int]
    }

    /// Higher is better. `nil` means no match.
    public static func match(query: String, in candidate: String) -> Match? {
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        guard !q.isEmpty else {
            return Match(score: 0, matchedIndices: [])
        }
        guard !c.isEmpty else { return nil }

        var qi = 0
        var indices: [Int] = []
        indices.reserveCapacity(q.count)
        var score = 0
        var lastMatch = -1
        var consecutive = 0

        for (ci, ch) in c.enumerated() {
            guard qi < q.count else { break }
            if ch == q[qi] {
                indices.append(ci)
                if lastMatch == ci - 1 {
                    consecutive += 1
                    score += 10 + consecutive * 5
                } else {
                    consecutive = 0
                    score += 10
                }
                // Prefer matches near the start / after separators.
                if ci == 0 || isSeparator(c[ci - 1]) {
                    score += 15
                }
                lastMatch = ci
                qi += 1
            }
        }

        guard qi == q.count else { return nil }
        // Prefer shorter candidates.
        score -= max(0, c.count - q.count)
        return Match(score: score, matchedIndices: indices)
    }

    public static func ranked<T>(
        query: String,
        items: [T],
        key: (T) -> String,
        limit: Int = 50
    ) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(items.prefix(limit))
        }

        var scored: [(Int, Int, T)] = []
        scored.reserveCapacity(min(items.count, limit * 2))
        for (index, item) in items.enumerated() {
            if let match = match(query: trimmed, in: key(item)) {
                scored.append((match.score, index, item))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
            return lhs.1 < rhs.1
        }
        return scored.prefix(limit).map(\.2)
    }

    /// Like ``ranked(query:items:key:limit:)`` but also returns each surviving item's
    /// ``Match`` — needed to highlight the matched characters in a picker row. An empty query
    /// returns the first `limit` items each with an empty match.
    public static func rankedWithMatches<T>(
        query: String,
        items: [T],
        key: (T) -> String,
        limit: Int = 50
    ) -> [(item: T, match: Match)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return items.prefix(limit).map { ($0, Match(score: 0, matchedIndices: [])) }
        }

        var scored: [(score: Int, index: Int, item: T, match: Match)] = []
        scored.reserveCapacity(min(items.count, limit * 2))
        for (index, item) in items.enumerated() {
            if let match = match(query: trimmed, in: key(item)) {
                scored.append((match.score, index, item, match))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }
        return scored.prefix(limit).map { ($0.item, $0.match) }
    }

    private static func isSeparator(_ ch: Character) -> Bool {
        ch == "/" || ch == "." || ch == "_" || ch == "-" || ch == " "
    }
}
