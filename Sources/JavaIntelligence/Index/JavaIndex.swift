import Foundation
import EditorIntelligence

/// Composes indexed shards (JDK, JARs, project sources) plus an in-memory overlay for open/edited
/// documents into one query surface -- the equivalent of `FileBasedIndex`'s read side, scoped to
/// the single "class by name" index this engine needs.
///
/// Precedence when the same qualified name appears in more than one source (a class shadowing a
/// same-named JDK/JAR class, or an open document's live overlay shadowing what's on disk):
/// lower ``Source/precedence`` wins. The overlay always wins (it sits at -1 internally); callers
/// assign 1 = project sources, 2 = JARs, 3 = JDK, per the overlay > sources > JARs > JDK ordering.
public actor JavaIndex {
    public struct Source: Sendable {
        public let precedence: Int
        public let reader: JavaIndexShardReader
        /// Shard file path used to scope queries. Empty means the source is visible to every query
        /// (the JDK, and any caller that has not opted into scoping).
        public let shardPath: String

        public init(precedence: Int, reader: JavaIndexShardReader, shardPath: String = "") {
            self.precedence = precedence
            self.reader = reader
            self.shardPath = shardPath
        }
    }

    /// Shard paths a single completion may see. `nil` (the default) sees every source. JDK shards
    /// (precedence 3), the overlay, and sources with an empty `shardPath` stay visible either way.
    @TaskLocal public static var queryScope: Set<String>?

    private var sources: [Source] = []
    /// `sources` ordered by precedence, cached by `setSources` so `classStub` doesn't re-sort on
    /// every lookup.
    private var sortedSources: [Source] = []
    private var overlay: [String: JavaClassStub] = [:]

    /// Sorted by lowercased simple name for binary-search prefix scans. `precedence` lets
    /// `classes(simpleNamePrefix:)` prefer the higher-priority definition when several sources
    /// define the same qualified name.
    private struct NameEntry {
        let lowerSimpleName: String
        let simpleName: String
        let qualifiedName: String
        let precedence: Int
        let shardPath: String
    }
    /// Names from every shard. Large (the whole JDK + classpath), so it is rebuilt only when the
    /// sources change -- never on an overlay edit.
    private var baseNameIndex: [NameEntry] = []
    private var basePackages: Set<String> = []
    /// Names from the open-document overlay (precedence -1). Small, and rebuilt from `overlay` on
    /// every overlay change, which is what keeps typing cheap on a large classpath.
    private var overlayNameIndex: [NameEntry] = []
    private var overlayPackages: Set<String> = []

    public init() {}

    // MARK: - Mutation

    public func setSources(_ sources: [Source]) {
        self.sources = sources
        self.sortedSources = sources.sorted { $0.precedence < $1.precedence }
        rebuildBaseIndex()
    }

    public func setOverlay(_ stubs: [String: JavaClassStub]) {
        self.overlay = stubs
        rebuildOverlayIndex()
    }

    public func updateOverlay(qualifiedName: String, stub: JavaClassStub?) {
        overlay[qualifiedName] = stub
        rebuildOverlayIndex()
    }

    /// Applies one document's overlay change: drops `removing`, then adds (or replaces) `adding`.
    /// Only the overlay table is touched, so the cost scales with the number of open classes
    /// rather than with the classpath.
    public func replaceOverlay(removing: Set<String>, adding: [JavaClassStub]) {
        for name in removing {
            overlay[name] = nil
        }
        for stub in adding {
            overlay[stub.qualifiedName] = stub
        }
        rebuildOverlayIndex()
    }

    private func rebuildBaseIndex() {
        var entries: [NameEntry] = []
        var pkgs: Set<String> = []

        for source in sources {
            for qualifiedName in source.reader.allQualifiedNames {
                let simpleName = String(qualifiedName.split(separator: ".").last ?? Substring(qualifiedName))
                entries.append(NameEntry(
                    lowerSimpleName: simpleName.lowercased(),
                    simpleName: simpleName,
                    qualifiedName: qualifiedName,
                    precedence: source.precedence,
                    shardPath: source.shardPath
                ))
                if let lastDot = qualifiedName.range(of: ".", options: .backwards) {
                    insertPackages(of: String(qualifiedName[..<lastDot.lowerBound]), into: &pkgs)
                } else {
                    insertPackages(of: "", into: &pkgs)
                }
            }
        }
        entries.sort { $0.lowerSimpleName < $1.lowerSimpleName }
        self.baseNameIndex = entries
        self.basePackages = pkgs
    }

    private func rebuildOverlayIndex() {
        var entries: [NameEntry] = []
        var pkgs: Set<String> = []
        entries.reserveCapacity(overlay.count)
        for (name, stub) in overlay {
            entries.append(NameEntry(lowerSimpleName: stub.simpleName.lowercased(), simpleName: stub.simpleName, qualifiedName: name, precedence: -1, shardPath: ""))
            insertPackages(of: stub.packageName, into: &pkgs)
        }
        entries.sort { $0.lowerSimpleName < $1.lowerSimpleName }
        self.overlayNameIndex = entries
        self.overlayPackages = pkgs
    }

    /// Package sets to search. Unscoped, the cached base and overlay sets; under a query scope,
    /// only packages that still have a visible class, so import completion doesn't offer a
    /// test-only package from `src/main`.
    private func visiblePackagePools() -> [Set<String>] {
        guard Self.queryScope != nil else { return [basePackages, overlayPackages] }
        var scoped = Set<String>()
        for table in [baseNameIndex, overlayNameIndex] {
            for entry in table where isVisible(shardPath: entry.shardPath, precedence: entry.precedence) {
                if let lastDot = entry.qualifiedName.range(of: ".", options: .backwards) {
                    insertPackages(of: String(entry.qualifiedName[..<lastDot.lowerBound]), into: &scoped)
                }
            }
        }
        return [scoped]
    }

    private func insertPackages(of packageName: String, into set: inout Set<String>) {
        guard !packageName.isEmpty else { return }
        let components = packageName.split(separator: ".").map(String.init)
        var prefix = ""
        for component in components {
            prefix = prefix.isEmpty ? component : "\(prefix).\(component)"
            set.insert(prefix)
        }
    }

    // MARK: - Queries

    /// The single, highest-precedence definition of a qualified name, or `nil` if unknown.
    public func classStub(qualifiedName: String) -> JavaClassStub? {
        if let overlaid = overlay[qualifiedName] {
            return overlaid
        }
        for source in sortedSources {
            guard isVisible(shardPath: source.shardPath, precedence: source.precedence) else { continue }
            if let stub = source.reader.classStub(named: qualifiedName) {
                return stub
            }
        }
        return nil
    }

    /// JDK (precedence 3), the overlay (precedence -1), and unscoped sources stay visible. A set
    /// query scope hides every other shard whose path is not in the set.
    private func isVisible(shardPath: String, precedence: Int) -> Bool {
        if precedence <= 0 || precedence == 3 || shardPath.isEmpty { return true }
        guard let scope = Self.queryScope else { return true }
        return scope.contains(shardPath)
    }

    /// Classes whose simple name starts with `prefix` (case-insensitive), or matches it as an
    /// all-uppercase camel-hump abbreviation (e.g. "ALE" matches "ArrayListEntry" by lining up
    /// against its uppercase letters in order). Results are deduplicated by qualified name
    /// (keeping the highest-precedence definition) and capped at `limit`.
    public func classes(simpleNamePrefix prefix: String, limit: Int = 200) -> [JavaClassStub] {
        guard !prefix.isEmpty else { return [] }
        let lowerPrefix = prefix.lowercased()
        var bestPrecedence: [String: Int] = [:]
        var matchedNames: [String] = []

        for table in [baseNameIndex, overlayNameIndex] {
            var i = lowerBoundIndex(for: lowerPrefix, in: table)
            while i < table.count, table[i].lowerSimpleName.hasPrefix(lowerPrefix) {
                if isVisible(shardPath: table[i].shardPath, precedence: table[i].precedence) {
                    considerMatch(table[i], bestPrecedence: &bestPrecedence, matchedNames: &matchedNames)
                }
                i += 1
            }
        }
        // Camel-hump: only worth scanning the rest of the table when the prefix looks like an
        // all-uppercase abbreviation, since a full scan is O(n) and `matchesCamelHump` rejects
        // anything else immediately anyway.
        if prefix.count > 1, prefix.allSatisfy(\.isUppercase) {
            for table in [baseNameIndex, overlayNameIndex] {
                for entry in table where bestPrecedence[entry.qualifiedName] == nil {
                    guard isVisible(shardPath: entry.shardPath, precedence: entry.precedence) else { continue }
                    if matchesCamelHump(prefix, entry.simpleName) {
                        considerMatch(entry, bestPrecedence: &bestPrecedence, matchedNames: &matchedNames)
                    }
                }
            }
        }

        var seen = Set<String>()
        var result: [JavaClassStub] = []
        for name in matchedNames {
            guard seen.insert(name).inserted else { continue }
            if let stub = classStub(qualifiedName: name) {
                result.append(stub)
            }
            if result.count >= limit { break }
        }
        return result
    }

    /// A class whose simple name matched a completion query, with how well it matched.
    public struct ClassMatch: Sendable {
        public let stub: JavaClassStub
        public let tier: CompletionMatcher.Tier
    }

    /// Classes whose simple name matches `query` the way IntelliJ's class-name completion does:
    /// prefix, camel-hump (`ArrLi`, `aL`, `NPE`), or from a later word start (`List` finds
    /// `ArrayList`). Best tier first, then higher-precedence (project before JDK), shorter names,
    /// alphabetical; deduplicated by qualified name and capped at `limit`.
    public func classes(matching query: String, limit: Int = 150) -> [ClassMatch] {
        guard let firstQueryCharacter = query.lowercased().first else { return [] }
        var best: [String: (entry: NameEntry, tier: CompletionMatcher.Tier)] = [:]
        for table in [baseNameIndex, overlayNameIndex] {
            for entry in table where entry.lowerSimpleName.contains(firstQueryCharacter) {
                guard isVisible(shardPath: entry.shardPath, precedence: entry.precedence),
                      let match = CompletionMatcher.match(query, in: entry.simpleName) else { continue }
                if let existing = best[entry.qualifiedName], existing.entry.precedence <= entry.precedence {
                    continue
                }
                best[entry.qualifiedName] = (entry, match.tier)
            }
        }
        let ordered = best.values.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
            if lhs.entry.precedence != rhs.entry.precedence { return lhs.entry.precedence < rhs.entry.precedence }
            if lhs.entry.simpleName.count != rhs.entry.simpleName.count { return lhs.entry.simpleName.count < rhs.entry.simpleName.count }
            return lhs.entry.qualifiedName < rhs.entry.qualifiedName
        }
        var result: [ClassMatch] = []
        for candidate in ordered {
            guard let stub = classStub(qualifiedName: candidate.entry.qualifiedName) else { continue }
            result.append(ClassMatch(stub: stub, tier: candidate.tier))
            if result.count >= limit { break }
        }
        return result
    }

    private func considerMatch(_ entry: NameEntry, bestPrecedence: inout [String: Int], matchedNames: inout [String]) {
        if let existing = bestPrecedence[entry.qualifiedName] {
            if entry.precedence < existing {
                bestPrecedence[entry.qualifiedName] = entry.precedence
            }
        } else {
            bestPrecedence[entry.qualifiedName] = entry.precedence
            matchedNames.append(entry.qualifiedName)
        }
    }

    /// Binary search for the first entry whose lowercased simple name is `>= prefix`.
    private func lowerBoundIndex(for lowerPrefix: String, in table: [NameEntry]) -> Int {
        var low = 0
        var high = table.count
        while low < high {
            let mid = (low + high) / 2
            if table[mid].lowerSimpleName < lowerPrefix {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// Requires `pattern` to be all-uppercase, then checks whether its characters appear, in
    /// order, among `name`'s uppercase letters (its "humps") -- so "AL" matches "ArrayList" and
    /// "ArrayListEntry" (a prefix of the hump sequence), but not "ListArray".
    private func matchesCamelHump(_ pattern: String, _ name: String) -> Bool {
        guard !pattern.isEmpty, pattern.allSatisfy(\.isUppercase) else { return false }
        var patternIndex = pattern.startIndex
        for char in name {
            guard patternIndex < pattern.endIndex else { break }
            if char.isUppercase, char == pattern[patternIndex] {
                patternIndex = pattern.index(after: patternIndex)
            }
        }
        return patternIndex == pattern.endIndex
    }

    /// All classes whose package is exactly `packageName`.
    public func classes(inPackage packageName: String) -> [JavaClassStub] {
        var seenQualified = Set<String>()
        var results: [JavaClassStub] = []
        for table in [overlayNameIndex, baseNameIndex] {
            for entry in table {
                guard isVisible(shardPath: entry.shardPath, precedence: entry.precedence) else { continue }
                guard seenQualified.insert(entry.qualifiedName).inserted else { continue }
                guard let stub = classStub(qualifiedName: entry.qualifiedName), stub.packageName == packageName else { continue }
                results.append(stub)
            }
        }
        return results
    }

    /// Every class defined by the project itself (open-document overlay and project source
    /// shards, precedence 1 or lower), never JARs or the JDK, deduplicated by qualified name with
    /// the overlay winning. Honors `queryScope`. Decodes one stub per class, so this is for
    /// explicit requests such as "Go to Implementation", not for the typing hot path.
    public func projectClassStubs() -> [JavaClassStub] {
        var seen = Set<String>()
        var results: [JavaClassStub] = []
        for table in [overlayNameIndex, baseNameIndex] {
            for entry in table where entry.precedence <= 1 {
                guard isVisible(shardPath: entry.shardPath, precedence: entry.precedence) else { continue }
                guard seen.insert(entry.qualifiedName).inserted else { continue }
                if let stub = classStub(qualifiedName: entry.qualifiedName) {
                    results.append(stub)
                }
            }
        }
        return results
    }

    /// Direct subpackages of `prefix` (empty string for top-level packages), for import/package
    /// completion. E.g. `subpackages(of: "java.util")` includes "java.util.concurrent" but not
    /// "java.util.concurrent.atomic".
    public func subpackages(of prefix: String) -> [String] {
        let searchPrefix = prefix.isEmpty ? "" : "\(prefix)."
        var result = Set<String>()
        for pool in visiblePackagePools() {
            for package in pool {
                guard package.hasPrefix(searchPrefix), package != prefix else { continue }
                let remainder = package.dropFirst(searchPrefix.count)
                guard !remainder.contains(".") else { continue }
                result.insert(package)
            }
        }
        return Array(result).sorted()
    }

    public var allSourceCount: Int { sources.count }
}
