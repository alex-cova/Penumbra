import XCTest
@testable import EditorIntelligence
@testable import JavaIntelligence

final class JavaIndexTests: XCTestCase {
    private func tempShardURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
    }

    private func writeShard(_ stubs: [JavaClassStub]) throws -> JavaIndexShardReader {
        let url = tempShardURL()
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        return try JavaIndexShardReader(url: url)
    }

    private func stub(_ qualifiedName: String, kind: JavaTypeKind = .classKind) -> JavaClassStub {
        let simple = String(qualifiedName.split(separator: ".").last!)
        let pkg = qualifiedName.contains(".") ? qualifiedName.components(separatedBy: ".").dropLast().joined(separator: ".") : ""
        return JavaClassStub(
            binaryName: qualifiedName, qualifiedName: qualifiedName, simpleName: simple, packageName: pkg,
            kind: kind, modifiers: [.publicFlag], origin: .jdkModule("java.base")
        )
    }

    func testDecodedStubCacheDropsTheOldestInsertion() {
        var cache = JavaFIFOCache<String, Int>(limit: 3)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(3, for: "c")
        cache.insert(4, for: "d")
        XCTAssertNil(cache.value(for: "a"))
        XCTAssertEqual(cache.value(for: "b"), 2)
        XCTAssertEqual(cache.value(for: "d"), 4)
        cache.insert(20, for: "b")
        XCTAssertEqual(cache.value(for: "b"), 20)
        XCTAssertEqual(cache.count, 3)
        cache.insert(5, for: "e")
        // Replacing `b` does not move it, so it is still the next slot to drop.
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "c"), 3)
        XCTAssertEqual(cache.value(for: "d"), 4)
        XCTAssertEqual(cache.value(for: "e"), 5)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    func testClassStubLooksUpAcrossSources() async throws {
        let jdkReader = try writeShard([stub("java.lang.String"), stub("java.util.ArrayList")])
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: jdkReader)])

        let found = await index.classStub(qualifiedName: "java.lang.String")
        XCTAssertEqual(found?.qualifiedName, "java.lang.String")
        let missing = await index.classStub(qualifiedName: "com.example.Missing")
        XCTAssertNil(missing)
    }

    func testOverlayShadowsLowerPrecedenceSource() async throws {
        let jdkReader = try writeShard([stub("com.example.Foo")])
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: jdkReader)])

        let overlaid = JavaClassStub(
            binaryName: "com.example.Foo", qualifiedName: "com.example.Foo", simpleName: "Foo", packageName: "com.example",
            kind: .classKind, modifiers: [.publicFlag, .finalFlag], origin: .source(URL(fileURLWithPath: "/tmp/Foo.java"), nameRange: 0..<3)
        )
        await index.setOverlay(["com.example.Foo": overlaid])

        let found = await index.classStub(qualifiedName: "com.example.Foo")
        XCTAssertTrue(found?.modifiers.contains(.finalFlag) == true, "overlay definition should win")
    }

    func testHigherPrecedenceSourceWinsOnCollidingQualifiedName() async throws {
        let jdkReader = try writeShard([stub("com.example.Foo")]) // precedence 3
        let sourceReader = try writeShard([{
            var s = stub("com.example.Foo")
            s = JavaClassStub(
                binaryName: s.binaryName, qualifiedName: s.qualifiedName, simpleName: s.simpleName, packageName: s.packageName,
                kind: s.kind, modifiers: [.publicFlag, .abstractFlag], origin: .jdkModule("shadowed")
            )
            return s
        }()]) // precedence 1

        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 3, reader: jdkReader),
            .init(precedence: 1, reader: sourceReader)
        ])

        let found = await index.classStub(qualifiedName: "com.example.Foo")
        XCTAssertTrue(found?.modifiers.contains(.abstractFlag) == true)
    }

    func testSimpleNamePrefixSearchIsCaseInsensitiveAndDeduplicated() async throws {
        let reader = try writeShard([stub("java.util.ArrayList"), stub("java.util.ArrayDeque"), stub("java.lang.String")])
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])

        let results = await index.classes(simpleNamePrefix: "array")
        XCTAssertEqual(Set(results.map(\.simpleName)), ["ArrayList", "ArrayDeque"])
    }

    func testSimpleNamePrefixSearchSupportsCamelHumpAbbreviation() async throws {
        let reader = try writeShard([stub("java.util.concurrent.ConcurrentHashMap"), stub("java.util.HashMap")])
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])

        let results = await index.classes(simpleNamePrefix: "CHM")
        XCTAssertEqual(results.map(\.simpleName), ["ConcurrentHashMap"])
    }

    func testSimpleNamePrefixSearchRespectsLimit() async throws {
        let stubs = (0..<20).map { stub("com.example.Item\($0)") }
        let reader = try writeShard(stubs)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])

        let results = await index.classes(simpleNamePrefix: "Item", limit: 5)
        XCTAssertEqual(results.count, 5)
    }

    func testClassesInPackage() async throws {
        let reader = try writeShard([stub("java.util.ArrayList"), stub("java.util.HashMap"), stub("java.lang.String")])
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])

        let results = await index.classes(inPackage: "java.util")
        XCTAssertEqual(Set(results.map(\.simpleName)), ["ArrayList", "HashMap"])
    }

    func testSubpackagesOfReturnsOnlyDirectChildren() async throws {
        let reader = try writeShard([
            stub("java.util.ArrayList"),
            stub("java.util.concurrent.atomic.AtomicInteger"),
            stub("java.util.concurrent.ConcurrentHashMap"),
            stub("java.lang.String")
        ])
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])

        let subpackagesOfUtil = await index.subpackages(of: "java.util")
        XCTAssertEqual(subpackagesOfUtil, ["java.util.concurrent"])

        // All fixture qualified names start with "java...", so "java" is the only direct child of
        // the root package; "java.lang"/"java.util" are two levels down and shouldn't appear here.
        let topLevel = await index.subpackages(of: "")
        XCTAssertEqual(topLevel, ["java"])
    }

    func testUpdateOverlayRemovesEntryWhenNil() async throws {
        let index = JavaIndex()
        let s = stub("com.example.Foo")
        await index.updateOverlay(qualifiedName: "com.example.Foo", stub: s)
        var found = await index.classStub(qualifiedName: "com.example.Foo")
        XCTAssertNotNil(found)
        await index.updateOverlay(qualifiedName: "com.example.Foo", stub: nil)
        found = await index.classStub(qualifiedName: "com.example.Foo")
        XCTAssertNil(found)
    }

    // MARK: - Incremental overlay

    /// Every query surface, so incremental overlay updates can be compared with a from-scratch build.
    private func snapshot(_ index: JavaIndex) async -> [String] {
        var lines: [String] = []
        for prefix in ["Foo", "F", "FB", "Bar", "java"] {
            lines.append("prefix \(prefix): " + (await index.classes(simpleNamePrefix: prefix)).map(\.qualifiedName).sorted().joined(separator: ","))
        }
        lines.append("matching oo: " + (await index.classes(matching: "oo")).map(\.stub.qualifiedName).joined(separator: ","))
        lines.append("inPackage: " + (await index.classes(inPackage: "com.example")).map(\.qualifiedName).sorted().joined(separator: ","))
        lines.append("sub root: " + (await index.subpackages(of: "")).joined(separator: ","))
        lines.append("sub com: " + (await index.subpackages(of: "com")).joined(separator: ","))
        return lines
    }

    func testReplaceOverlayMatchesFromScratchBuild() async throws {
        let reader = try writeShard([stub("java.lang.String"), stub("com.example.FooBar")])
        let sources: [JavaIndex.Source] = [.init(precedence: 3, reader: reader)]

        let incremental = JavaIndex()
        await incremental.setSources(sources)
        await incremental.replaceOverlay(removing: [], adding: [stub("com.example.Foo"), stub("com.other.Baz")])
        await incremental.replaceOverlay(removing: ["com.other.Baz"], adding: [stub("com.example.Bar")])

        let scratch = JavaIndex()
        await scratch.setSources(sources)
        await scratch.setOverlay([
            "com.example.Foo": stub("com.example.Foo"),
            "com.example.Bar": stub("com.example.Bar"),
        ])

        let lhs = await snapshot(incremental)
        let rhs = await snapshot(scratch)
        XCTAssertEqual(lhs, rhs)
        XCTAssertTrue(lhs.contains { $0.hasPrefix("prefix Foo:") && $0.contains("com.example.Foo") })
    }

    func testOverlayOnlyPackageDisappearsWhenLastClassIsRemoved() async throws {
        let index = JavaIndex()
        await index.replaceOverlay(removing: [], adding: [stub("com.only.Thing")])
        var subpackages = await index.subpackages(of: "com")
        XCTAssertEqual(subpackages, ["com.only"])

        await index.replaceOverlay(removing: ["com.only.Thing"], adding: [])
        subpackages = await index.subpackages(of: "com")
        XCTAssertEqual(subpackages, [])
        let topLevel = await index.subpackages(of: "")
        XCTAssertEqual(topLevel, [])
    }

    func testReplaceOverlayDoesNotDisturbSourcePackagesOrShadowing() async throws {
        let reader = try writeShard([stub("com.example.Foo")])
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])

        let overlaid = JavaClassStub(
            binaryName: "com.example.Foo", qualifiedName: "com.example.Foo", simpleName: "Foo", packageName: "com.example",
            kind: .classKind, modifiers: [.publicFlag, .finalFlag], origin: .source(URL(fileURLWithPath: "/tmp/Foo.java"), nameRange: 0..<3)
        )
        await index.replaceOverlay(removing: [], adding: [overlaid])
        var found = await index.classStub(qualifiedName: "com.example.Foo")
        XCTAssertTrue(found?.modifiers.contains(.finalFlag) == true)

        await index.replaceOverlay(removing: ["com.example.Foo"], adding: [])
        found = await index.classStub(qualifiedName: "com.example.Foo")
        XCTAssertFalse(found?.modifiers.contains(.finalFlag) == true, "shard definition returns once the overlay entry is gone")
        let subpackages = await index.subpackages(of: "com")
        XCTAssertEqual(subpackages, ["com.example"])
    }

    func testClassStubPrefersTheWinningShard() async throws {
        func marked(_ qualifiedName: String, _ extra: JavaModifiers) -> JavaClassStub {
            let base = stub(qualifiedName)
            return JavaClassStub(
                binaryName: base.binaryName, qualifiedName: base.qualifiedName, simpleName: base.simpleName, packageName: base.packageName,
                kind: base.kind, modifiers: [.publicFlag, extra], origin: base.origin
            )
        }
        let project = try writeShard([marked("com.example.Shared", .abstractFlag), marked("com.example.OnlyProject", .abstractFlag)])
        let jdk = try writeShard([marked("com.example.Shared", .finalFlag), marked("java.lang.String", .finalFlag)])
        let first = try writeShard([marked("com.example.Dup", .abstractFlag)])
        let second = try writeShard([marked("com.example.Dup", .finalFlag)])
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 1, reader: project, shardPath: "/proj"),
            .init(precedence: 3, reader: jdk, shardPath: "/jdk"),
            .init(precedence: 1, reader: first, shardPath: "/a"),
            .init(precedence: 1, reader: second, shardPath: "/b")
        ])

        let shared = await index.classStub(qualifiedName: "com.example.Shared")
        XCTAssertTrue(shared?.modifiers.contains(.abstractFlag) == true)
        let hiddenProject = await JavaIndex.$queryScope.withValue(["/jdk"]) {
            await index.classStub(qualifiedName: "com.example.Shared")
        }
        XCTAssertTrue(hiddenProject?.modifiers.contains(.finalFlag) == true)

        let dup = await index.classStub(qualifiedName: "com.example.Dup")
        XCTAssertTrue(dup?.modifiers.contains(.abstractFlag) == true, "the first precedence-1 shard wins")
        let other = await JavaIndex.$queryScope.withValue(["/b"]) {
            await index.classStub(qualifiedName: "com.example.Dup")
        }
        XCTAssertTrue(other?.modifiers.contains(.finalFlag) == true)

        let missing = await index.classStub(qualifiedName: "no.Such")
        XCTAssertNil(missing)
        let missingScoped = await JavaIndex.$queryScope.withValue(["/a"]) {
            await index.classStub(qualifiedName: "no.Such")
        }
        XCTAssertNil(missingScoped)
    }

    func testExactSimpleNameSkipsPrefixNeighbours() async throws {
        let reader = try writeShard([
            stub("java.util.List"), stub("java.util.ListIterator"), stub("java.util.UUID"), stub("com.example.List")
        ])
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])
        let lists = await index.classes(simpleName: "List")
        XCTAssertEqual(Set(lists.map(\.qualifiedName)), ["java.util.List", "com.example.List"])
        let one = await index.classes(simpleName: "List", limit: 1)
        XCTAssertEqual(one.count, 1)
        let uuid = await index.classes(simpleName: "UUID")
        XCTAssertEqual(uuid.map(\.qualifiedName), ["java.util.UUID"])
    }

    func testClassNameBucketsMatchTheLinearScan() async throws {
        let names = [
            "Base64", "S3Client", "URLConnection", "_Internal", "$Proxy12", "ΣigmaService",
            "NullPointerException", "ArrayListEntry", "UUID", "Shared"
        ]
        var project: [JavaClassStub] = names.filter { $0 != "Shared" }.map { stub("com.example.\($0)") }
        project.append(stub("com.example.Shared", kind: .classKind))
        project += (0..<30).map { stub("com.fill.Service\($0)") }
        let projectReader = try writeShard(project)
        let jarReader = try writeShard([stub("com.example.Shared")])
        let hiddenReader = try writeShard([stub("com.hidden.HiddenService")])
        let index = JavaIndex()
        let sources: [JavaIndex.Source] = [
            .init(precedence: 1, reader: projectReader, shardPath: "/project"),
            .init(precedence: 2, reader: jarReader, shardPath: "/jar"),
            .init(precedence: 2, reader: hiddenReader, shardPath: "/hidden")
        ]
        await index.setSources(sources)
        let overlay = stub("com.live.OverService")
        await index.setOverlay([overlay.qualifiedName: overlay])

        var base: [RefEntry] = []
        for source in sources.sorted(by: { $0.precedence < $1.precedence }) {
            for name in source.reader.allQualifiedNames {
                let simple = String(name.split(separator: ".").last!)
                base.append(RefEntry(
                    lowerSimpleName: simple.lowercased(), simpleName: simple, qualifiedName: name,
                    precedence: source.precedence, shardPath: source.shardPath
                ))
            }
        }
        base.sort { $0.lowerSimpleName < $1.lowerSimpleName }
        let overlayEntries = [RefEntry(
            lowerSimpleName: overlay.simpleName.lowercased(), simpleName: overlay.simpleName,
            qualifiedName: overlay.qualifiedName, precedence: -1, shardPath: ""
        )]
        let scope: Set<String> = ["/project", "/jar"]

        for name in names + ["OverService", "HiddenService", "Service0"] {
            let units = Array(name.utf16)
            var yielded = Set<UInt8>()
            JavaWordBuckets.wordInitials(of: name) { yielded.insert($0) }
            for start in CompletionMatcher.wordStarts(units) {
                let unit = units[start]
                let lowered = (unit >= 65 && unit <= 90) ? unit + 32 : unit
                guard lowered < 256 else { continue }
                XCTAssertTrue(yielded.contains(UInt8(lowered)), "\(name) missing word start at \(start)")
            }
        }

        var queries: [String] = ["uC", "NPE", "64"]
        for name in names {
            let chars = Array(name)
            for length in 1...min(3, chars.count) {
                queries.append(String(chars.prefix(length)))
            }
        }
        let limit = 5
        for query in queries {
            let expected = referenceMatches(query: query, base: base, overlay: overlayEntries, limit: limit, scope: scope)
            let actual = await JavaIndex.$queryScope.withValue(scope) {
                await index.classes(matching: query, limit: limit).map { ($0.stub.qualifiedName, $0.tier) }
            }
            XCTAssertEqual(actual.map(\.0), expected.map(\.0), query)
            XCTAssertEqual(actual.map(\.1), expected.map(\.1), query)
        }
        for pattern in ["ALE", "NPE", "URL", "UC", "UUID", "ΣS"] {
            let expected = referencePrefixes(pattern: pattern, base: base, overlay: overlayEntries, limit: limit, scope: scope)
            let actual = await JavaIndex.$queryScope.withValue(scope) {
                await index.classes(simpleNamePrefix: pattern, limit: limit).map(\.qualifiedName)
            }
            XCTAssertEqual(actual, expected, pattern)
        }
    }
}

