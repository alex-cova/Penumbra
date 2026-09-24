import Foundation

/// Default ranker, ordered like IntelliJ's completion list:
///
/// 1. match tier from ``CompletionMatcher`` (exact > prefix > camel-hump > word start);
/// 2. `preselect`, then provider `priority` (locals over members over inherited members…);
/// 3. recently accepted items;
/// 4. kind weight;
/// 5. shorter label, then alphabetical, so equal items keep a stable order.
///
/// Items that don't match the prefix at all are dropped.
public struct DefaultRanker: Ranker {
    public let recency: CompletionRecency

    public init(recency: CompletionRecency = CompletionRecency()) {
        self.recency = recency
    }

    public func rank(items: [CompletionItem], context: CompletionContext) async -> [RankedCompletionItem] {
        rankSynchronously(items: items, prefix: context.prefix)
    }

    /// Ranking without the async hop, used when re-filtering an open popup on every keystroke.
    public func rankSynchronously(items: [CompletionItem], prefix: String) -> [RankedCompletionItem] {
        let recent = recency.snapshot()
        var scored: [(RankedCompletionItem, CompletionMatcher.Match)] = []
        scored.reserveCapacity(items.count)
        for item in items {
            guard let match = CompletionMatcher.match(prefix, in: item.matchText) else { continue }
            let score = Self.score(item: item, match: match, recentRank: recent[Self.recencyKey(item)])
            scored.append((RankedCompletionItem(item: item, score: score), match))
        }
        scored.sort { lhs, rhs in
            if lhs.0.score != rhs.0.score { return lhs.0.score > rhs.0.score }
            let lhsLabel = lhs.0.item.label, rhsLabel = rhs.0.item.label
            if lhsLabel.count != rhsLabel.count { return lhsLabel.count < rhsLabel.count }
            if lhsLabel != rhsLabel { return lhsLabel < rhsLabel }
            return (lhs.0.item.labelDetail ?? "") < (rhs.0.item.labelDetail ?? "")
        }
        // Middle matches (a later word start) stay out while a short list of start matches is
        // already showing, so they don't crowd the top. With no start matches, or more than ten,
        // they are included.
        let startCount = scored.filter { $0.1.tier >= .camelHump }.count
        let visible = (startCount > 0 && startCount <= 10) ? scored.filter { $0.1.tier != .wordStart } : scored
        return visible.map(\.0)
    }

    /// Scores are always positive for matching items: the tier dominates (100 apart), and
    /// priority/recency/kind only order items within one tier.
    static func score(item: CompletionItem, match: CompletionMatcher.Match, recentRank: Int?) -> Double {
        var score = 1000 + Double(match.tier.rawValue) * 100
        // IntelliJ matches the first letter's case: `UserS` means `UserService`, not a local `users`.
        if match.firstCharacterCaseMatches { score += 12 }
        if item.preselect { score += 20 }
        score += max(-40, min(40, item.priority * 4))
        if let recentRank { score += max(0, 3 - Double(recentRank) * 0.1) }
        score += kindWeight(item.kind)
        return score
    }

    static func recencyKey(_ item: CompletionItem) -> String {
        "\(item.label)|\(item.labelDetail ?? "")|\(item.detail ?? "")"
    }

    static func kindWeight(_ kind: CompletionItemKind) -> Double {
        switch kind {
        case .variable:
            return 0.6
        case .field, .property, .enumMember:
            return 0.5
        case .method, .function, .constructor:
            return 0.4
        case .type, .class, .interface, .enum, .annotation:
            return 0.3
        case .keyword:
            return 0.2
        case .snippet, .module, .package, .file:
            return 0.1
        case .text:
            return 0.0
        }
    }
}

/// Most-recently-accepted completions, used to lift items the user keeps picking.
public final class CompletionRecency: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []
    private let capacity: Int

    public init(capacity: Int = 30) {
        self.capacity = capacity
    }

    public func record(_ item: CompletionItem) {
        let key = DefaultRanker.recencyKey(item)
        lock.lock()
        defer { lock.unlock() }
        keys.removeAll { $0 == key }
        keys.insert(key, at: 0)
        if keys.count > capacity {
            keys.removeLast(keys.count - capacity)
        }
    }

    /// Key → rank (0 is the most recent).
    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: Int] = [:]
        for (rank, key) in keys.enumerated() {
            result[key] = rank
        }
        return result
    }
}
