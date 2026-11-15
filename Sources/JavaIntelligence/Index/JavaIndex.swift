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
        /// (the JDK, and any caller that has not opted into scoping). A platform (precedence 3)
        /// names its release with ``JavaPlatformScope/token(release:)`` here.
        public let shardPath: String
        /// The platform a query sees when its scope names no platform release (the selected JDK's
        /// own). Only meaningful at precedence 3 with a platform token.
        public let isDefaultPlatform: Bool

        public init(precedence: Int, reader: JavaIndexShardReader, shardPath: String = "", isDefaultPlatform: Bool = false) {
            self.precedence = precedence
            self.reader = reader
            self.shardPath = shardPath
            self.isDefaultPlatform = isDefaultPlatform
        }

        /// A release-specific platform: precedence 3 with a platform token.
        var isPlatform: Bool { precedence == 3 && JavaPlatformScope.release(ofToken: shardPath) != nil }
    }

    /// Shard paths a single completion may see. `nil` (the default) sees every source. JDK shards
    /// (precedence 3), the overlay, and sources with an empty `shardPath` stay visible either way,
    /// except that of several platforms (one per Java API release) exactly one is visible: the one
    /// whose ``JavaPlatformScope`` token the scope holds, else the default platform.
    @TaskLocal public static var queryScope: Set<String>?
    /// Package restrictions of the module the query comes from (JPMS, F16). They narrow the lists
    /// of class names offered to the user, never `classStub(qualifiedName:)`: a value's type may
    /// come from a package its module does not export, and its members still resolve.
    @TaskLocal public static var queryModules: JavaModuleVisibility?

    /// The classes of the buffer a request is about, by qualified name. They win over whatever is
    /// indexed under the same names for the length of that request: the overlay follows an edit
    /// after its debounce, and a request about code just typed must still see its own classes.
    /// Anything that caches answers (the member-set cache) must not be used while this is set.
    @TaskLocal public static var liveStubs: [String: JavaClassStub]?

    /// Shard paths the query's module needs before it can call a class missing: the indexed roots
    /// of its compile classpath (its source directories, its project dependencies', its jars).
    /// ``canProveAbsence`` is false while any of them is not among the sources (still indexing,
    /// failed, cancelled). `nil` asks only for the platform and the host's completeness flag.
    @TaskLocal public static var requiredShards: Set<String>?

    private var sources: [Source] = []
    /// `sources` ordered by precedence, cached by `setSources` so `classStub` doesn't re-sort on
    /// every lookup.
    private var sortedSources: [Source] = []
    private var overlay: [String: JavaClassStub] = [:]

    /// Sorted by lowercased simple name for binary-search prefix scans. `precedence` lets
    /// `classes(simpleNamePrefix:)` prefer the higher-priority definition when several sources
    /// define the same qualified name.
    private struct NameEntry: Sendable {
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
    private var basePackages: Set<String> = [] { didSet { baseParents = nil } }
    private var baseParents: Set<String>?
    /// Names from the open-document overlay (precedence -1). Small, and rebuilt from `overlay` on
    /// every overlay change, which is what keeps typing cheap on a large classpath.
    private var overlayNameIndex: [NameEntry] = []
    private var overlayPackages: Set<String> = [] { didSet { overlayParents = nil } }
    private var overlayParents: Set<String>?
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
    /// Bumped by every ``setSources(_:classpathComplete:)`` that applies (never by an overlay
    /// edit). Anything that caches a conclusion drawn from the indexed classpath — in particular
    /// "no class of this name exists" — keys it by this value and recomputes when it moves.
    public private(set) var sourcesVersion = 0
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

    // MARK: - Inheritor table (what extends X)

    private var baseInheritors: JavaInheritorTable?
    private var baseInheritorsBuild: Task<JavaInheritorTable, Never>?
    private var overlayInheritors: (generation: Int, table: JavaInheritorTable)?

    /// The project shards' subtype table, built lazily off the actor and dropped with the sources
    /// (same lifecycle as ``baseMemberTable()``).
    func baseInheritorTable() async -> JavaInheritorTable {
        while true {
            if let baseInheritors { return baseInheritors }
            let version = sourcesVersion
            let task: Task<JavaInheritorTable, Never>
            if let running = baseInheritorsBuild {
                task = running
            } else {
                let snapshot = sortedSources
                task = Task.detached(priority: .userInitiated) { JavaInheritorTable.build(from: snapshot) }
                baseInheritorsBuild = task
            }
            let table = await task.value
            if sourcesVersion == version {
                baseInheritors = table
                baseInheritorsBuild = nil
                return table
            }
        }
    }

    /// The open buffers' classes, rebuilt when anything the index sees changed.
    func overlayInheritorTable() -> JavaInheritorTable {
        if let cached = overlayInheritors, cached.generation == generation { return cached.table }
        var table = JavaInheritorTable()
        for stub in overlay.values { table.add(stub, shardPath: "", precedence: -1) }
        overlayInheritors = (generation, table)
        return table
    }

    func isInheritorSourceVisible(shardPath: String, precedence: Int) -> Bool {
        isVisible(shardPath: shardPath, precedence: precedence)
    }

    func isMemberOwnerVisible(_ owner: JavaMemberTable.Owner) -> Bool {
        isVisible(shardPath: owner.shardPath, precedence: owner.precedence)
    }

    // MARK: - Mutation

    /// Replaces every source. The name tables (about 4 µs per name: 0.2 s for a 46,000-name classpath, 0.65 s for
    /// 146,000) are built off the actor from the new sources, then swapped in with the rest of the state in one
    /// step, so a completion asked meanwhile is answered from the previous sources instead of waiting for the
    /// rebuild; this used to hold the actor, and every save stalled the next completion by that long. Returns once
    /// the new sources are in effect. A call overtaken by a newer one (the actor is re-entrant) returns without
    /// applying: the newer one applies its own sources.
    ///
    /// `classpathComplete` is the host's word that `sources` hold every root the project's code
    /// can see (no build model still being read, no dependency left to index). It is applied with
    /// the sources, so the two never disagree. See ``canProveAbsence``.
    public func setSources(_ sources: [Source], classpathComplete: Bool = true) async {
        let sorted = sources.sorted { $0.precedence < $1.precedence }
        sourcesBuildToken += 1
        let token = sourcesBuildToken
        // The same readers (shards are immutable, so the same content) and the same flag: nothing
        // a query can see changes. Keep the tables and the version, so nothing cached is dropped
        // and no open file is analysed again. The token above still overtakes an older call.
        let signature = SourcesSignature(sources: sorted, classpathComplete: classpathComplete)
        if signature == appliedSignature { return }
        let built = await Task.detached(priority: .userInitiated) {
            await Self.sourcesBuildHook?()
            return Self.buildBase(sortedSources: sorted)
        }.value
        guard token == sourcesBuildToken else { return }
        self.classpathComplete = classpathComplete
        appliedSignature = signature
        loadedShardPaths = Set(sorted.map(\.shardPath).filter { !$0.isEmpty })
        let platforms = sorted.filter(\.isPlatform)
        defaultPlatformShardPath = (platforms.first(where: \.isDefaultPlatform) ?? platforms.first)?.shardPath
        platformShardPaths = platforms.map(\.shardPath)
        platformShardPathSet = Set(platformShardPaths)
        platformSelectionCache = nil
        baseMembers = nil
        baseMembersBuild = nil
        baseInheritors = nil
        baseInheritorsBuild = nil
        sourcesVersion += 1
        self.sources = sources
        self.sortedSources = sorted
        decodedStubs.removeAll()
        baseNameIndex = built.entries
        baseNameBuckets = built.buckets
        winningSource = built.winners
        basePackages = built.packages
        baseEntriesByOwner = built.byOwner
        bumpGeneration()
    }

    /// Test seam: awaited by the off-actor build before it starts, so a test can hold a rebuild in flight.
    nonisolated(unsafe) static var sourcesBuildHook: (@Sendable () async -> Void)?

    /// Which ``setSources(_:)`` call is the newest: only it may apply its tables.
    private var sourcesBuildToken = 0

    /// See ``setSources(_:classpathComplete:)``.
    public private(set) var classpathComplete = true

    /// The shard paths of the applied sources (scoped ones only).
    public private(set) var loadedShardPaths: Set<String> = []

    /// Platform tokens of the applied platform sources, and the one a query without a platform
    /// token sees. With one platform (or none) every JDK source is visible, as before releases.
    private var platformShardPaths: [String] = []
    private var platformShardPathSet: Set<String> = []
    private var defaultPlatformShardPath: String?

    /// The platform token visible to the current query: the first applied platform the query
    /// scope names, else the default. `nil` when at most one platform is applied.
    private func selectedPlatformShardPath() -> String? {
        guard platformShardPaths.count > 1 else { return nil }
        guard let scope = Self.queryScope else { return defaultPlatformShardPath }
        // Name listings ask once per entry; one query passes the same scope set throughout, and
        // `==` on the same set storage returns at once.
        if let cached = platformSelectionCache, cached.scope == scope { return cached.selected }
        let selected = platformShardPaths.first(where: scope.contains) ?? defaultPlatformShardPath
        platformSelectionCache = (scope, selected)
        return selected
    }

    /// The last scope's platform choice. Cleared whenever the platforms change.
    private var platformSelectionCache: (scope: Set<String>, selected: String?)?

    /// The platform release the current query resolves against, when a platform is published
    /// under a token (`nil` for an index whose JDK carries no token, as in most tests).
    public var queryPlatformRelease: Int? {
        if let selected = selectedPlatformShardPath() { return JavaPlatformScope.release(ofToken: selected) }
        return platformShardPaths.first.flatMap(JavaPlatformScope.release(ofToken:))
    }

    /// What the applied sources were, for spotting a republish that changes nothing.
    private var appliedSignature: SourcesSignature?

    private struct SourcesSignature: Equatable {
        struct Entry: Equatable {
            let reader: ObjectIdentifier
            let precedence: Int
            let shardPath: String
            let isDefaultPlatform: Bool
        }
        let entries: [Entry]
        let classpathComplete: Bool

        init(sources: [Source], classpathComplete: Bool) {
            entries = sources.map { Entry(reader: ObjectIdentifier($0.reader), precedence: $0.precedence, shardPath: $0.shardPath, isDefaultPlatform: $0.isDefaultPlatform) }
            self.classpathComplete = classpathComplete
        }
    }

    /// Whether "no class of this name is indexed" means "no such class exists" for the code this
    /// index serves. It does not while the Java platform is missing (the JDK is still being
    /// indexed, or none was found: every `String` would be unresolved) or while the host says the
    /// classpath is still incomplete (a Gradle or Maven project whose model, and so whose
    /// dependency jars, is not known yet). `java.lang.Object` is the platform test: every class
    /// extends it, so an index without it cannot resolve anything authoritatively.
    ///
    /// Rules that report a class as missing ask this first and stay silent ("pending") when it is
    /// false; they never cache that silence past the next ``sourcesVersion``.
    ///
    /// Under ``requiredShards`` (set per file by the inspection service from its module's
    /// classpath) every required shard must be loaded too, so a module whose jar failed or is still
    /// indexing stays pending while the other modules keep reporting.
    public var canProveAbsence: Bool {
        classpathComplete && hasPlatformClasses && missingRequiredShards.isEmpty
    }

    /// The query's ``requiredShards`` that no applied source provides.
    public var missingRequiredShards: Set<String> {
        guard let required = Self.requiredShards else { return [] }
        return required.subtracting(loadedShardPaths)
    }

    /// Whether `java.lang.Object` is indexed (in any source, or an open buffer).
    public var hasPlatformClasses: Bool {
        winningSource["java.lang.Object"] != nil || overlay["java.lang.Object"] != nil
    }

    public func setOverlay(_ stubs: [String: JavaClassStub]) {
        self.overlay = stubs
        rebuildOverlayIndex()
        noteOverlayDeclarations()
        bumpGeneration()
    }

    public func updateOverlay(qualifiedName: String, stub: JavaClassStub?) {
        overlay[qualifiedName] = stub
        rebuildOverlayIndex()
        noteOverlayDeclarations()
        bumpGeneration()
    }

    /// Bumped when what the open buffers *declare* changes: a type added or removed, or a type's
    /// surface (kind, modifiers, supertypes, member names and signatures, nested types). A body
    /// edit or a moved name range leaves it alone. Results that judge other files by these
    /// declarations ("cannot resolve type") key on it, as they key on ``sourcesVersion``.
    public private(set) var overlayDeclarationsVersion = 0
    private var overlaySurfaces: [String: Int] = [:]

    private func noteOverlayDeclarations() {
        var surfaces: [String: Int] = [:]
        surfaces.reserveCapacity(overlay.count)
        for (name, stub) in overlay {
            surfaces[name] = Self.surface(of: stub)
        }
        if surfaces != overlaySurfaces {
            overlaySurfaces = surfaces
            overlayDeclarationsVersion += 1
        }
    }

    /// What another file can see of a class. Deliberately leaves out source ranges and Javadoc.
    private static func surface(of stub: JavaClassStub) -> Int {
        var hasher = Hasher()
        hasher.combine(stub.qualifiedName)
        hasher.combine(String(describing: stub.kind))
        hasher.combine(stub.modifiers.rawValue)
        hasher.combine(String(describing: stub.typeParameters))
        hasher.combine(String(describing: stub.superclass))
        hasher.combine(String(describing: stub.interfaces))
        hasher.combine(stub.innerTypeNames)
        for field in stub.fields {
            hasher.combine(field.name)
            hasher.combine(String(describing: field.type))
            hasher.combine(field.modifiers.rawValue)
        }
        for method in stub.methods {
            hasher.combine(method.name)
            hasher.combine(method.isConstructor)
            hasher.combine(method.modifiers.rawValue)
            hasher.combine(String(describing: method.returnType))
            hasher.combine(String(describing: method.typeParameters))
            for parameter in method.parameters { hasher.combine(String(describing: parameter.type)) }
        }
        return hasher.finalize()
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
        noteOverlayDeclarations()
        bumpGeneration()
    }

    private struct BuiltBase: Sendable {
        let entries: [NameEntry]
        let buckets: [[Int32]]
        let winners: [String: Int32]
        let packages: Set<String>
        let byOwner: [String: [NameEntry]]
    }

    private static func buildBase(sortedSources: [Source]) -> BuiltBase {
        var entries: [NameEntry] = []
        var pkgs: Set<String> = []
        var winners: [String: Int32] = [:]
        var nameCount = 0
        for source in sortedSources { nameCount += source.reader.allQualifiedNames.count }
        entries.reserveCapacity(nameCount)
        winners.reserveCapacity(nameCount)

        // The unscoped package pool is the default platform's: another release's packages
        // (`javax.xml.bind` for release 8) appear only under a scope that selects it.
        let platforms = sortedSources.filter(\.isPlatform)
        let defaultPlatform = (platforms.first(where: \.isDefaultPlatform) ?? platforms.first)?.shardPath
        // First position in `sortedSources` wins, which is the shard `classStub` used to return.
        // Equal precedences keep their incoming order, so two project shards stay in caller order.
        for (position, source) in sortedSources.enumerated() {
            let sourcePosition = Int32(position)
            let addsPackages = !source.isPlatform || source.shardPath == defaultPlatform
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
                guard addsPackages else { continue }
                if let lastDot = qualifiedName.range(of: ".", options: .backwards) {
                    Self.insertPackages(of: String(qualifiedName[..<lastDot.lowerBound]), into: &pkgs)
                } else {
                    Self.insertPackages(of: "", into: &pkgs)
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
        return BuiltBase(entries: entries, buckets: buckets, winners: winners, packages: pkgs, byOwner: byOwner)
    }

    private func rebuildOverlayIndex() {
        var entries: [NameEntry] = []
        var pkgs: Set<String> = []
        entries.reserveCapacity(overlay.count)
        for (name, stub) in overlay {
            entries.append(NameEntry(lowerSimpleName: stub.simpleName.lowercased(), simpleName: stub.simpleName, qualifiedName: name, precedence: -1, shardPath: ""))
            Self.insertPackages(of: stub.packageName, into: &pkgs)
        }
        entries.sort { $0.lowerSimpleName < $1.lowerSimpleName }
        self.overlayNameIndex = entries
        self.overlayPackages = pkgs
    }

    /// Package sets to search. Unscoped, the cached base and overlay sets; under a query scope,
    /// only packages that still have a visible class, so import completion doesn't offer a
    /// test-only package from `src/main`.
    private func visiblePackagePools() -> [Set<String>] {
        guard Self.queryScope != nil || Self.queryModules != nil else { return [basePackages, overlayPackages] }
        return [scopedPackages().packages]
    }

    /// The packages visible under the current query scope, and the ones among them that have a
    /// subpackage. Rebuilt from every name only when the scope, the modules or the ``generation``
    /// changed, not on each query (the typer asks once per unresolved receiver name).
    private func scopedPackages() -> (packages: Set<String>, parents: Set<String>) {
        let scope = Self.queryScope
        let modules = Self.queryModules
        if let cached = scopedPackageCache, cached.generation == generation, cached.scope == scope, cached.modules == modules {
            return (cached.packages, cached.parents)
        }
        var scoped = Set<String>()
        for table in [baseNameIndex, overlayNameIndex] {
            for entry in table where isNameVisible(entry) {
                if let lastDot = entry.qualifiedName.range(of: ".", options: .backwards) {
                    Self.insertPackages(of: String(entry.qualifiedName[..<lastDot.lowerBound]), into: &scoped)
                }
            }
        }
        let parents = Self.parents(of: scoped)
        scopedPackageCache = (generation, scope, modules, scoped, parents)
        return (scoped, parents)
    }

    private var scopedPackageCache: (generation: Int, scope: Set<String>?, modules: JavaModuleVisibility?, packages: Set<String>, parents: Set<String>)?

    /// Packages in `pool` that are the strict leading part of another one (`java` and `java.util`
    /// when `java.util.concurrent` is there). A pool already holds every dotted prefix.
    private static func parents(of pool: Set<String>) -> Set<String> {
        var result = Set<String>()
        for package in pool {
            var end = package.endIndex
            while let dot = package[..<end].lastIndex(of: ".") {
                if !result.insert(String(package[..<dot])).inserted { break }
                end = dot
            }
        }
        return result
    }

    /// Whether some visible package lives strictly below `name`: the same answer as
    /// `!subpackages(of: name).isEmpty` without walking the pool.
    public func hasSubpackages(of name: String) -> Bool {
        guard !name.isEmpty else { return !visiblePackagePools().allSatisfy(\.isEmpty) }
        guard Self.queryScope != nil || Self.queryModules != nil else {
            if baseParents == nil { baseParents = Self.parents(of: basePackages) }
            if overlayParents == nil { overlayParents = Self.parents(of: overlayPackages) }
            return baseParents!.contains(name) || overlayParents!.contains(name)
        }
        return scopedPackages().parents.contains(name)
    }

    private static func insertPackages(of packageName: String, into set: inout Set<String>) {
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
        if let live = Self.liveStubs?[qualifiedName] {
            return live
        }
        if let anonymous = JavaAnonymousClass.registry?.stub(named: qualifiedName) {
            return anonymous
        }
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

    /// Whether `qualifiedName` (already known to resolve through ``classStub(qualifiedName:)``)
    /// comes from a package its defining module exports to the query's module
    /// (``queryModules``). An open buffer, the JDK, and any shard with no restriction are exported.
    /// The shard asked about is the one ``classStub(qualifiedName:)`` answered from.
    public func isExportedToQuery(qualifiedName: String) -> Bool {
        guard let modules = Self.queryModules else { return true }
        if Self.liveStubs?[qualifiedName] != nil || overlay[qualifiedName] != nil { return true }
        guard let start = winningSource[qualifiedName] else { return true }
        for position in Int(start)..<sortedSources.count {
            let source = sortedSources[position]
            guard isVisible(shardPath: source.shardPath, precedence: source.precedence),
                  decodedStubs.value(for: DecodedKey(source: position, qualifiedName: qualifiedName)) != nil
                    || source.reader.classStub(named: qualifiedName) != nil else { continue }
            return modules.restrictions[source.shardPath]?.allows(qualifiedName: qualifiedName) ?? true
        }
        return true
    }

    /// JDK (precedence 3), the overlay (precedence -1), and unscoped sources stay visible. A set
    /// query scope hides every other shard whose path is not in the set. Of several platforms,
    /// only the query's (``selectedPlatformShardPath()``) is visible.
    private func isVisible(shardPath: String, precedence: Int) -> Bool {
        if precedence == 3, platformShardPaths.count > 1, platformShardPathSet.contains(shardPath) {
            return shardPath == selectedPlatformShardPath()
        }
        if precedence <= 0 || precedence == 3 || shardPath.isEmpty { return true }
        guard let scope = Self.queryScope else { return true }
        return scope.contains(shardPath)
    }

    /// ``isVisible(shardPath:precedence:)`` plus the module's package exports, for the lists of
    /// class names offered to the user.
    private func isNameVisible(_ entry: NameEntry) -> Bool {
        guard isVisible(shardPath: entry.shardPath, precedence: entry.precedence) else { return false }
        guard let restriction = Self.queryModules?.restrictions[entry.shardPath] else { return true }
        return restriction.allows(qualifiedName: entry.qualifiedName)
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
                if isNameVisible(table[i]) {
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
                          isNameVisible(entry),
                          matchesCamelHump(prefix, entry.simpleName) else { continue }
                    considerMatch(entry, bestPrecedence: &bestPrecedence, matchedNames: &matchedNames)
                }
                for entry in overlayNameIndex where bestPrecedence[entry.qualifiedName] == nil {
                    guard isNameVisible(entry),
                          matchesCamelHump(prefix, entry.simpleName) else { continue }
                    considerMatch(entry, bestPrecedence: &bestPrecedence, matchedNames: &matchedNames)
                }
            } else {
                for table in [baseNameIndex, overlayNameIndex] {
                    for entry in table where bestPrecedence[entry.qualifiedName] == nil {
                        guard isNameVisible(entry) else { continue }
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
                if table[i].simpleName == name, isNameVisible(table[i]) {
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
            guard isNameVisible(entry),
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
                guard isNameVisible(entry),
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

    /// Whether `name` is a package (or the leading part of one) that some visible class lives in.
    public func hasPackage(_ name: String) -> Bool {
        visiblePackagePools().contains { $0.contains(name) }
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

/// Why an index could not prove a class missing for one file, as of one pass.
public struct JavaResolutionReadiness: Sendable, Equatable {
    /// `java.lang.Object` is not indexed: the JDK is still indexing, or none was found.
    public let platformMissing: Bool
    /// The host said the classpath is incomplete (project sources still indexing, or a Gradle or
    /// Maven project without a model).
    public let classpathIncomplete: Bool
    /// Shards of the file's module classpath that no applied source provides (still indexing,
    /// failed, or cancelled).
    public let missingShards: Set<String>

    /// Reads the index under the caller's task-locals (the file's resolution context). `nil` when
    /// the index can prove absence.
    public init?(index: JavaIndex) async {
        let platform = await index.hasPlatformClasses
        let complete = await index.classpathComplete
        let missing = await index.missingRequiredShards
        guard !platform || !complete || !missing.isEmpty else { return nil }
        platformMissing = !platform
        classpathIncomplete = !complete
        missingShards = missing
    }

    public init(platformMissing: Bool, classpathIncomplete: Bool, missingShards: Set<String>) {
        self.platformMissing = platformMissing
        self.classpathIncomplete = classpathIncomplete
        self.missingShards = missingShards
    }
}