/// The class-name scan this change replaces, kept so the bucketed lookup can be checked against it.
private struct RefEntry {
    let lowerSimpleName: String
    let simpleName: String
    let qualifiedName: String
    let precedence: Int
    let shardPath: String
}

private func referenceVisible(_ entry: RefEntry, scope: Set<String>) -> Bool {
    if entry.precedence <= 0 || entry.precedence == 3 || entry.shardPath.isEmpty { return true }
    return scope.contains(entry.shardPath)
}

private func referenceMatches(
    query: String, base: [RefEntry], overlay: [RefEntry], limit: Int, scope: Set<String>
) -> [(String, CompletionMatcher.Tier)] {
    guard let first = query.lowercased().first else { return [] }
    var best: [String: (entry: RefEntry, tier: CompletionMatcher.Tier)] = [:]
    for entry in base + overlay where entry.lowerSimpleName.contains(first) {
        guard referenceVisible(entry, scope: scope), let match = CompletionMatcher.match(query, in: entry.simpleName) else { continue }
        if let existing = best[entry.qualifiedName], existing.entry.precedence <= entry.precedence { continue }
        best[entry.qualifiedName] = (entry, match.tier)
    }
    let ordered = best.values.sorted { lhs, rhs in
        if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
        if lhs.entry.precedence != rhs.entry.precedence { return lhs.entry.precedence < rhs.entry.precedence }
        if lhs.entry.simpleName.count != rhs.entry.simpleName.count { return lhs.entry.simpleName.count < rhs.entry.simpleName.count }
        return lhs.entry.qualifiedName < rhs.entry.qualifiedName
    }
    return ordered.prefix(limit).map { ($0.entry.qualifiedName, $0.tier) }
}

