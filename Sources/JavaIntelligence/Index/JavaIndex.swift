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
    /// Indexes into ``baseNameIndex``, one bucket per word-start byte. Built with the name index.
    private var baseNameBuckets = [[Int32]](repeating: [], count: JavaWordBuckets.count)
    /// Qualified name → position in ``sortedSources`` of the first shard that defines it.
    private var winningSource: [String: Int32] = [:]
    private var basePackages: Set<String> = []
    /// Names from the open-document overlay (precedence -1). Small, and rebuilt from `overlay` on
    /// every overlay change, which is what keeps typing cheap on a large classpath.
    private var overlayNameIndex: [NameEntry] = []
    private var overlayPackages: Set<String> = []
    /// Base entries by the name-derived owner: a top-level class under its package, a nested class
    /// under its outer class (`java.util.Map.Entry` under `java.util.Map`). Lets
    /// ``classes(inPackage:)`` touch one package's names instead of the whole classpath.
    private var baseEntriesByOwner: [String: [NameEntry]] = [:]
    /// Decoded stubs by source position (in `sortedSources`) and qualified name. Shards are
    /// immutable, so entries stay valid until `setSources` replaces them. Past the cap, the oldest
    /// insertion is dropped — one decode on the next use of that name, not a flush of the cache.
    private var decodedStubs = JavaFIFOCache<DecodedKey, JavaClassStub>(limit: 16_384)

    private struct DecodedKey: Hashable {
        let source: Int
        let qualifiedName: String
    }

    /// Bumped whenever anything a query can see changes (sources or overlay), so callers can
    /// cache derived results (member sets, supertype closures) and drop them when it moves.
    public private(set) var generation = 0

    /// Member sets computed by ``JavaMemberLookup``, valid for the current ``generation`` only.
    private var memberSets: [String: [JavaResolvedMember]] = [:]
    private static let memberSetLimit = 2_048

    private func bumpGeneration() {
        generation += 1
        memberSets.removeAll(keepingCapacity: true)
    }

    func cachedMemberSet(_ key: String) -> [JavaResolvedMember]? {
        memberSets[key]
    }

    func storeMemberSet(_ members: [JavaResolvedMember], for key: String) {
        if memberSets.count >= Self.memberSetLimit { memberSets.removeAll(keepingCapacity: true) }
        memberSets[key] = members
    }

    public init() {}

    // MARK: - Member table (Go to Symbol)

    /// Built lazily by ``members(matching:limit:)`` and dropped when the sources change.
    private var baseMembers: JavaMemberTable?
    private var baseMembersBuild: Task<JavaMemberTable, Never>?
    private var sourcesVersion = 0
    private var overlayMembers: (generation: Int, table: JavaMemberTable)?

    /// The members of every project shard. The build decodes each class once, off the actor, so a
    /// completion asking the index meanwhile is not held up; a build that a `setSources` overtook
    /// is discarded and started again.
    func baseMemberTable() async -> JavaMemberTable {
        while true {
            if let baseMembers { return baseMembers }
            let version = sourcesVersion
            let task: Task<JavaMemberTable, Never>
            if let running = baseMembersBuild {
                task = running
            } else {
                let snapshot = sortedSources
                task = Task.detached(priority: .userInitiated) { JavaMemberTable.build(from: snapshot) }
                baseMembersBuild = task
            }
            let table = await task.value
            if sourcesVersion == version {
                baseMembers = table
                baseMembersBuild = nil
                return table
            }
        }
    }

    /// The members of the open buffers' classes, rebuilt when anything the index sees changed.
    func overlayMemberTable() -> JavaMemberTable {
        if let cached = overlayMembers, cached.generation == generation { return cached.table }
        var table = JavaMemberTable()
        for stub in overlay.values { table.add(stub, shardPath: "", precedence: -1) }
        overlayMembers = (generation, table)
        return table
    }

    func overlayStubs() -> [String: JavaClassStub] { overlay }

    func isMemberOwnerVisible(_ owner: JavaMemberTable.Owner) -> Bool {
        isVisible(shardPath: owner.shardPath, precedence: owner.precedence)
    }

    // MARK: - Mutation

    public func setSources(_ sources: [Source]) {
        baseMembers = nil
        baseMembersBuild = nil
        sourcesVersion += 1
        self.sources = sources
        self.sortedSources = sources.sorted { $0.precedence < $1.precedence }
        decodedStubs.removeAll()
        rebuildBaseIndex()
        bumpGeneration()
    }

    public func setOverlay(_ stubs: [String: JavaClassStub]) {
        self.overlay = stubs
        rebuildOverlayIndex()
        bumpGeneration()
    }

    public func updateOverlay(qualifiedName: String, stub: JavaClassStub?) {
        overlay[qualifiedName] = stub
        rebuildOverlayIndex()
        bumpGeneration()
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
        bumpGeneration()
    }

    private func rebuildBaseIndex() {
        var entries: [NameEntry] = []
        var pkgs: Set<String> = []
        var winners: [String: Int32] = [:]
        var nameCount = 0
        for source in sortedSources { nameCount += source.reader.allQualifiedNames.count }
        entries.reserveCapacity(nameCount)
        winners.reserveCapacity(nameCount)

        // First position in `sortedSources` wins, which is the shard `classStub` used to return.
        // Equal precedences keep their incoming order, so two project shards stay in caller order.
        for (position, source) in sortedSources.enumerated() {
            let sourcePosition = Int32(position)
            for qualifiedName in source.reader.allQualifiedNames {
                if winners[qualifiedName] == nil { winners[qualifiedName] = sourcePosition }
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
        var buckets = [[Int32]](repeating: [], count: JavaWordBuckets.count)
        var byOwner: [String: [NameEntry]] = [:]
        for (index, entry) in entries.enumerated() {
            let entryID = Int32(index)
            JavaWordBuckets.wordInitials(of: entry.simpleName) { buckets[Int($0)].append(entryID) }
            let owner = entry.qualifiedName.range(of: ".", options: .backwards).map { String(entry.qualifiedName[..<$0.lowerBound]) } ?? ""
            byOwner[owner, default: []].append(entry)
        }
        self.baseNameIndex = entries
        self.baseNameBuckets = buckets
        self.winningSource = winners
        self.basePackages = pkgs
        self.baseEntriesByOwner = byOwner
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
        guard let start = winningSource[qualifiedName] else { return nil }
        // No earlier shard defines the name. A hidden shard (or a stub that fails to decode) falls
        // through to the same walk as before, from the next position.
        for position in Int(start)..<sortedSources.count {
            let source = sortedSources[position]
            guard isVisible(shardPath: source.shardPath, precedence: source.precedence) else { continue }
            let key = DecodedKey(source: position, qualifiedName: qualifiedName)
            if let cached = decodedStubs.value(for: key) { return cached }
            if let stub = source.reader.classStub(named: qualifiedName) {
                decodedStubs.insert(stub, for: key)
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
        // Camel-hump: only worth scanning when the prefix looks like an all-uppercase abbreviation.
        // Every ASCII uppercase letter is a bucket key, so the names `matchesCamelHump` can accept
        // all sit in the bucket of the pattern's first letter. A non-ASCII first letter stays a
        // full scan, because `matchesCamelHump` uses `Character.isUppercase`.
        if prefix.count > 1, prefix.allSatisfy(\.isUppercase) {
            let firstIsASCIIUpper = prefix.utf8.first.map { $0 >= 65 && $0 <= 90 } ?? false
            if firstIsASCIIUpper, let key = JavaWordBuckets.bucketKey(of: prefix) {
                for id in baseNameBuckets[Int(key)] {
                    let entry = baseNameIndex[Int(id)]
                    guard bestPrecedence[entry.qualifiedName] == nil,
                          isVisible(shardPath: entry.shardPath, precedence: entry.precedence),
                          matchesCamelHump(prefix, entry.simpleName) else { continue }
                    considerMatch(entry, bestPrecedence: &bestPrecedence, matchedNames: &matchedNames)
                }
                for entry in overlayNameIndex where bestPrecedence[entry.qualifiedName] == nil {
                    guard isVisible(shardPath: entry.shardPath, precedence: entry.precedence),
                          matchesCamelHump(prefix, entry.simpleName) else { continue }
                    considerMatch(entry, bestPrecedence: &bestPrecedence, matchedNames: &matchedNames)
                }
            } else {
                for table in [baseNameIndex, overlayNameIndex] {
                    for entry in table where bestPrecedence[entry.qualifiedName] == nil {
                        guard isVisible(shardPath: entry.shardPath, precedence: entry.precedence) else { continue }
                        if matchesCamelHump(prefix, entry.simpleName) {
                            considerMatch(entry, bestPrecedence: &bestPrecedence, matchedNames: &matchedNames)
                        }
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

    /// Classes whose simple name is exactly `name` (case-sensitive), deduplicated by qualified name
    /// keeping the higher-precedence definition. Unlike ``classes(simpleNamePrefix:)`` this does
    /// not decode prefix neighbours (`List` does not pull in `ListIterator`) and does not run the
    /// all-caps hump scan (`UUID`, `URL`).
    public func classes(simpleName name: String, limit: Int = 200) -> [JavaClassStub] {
        guard !name.isEmpty, limit > 0 else { return [] }
        let lower = name.lowercased()
        var bestPrecedence: [String: Int] = [:]
        var matchedNames: [String] = []
        for table in [baseNameIndex, overlayNameIndex] {
            var i = lowerBoundIndex(for: lower, in: table)
            while i < table.count, table[i].lowerSimpleName == lower {
                if table[i].simpleName == name, isVisible(shardPath: table[i].shardPath, precedence: table[i].precedence) {
                    considerMatch(table[i], bestPrecedence: &bestPrecedence, matchedNames: &matchedNames)
                }
                i += 1
            }
        }
        var seen = Set<String>()
        var result: [JavaClassStub] = []
        for matched in matchedNames {
            guard seen.insert(matched).inserted else { continue }
            if let stub = classStub(qualifiedName: matched) {
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
        guard limit > 0, let key = JavaWordBuckets.bucketKey(of: query) else { return [] }
        let lowered = Array(query.lowercased().utf8)
        var top: [RankedClass] = []
        top.reserveCapacity(min(limit * 2, 512))
        var slot: [String: Int] = [:]
        var floor: RankedClass?

        func consider(_ entry: NameEntry, _ tier: CompletionMatcher.Tier) {
            if let index = slot[entry.qualifiedName] {
                // Same simple name, so the same tier. A second definition replaces one already
                // held only when its precedence is lower.
                if entry.precedence < top[index].precedence { top[index].precedence = entry.precedence }
                return
            }
            let ranked = RankedClass(
                tier: tier, precedence: entry.precedence, simpleCount: entry.simpleName.count, qualifiedName: entry.qualifiedName
            )
            if let floor, top.count >= limit, !ranked.isBetter(than: floor) { return }
            slot[entry.qualifiedName] = top.count
            top.append(ranked)
            if top.count >= limit * 2 {
                top.sort { $0.isBetter(than: $1) }
                if top.count > limit { top.removeLast(top.count - limit) }
                slot.removeAll(keepingCapacity: true)
                for (index, item) in top.enumerated() { slot[item.qualifiedName] = index }
                floor = top.last
            }
        }

        func consume(_ entry: NameEntry) {
            guard isVisible(shardPath: entry.shardPath, precedence: entry.precedence),
                  JavaWordBuckets.isSubsequence(lowered, of: entry.lowerSimpleName),
                  let tier = CompletionMatcher.tier(query, in: entry.simpleName) else { return }
            consider(entry, tier)
        }

        for entry in overlayNameIndex { consume(entry) }
        for id in baseNameBuckets[Int(key)] { consume(baseNameIndex[Int(id)]) }

        top.sort { $0.isBetter(than: $1) }
        var result: [ClassMatch] = []
        result.reserveCapacity(min(limit, top.count))
        for item in top {
            guard result.count < limit, let stub = classStub(qualifiedName: item.qualifiedName) else { continue }
            result.append(ClassMatch(stub: stub, tier: item.tier))
        }
        return result
    }

    /// One held class-name match. Ordered as ``classes(matching:)``: better tier, then lower
    /// precedence, then a shorter simple name, then the qualified name.
    private struct RankedClass {
        var tier: CompletionMatcher.Tier
        var precedence: Int
        var simpleCount: Int
        var qualifiedName: String

        func isBetter(than other: RankedClass) -> Bool {
            if tier != other.tier { return tier > other.tier }
            if precedence != other.precedence { return precedence < other.precedence }
            if simpleCount != other.simpleCount { return simpleCount < other.simpleCount }
            return qualifiedName < other.qualifiedName
        }
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

    /// All classes whose package is exactly `packageName`, nested classes included.
    public func classes(inPackage packageName: String) -> [JavaClassStub] {
        var seenQualified = Set<String>()
        var results: [JavaClassStub] = []
        for stub in overlay.values where stub.packageName == packageName && seenQualified.insert(stub.qualifiedName).inserted {
            results.append(stub)
        }
        // Top-level classes are listed under the package; their nested classes under them.
        var owners = [packageName]
        while let owner = owners.popLast() {
            for entry in baseEntriesByOwner[owner] ?? [] {
                guard isVisible(shardPath: entry.shardPath, precedence: entry.precedence),
                      seenQualified.insert(entry.qualifiedName).inserted,
                      let stub = classStub(qualifiedName: entry.qualifiedName), stub.packageName == packageName else { continue }
                results.append(stub)
                owners.append(entry.qualifiedName)
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

/// A fixed-capacity map that drops the oldest insertion when it fills. A lookup of a dropped key
/// misses and is inserted again at the newest position; nothing empties the whole map at once.
struct JavaFIFOCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var ring: [Key] = []
    private var cursor = 0
    let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var count: Int { storage.count }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        ring.removeAll(keepingCapacity: true)
        cursor = 0
    }

    func value(for key: Key) -> Value? {
        storage[key]
    }

    /// Replaces an existing key in place. A new key past `limit` takes the oldest slot.
    mutating func insert(_ value: Value, for key: Key) {
        if storage[key] != nil {
            storage[key] = value
            return
        }
        if storage.count >= limit, !ring.isEmpty {
            storage[ring[cursor]] = nil
            ring[cursor] = key
            cursor += 1
            if cursor == ring.count { cursor = 0 }
        } else {
            ring.append(key)
        }
        storage[key] = value
    }
}
