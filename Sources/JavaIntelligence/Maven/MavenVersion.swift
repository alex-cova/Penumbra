import Foundation

/// Maven version order and version ranges, enough to pick the highest artifact present in a local
/// repository. Qualifiers follow Maven's order: `alpha` < `beta` < `milestone` < `rc` < `snapshot`
/// < a release < `sp`.
enum MavenVersion {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = parsed(lhs)
        let right = parsed(rhs)
        let count = max(left.numbers.count, right.numbers.count)
        for index in 0..<count {
            let a = index < left.numbers.count ? left.numbers[index] : 0
            let b = index < right.numbers.count ? right.numbers[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        if left.qualifier != right.qualifier {
            return left.qualifier < right.qualifier ? .orderedAscending : .orderedDescending
        }
        return compareRest(left.rest, right.rest)
    }

    /// `sp1` is qualifier `sp` and rest `1`. An empty rest sorts below a numbered one.
    private static func compareRest(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        if lhs.isEmpty { return .orderedAscending }
        if rhs.isEmpty { return .orderedDescending }
        let left = lhs.split(separator: "-").map(String.init)
        let right = rhs.split(separator: "-").map(String.init)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : ""
            let b = index < right.count ? right[index] : ""
            if a == b { continue }
            if let ai = Int(a), let bi = Int(b), ai != bi {
                return ai < bi ? .orderedAscending : .orderedDescending
            }
            if a.isEmpty { return .orderedAscending }
            if b.isEmpty { return .orderedDescending }
            return a.compare(b)
        }
        return .orderedSame
    }

    /// `version` satisfies `range`. A range is `[1,2)`, `(1,2]`, `[1,)`, or several of those
    /// separated by `],[`. A plain version matches only itself.
    static func satisfies(_ version: String, range: String) -> Bool {
        let trimmed = range.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("[") || trimmed.contains("(") else {
            return compare(version, trimmed) == .orderedSame
        }
        for part in splitRanges(trimmed) {
            if satisfiesOne(version, range: part) { return true }
        }
        return false
    }

    static func highest(among versions: [String], matching range: String) -> String? {
        versions.filter { satisfies($0, range: range) }.max { compare($0, $1) == .orderedAscending }
    }

    private static func splitRanges(_ range: String) -> [String] {
        range.replacingOccurrences(of: "],", with: "]|").replacingOccurrences(of: "),", with: ")|")
            .split(separator: "|").map(String.init)
    }

    private static func satisfiesOne(_ version: String, range: String) -> Bool {
        guard let open = range.first, let close = range.last, "[]()".contains(open), "[]()".contains(close) else {
            return compare(version, range) == .orderedSame
        }
        let body = range.dropFirst().dropLast()
        let parts = body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let lower = parts.first ?? ""
        let upper = parts.count > 1 ? parts[1] : ""
        if !lower.isEmpty {
            let order = compare(version, lower)
            if open == "[" ? order == .orderedAscending : order != .orderedDescending { return false }
        }
        if !upper.isEmpty {
            let order = compare(version, upper)
            if close == "]" ? order == .orderedDescending : order != .orderedAscending { return false }
        }
        return true
    }

    /// A missing qualifier sorts as a release, which is above `snapshot` and below `sp`.
    private static let qualifiers: [String: Int] = [
        "alpha": -5, "a": -5,
        "beta": -4, "b": -4,
        "milestone": -3, "m": -3,
        "rc": -2, "cr": -2,
        "snapshot": -1,
        "ga": 0, "final": 0, "release": 0,
        "sp": 1
    ]

    private struct Parsed {
        var numbers: [Int]
        var qualifier: Int
        var rest: String
    }

    private static func parsed(_ version: String) -> Parsed {
        let pieces = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let numbers = pieces[0].split(separator: ".").compactMap { Int($0) }
        guard pieces.count > 1 else { return Parsed(numbers: numbers, qualifier: 0, rest: "") }
        let tail = pieces[1]
        let qualifierName = tail.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
        let after = tail.split(separator: "-").dropFirst().joined(separator: "-")
        if let rank = qualifiers[qualifierName] {
            return Parsed(numbers: numbers, qualifier: rank, rest: after)
        }
        if let split = splitKnownQualifier(qualifierName) {
            let rest = after.isEmpty ? split.remainder : split.remainder + "-" + after
            return Parsed(numbers: numbers, qualifier: split.rank, rest: rest)
        }
        if Int(qualifierName) != nil {
            return Parsed(numbers: numbers, qualifier: -1, rest: tail)
        }
        return Parsed(numbers: numbers, qualifier: -1, rest: tail.lowercased())
    }

    /// `sp1` and `alpha2` are a known qualifier plus a number, the way Maven tokenizes them.
    private static func splitKnownQualifier(_ token: String) -> (rank: Int, remainder: String)? {
        for name in qualifiers.keys.sorted(by: { $0.count > $1.count }) where token.hasPrefix(name) && token.count > name.count {
            let rest = String(token.dropFirst(name.count))
            if rest.allSatisfy(\.isNumber), let rank = qualifiers[name] {
                return (rank, rest)
            }
        }
        return nil
    }
}