private func referencePrefixes(
    pattern: String, base: [RefEntry], overlay: [RefEntry], limit: Int, scope: Set<String>
) -> [String] {
    let lower = pattern.lowercased()
    var best: [String: Int] = [:]
    var names: [String] = []
    func consider(_ entry: RefEntry) {
        if let existing = best[entry.qualifiedName] {
            if entry.precedence < existing { best[entry.qualifiedName] = entry.precedence }
        } else {
            best[entry.qualifiedName] = entry.precedence
            names.append(entry.qualifiedName)
        }
    }
    for table in [base, overlay] {
        var index = table.firstIndex { $0.lowerSimpleName >= lower } ?? table.count
        while index < table.count, table[index].lowerSimpleName.hasPrefix(lower) {
            if referenceVisible(table[index], scope: scope) { consider(table[index]) }
            index += 1
        }
    }
    if pattern.count > 1, pattern.allSatisfy(\.isUppercase) {
        for table in [base, overlay] {
            for entry in table where best[entry.qualifiedName] == nil && referenceVisible(entry, scope: scope) {
                if referenceCamelHump(pattern, entry.simpleName) { consider(entry) }
            }
        }
    }
    var seen = Set<String>()
    var result: [String] = []
    for name in names where seen.insert(name).inserted {
        result.append(name)
        if result.count >= limit { break }
    }
    return result
}

private func referenceCamelHump(_ pattern: String, _ name: String) -> Bool {
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
