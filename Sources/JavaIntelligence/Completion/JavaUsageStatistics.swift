import Foundation

/// How much the project uses each name, for ranking (F18). The count is the number of project files
/// that mention an identifier: a document frequency, not an occurrence count, which is what the
/// persistent name index (`JavaNameIndex`) stores and answers in a dictionary lookup.
///
/// Project-local and recomputed from the files on disk: nothing is collected from the user's typing
/// and nothing is persisted beyond the name index that already exists, so there is no telemetry or
/// cross-session profile to account for.
public protocol JavaUsageStatisticsSource: Sendable {
    /// For each of `identifiers` that appears in the project, the number of files that mention it.
    /// Identifiers that do not appear may be left out.
    func fileCounts(ofIdentifiers identifiers: [String]) async -> [String: Int]
}

/// The counts for the classes one request is about, and how they turn into a ranking nudge.
struct JavaUsageProfile: Sendable {
    static let empty = JavaUsageProfile(fileCounts: [:])

    /// Simple name → files mentioning it.
    let fileCounts: [String: Int]

    var isEmpty: Bool { fileCounts.isEmpty }

    /// Files that use the class, not counting its own declaring file: a project class always
    /// mentions itself, which says nothing about whether anyone uses it.
    func usage(of stub: JavaClassStub) -> Int {
        let mentions = fileCounts[stub.simpleName] ?? 0
        if case .source = stub.origin { return max(0, mentions - 1) }
        return mentions
    }

    /// Where the bonus stops growing: at this many files a class counts as fully "in use".
    static let saturation = 64.0

    /// 0 for an unused class, `cap` from `saturation` files on, logarithmic in between: the first
    /// few files matter most, the hundredth hardly at all.
    func bonus(for stub: JavaClassStub, cap: Double) -> Double {
        let count = Double(usage(of: stub))
        guard count > 0 else { return 0 }
        return cap * min(1, log2(1 + count) / log2(1 + Self.saturation))
    }

    /// The most used of `candidates` (ties go to the one listed first), when at least
    /// `minimumFiles` files use it.
    func mostUsed(of candidates: [JavaClassStub], minimumFiles: Int = 2) -> JavaClassStub? {
        var best: (stub: JavaClassStub, count: Int)?
        for stub in candidates {
            let count = usage(of: stub)
            if count >= minimumFiles, count > (best?.count ?? 0) { best = (stub, count) }
        }
        return best?.stub
    }
}

/// The nudges. Priority units: one step is four ranker points (`DefaultRanker`), a scope bucket is
/// 0.5 apart, so a general class nudge stays below the difference between "in scope" and "other".
extension JavaCompletionPriority {
    /// Most a class's popularity can add when classes compete for position.
    static let usageCap = 0.4
    /// Most it can add to an implementation offered after `new`, where every candidate is in one
    /// bucket and the only question is which the project reaches for.
    static let usageCapForNew = 1.5
}
