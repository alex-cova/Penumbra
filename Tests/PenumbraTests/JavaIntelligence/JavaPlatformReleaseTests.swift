import Foundation
import XCTest
@testable import JavaIntelligence

/// Release-aware platform resolution without a real JDK: synthetic platform shards stand in for
/// JDK 21's own platform and for `ct.sym`'s release 8, so every case is deterministic.
final class JavaPlatformReleaseTests: XCTestCase {
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("platform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
        JavaIndex.sourcesBuildHook = nil
    }

    // MARK: - Fixtures

    private static let pub: JavaModifiers = [.publicFlag]
    private static let pubStatic: JavaModifiers = [.publicFlag, .staticFlag]

    private static func type(_ name: String) -> JavaTypeRef {
        .classType(qualifiedName: name, arguments: [], outer: nil)
    }

    private static func stub(_ qualifiedName: String, kind: JavaTypeKind = .classKind, superclass: String? = "java.lang.Object",
                             interfaces: [String] = [], methods: [JavaMethodStub] = []) -> JavaClassStub {
        let parts = qualifiedName.split(separator: ".")
        return JavaClassStub(
            binaryName: qualifiedName, qualifiedName: qualifiedName, simpleName: String(parts.last!),
            packageName: parts.dropLast().joined(separator: "."), kind: kind, modifiers: pub,
            superclass: superclass.map(type), interfaces: interfaces.map(type), methods: methods, origin: .jdkModule("java.base")
        )
    }

    private static func method(_ name: String, _ modifiers: JavaModifiers = pub, returns: JavaTypeRef = .void, parameters: Int = 0) -> JavaMethodStub {
        JavaMethodStub(
            name: name, parameters: (0..<parameters).map { _ in JavaParameterStub(name: nil, type: type("java.lang.Object")) },
            returnType: returns, modifiers: modifiers)
    }

    /// Release 8: `List` without `of`, `ByteBuffer.flip()` inherited from `Buffer`, JAXB present.
    private static var release8: [JavaClassStub] {
        [
            stub("java.lang.Object", superclass: nil, methods: [method("hashCode", returns: .primitive(.int))]),
            stub("java.lang.String"),
            stub("java.util.Collection", kind: .interfaceKind, superclass: nil, methods: [method("stream", [.publicFlag, .defaultMethod])]),
            stub("java.util.List", kind: .interfaceKind, superclass: nil, interfaces: ["java.util.Collection"], methods: [method("size", returns: .primitive(.int))]),
            stub("java.nio.Buffer", methods: [method("flip", returns: type("java.nio.Buffer"))]),
            stub("java.nio.ByteBuffer", superclass: "java.nio.Buffer"),
            stub("javax.xml.bind.JAXBContext"),
        ]
    }

    /// Release 21 (the JDK's own): `List.of`, covariant `ByteBuffer.flip()`, no JAXB.
    private static var release21: [JavaClassStub] {
        [
            stub("java.lang.Object", superclass: nil, methods: [method("hashCode", returns: .primitive(.int))]),
            stub("java.lang.String", methods: [method("isBlank", returns: .primitive(.boolean))]),
            stub("java.util.Collection", kind: .interfaceKind, superclass: nil, methods: [method("stream", [.publicFlag, .defaultMethod])]),
            stub("java.util.List", kind: .interfaceKind, superclass: nil, interfaces: ["java.util.Collection"], methods: [
                method("size", returns: .primitive(.int)), method("of", pubStatic, returns: type("java.util.List"), parameters: 1),
            ]),
            stub("java.nio.Buffer", methods: [method("flip", returns: type("java.nio.Buffer"))]),
            stub("java.nio.ByteBuffer", superclass: "java.nio.Buffer", methods: [method("flip", returns: type("java.nio.ByteBuffer"))]),
            stub("java.net.http.HttpClient"),
        ]
    }

    private func shard(_ name: String, _ stubs: [JavaClassStub]) throws -> JavaIndexShardReader {
        let url = work.appendingPathComponent("\(name).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        return try JavaIndexShardReader(url: url)
    }

    private static let token8 = JavaPlatformScope.token(release: 8)
    private static let token21 = JavaPlatformScope.token(release: 21)

    private func twoPlatformIndex() async throws -> JavaIndex {
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 3, reader: try shard("jdk21", Self.release21), shardPath: Self.token21, isDefaultPlatform: true),
            .init(precedence: 3, reader: try shard("ct8", Self.release8), shardPath: Self.token8),
        ])
        return index
    }

    private static let context = JavaResolutionContext(packageName: "app", imports: [], enclosingTypeQualifiedNames: ["app.Main"])

    private static func memberNames(_ owner: String, _ mode: JavaMemberLookupMode, _ index: JavaIndex) async -> Set<String> {
        Set(await JavaMemberLookup.members(of: Self.type(owner), mode: mode, context: Self.context, index: index).map(\.name))
    }

    // MARK: - Compiler settings → platform API

    func testReleaseWinsOverToolchainAndSourceCompatibility() {
        let settings = JavaCompilerSettings(release: 8, toolchainVersion: 21, sourceCompatibility: 17, targetCompatibility: 17)
        XCTAssertEqual(JavaPlatformAPI(settings: settings, legacyLanguageLevel: 21), .release(8))
        XCTAssertEqual(JavaPlatformAPI(settings: settings, legacyLanguageLevel: 21).apiRelease, 8)
    }

    func testToolchainWithoutReleaseIsThatJDKsPlatform() {
        let api = JavaPlatformAPI(settings: JavaCompilerSettings(toolchainVersion: 17, sourceCompatibility: 8), legacyLanguageLevel: nil)
        XCTAssertEqual(api, .toolchain(17))
        XCTAssertEqual(api.apiRelease, 17)
    }

    /// `-source 8 -target 8` on JDK 21 compiles against JDK 21's platform: no API restriction.
    func testSourceAndTargetAloneDoNotRestrictTheAPI() {
        let api = JavaPlatformAPI(settings: JavaCompilerSettings(sourceCompatibility: 8, targetCompatibility: 8), legacyLanguageLevel: 8)
        XCTAssertEqual(api, .compilerJDK(sourceLevel: 8))
        XCTAssertNil(api.apiRelease)
    }

    func testModelWithoutCompilerSettingsIsLegacyAndUnrestricted() {
        let api = JavaPlatformAPI(settings: nil, legacyLanguageLevel: 8)
        XCTAssertEqual(api, .legacy(languageLevel: 8))
        XCTAssertNil(api.apiRelease)
    }

    func testPlatformTokensRoundTrip() {
        XCTAssertEqual(JavaPlatformScope.release(ofToken: JavaPlatformScope.token(release: 17)), 17)
        XCTAssertNil(JavaPlatformScope.release(ofToken: "/cache/jar-abc.idx"))
    }

    // MARK: - javac flags follow the same decision

    func testJavacFlags() {
        func flags(_ api: JavaPlatformAPI, jdk: Int) -> [String] {
            let result = JavacInvocationBuilder.platformFlags(api, jdkFeatureVersion: jdk)
            return (result.release.map { ["--release", String($0)] } ?? []) + result.options
        }
        XCTAssertEqual(flags(.release(8), jdk: 21), ["--release", "8"])
        XCTAssertEqual(flags(.release(25), jdk: 21), ["--release", "21"], "capped at the JDK, as before")
        XCTAssertEqual(flags(.toolchain(21), jdk: 21), [], "the toolchain is the JDK checking")
        XCTAssertEqual(flags(.toolchain(17), jdk: 21), ["--release", "17"], "release 17 stands in for a JDK 17")
        XCTAssertEqual(flags(.compilerJDK(sourceLevel: 8), jdk: 21), ["-source", "8", "-target", "8", "-Xlint:-options"],
                       "a source level must not become --release: the build accepts JDK 21 APIs")
        XCTAssertEqual(flags(.compilerJDK(sourceLevel: 21), jdk: 21), [])
        XCTAssertEqual(flags(.compilerJDK(sourceLevel: nil), jdk: 21), [])
        XCTAssertEqual(flags(.legacy(languageLevel: 17), jdk: 21), ["--release", "17"], "old models keep their old flags")
    }

    func testJavacInvocationForSourceCompatibilityOnlyModule() throws {
        let root = work.appendingPathComponent("proj", isDirectory: true)
        let src = root.appendingPathComponent("src/main/java", isDirectory: true)
        let file = src.appendingPathComponent("app/Main.java")
        let set = JavaGradleProjectModel.SourceSet(name: "main", sourceDirs: [src], compiler: JavaCompilerSettings(sourceCompatibility: 8))
        let model = JavaGradleProjectModel(formatVersion: 9, gradleVersion: "9.0", subprojects: [
            .init(path: ":", directory: root, languageLevel: 8, sourceSets: [set]),
        ])
        let settings = try XCTUnwrap(JavacInvocationBuilder.resolve(file: file, text: "package app;", kind: .gradle(model)))
        XCTAssertEqual(settings.platform, .compilerJDK(sourceLevel: 8))
    }

    // MARK: - Model

    private func twoModuleModel() -> (JavaGradleProjectModel, legacy: URL, modern: URL, modernTest: URL) {
        let root = work.appendingPathComponent("proj", isDirectory: true)
        let legacyDir = root.appendingPathComponent("legacy/src/main/java", isDirectory: true)
        let modernDir = root.appendingPathComponent("modern/src/main/java", isDirectory: true)
        let modernTestDir = root.appendingPathComponent("modern/src/test/java", isDirectory: true)
        let model = JavaGradleProjectModel(formatVersion: 9, gradleVersion: "9.0", subprojects: [
            .init(path: ":legacy", directory: root.appendingPathComponent("legacy"), languageLevel: 8, sourceSets: [
                .init(name: "main", sourceDirs: [legacyDir], compiler: JavaCompilerSettings(release: 8)),
            ]),
            .init(path: ":modern", directory: root.appendingPathComponent("modern"), languageLevel: 21, sourceSets: [
                .init(name: "main", sourceDirs: [modernDir], compiler: JavaCompilerSettings(sourceCompatibility: 21)),
                .init(name: "test", sourceDirs: [modernTestDir], compiler: JavaCompilerSettings(release: 17)),
            ]),
        ])
        return (model, legacyDir.appendingPathComponent("A.java"), modernDir.appendingPathComponent("B.java"),
                modernTestDir.appendingPathComponent("BTest.java"))
    }

    func testEachSourceSetScopesItsOwnPlatform() throws {
        let (model, legacy, modern, modernTest) = twoModuleModel()
        let paths = JavaIndexPaths(root: work)
        XCTAssertTrue(try XCTUnwrap(model.visibleShardPaths(forFile: legacy, paths: paths)).contains(Self.token8))
        XCTAssertFalse(try XCTUnwrap(model.visibleShardPaths(forFile: modern, paths: paths)).contains { $0.hasPrefix(JavaPlatformScope.tokenPrefix) })
        XCTAssertTrue(try XCTUnwrap(model.visibleShardPaths(forFile: modernTest, paths: paths)).contains(JavaPlatformScope.token(release: 17)))
        XCTAssertEqual(model.platformReleases, [8, 17])
        XCTAssertEqual(model.maxLanguageLevel, 21)
    }

    /// A module's release is required like its jars: until it is published, absence is unproven.
    func testPlatformTokenIsARequiredShard() {
        let (model, legacy, modern, _) = twoModuleModel()
        let scopes = JavaFileResolutionScopes(model: model, paths: JavaIndexPaths(root: work))
        XCTAssertEqual(scopes.context(for: legacy).requiredShards, [Self.token8])
        XCTAssertEqual(scopes.context(for: modern).requiredShards, [])
    }

    func testCompilerSettingsDecodeAndOldModelsDecodeWithout() throws {
        let set = JavaGradleProjectModel.SourceSet(name: "main", compiler: JavaCompilerSettings(release: 11, sourceCompatibility: 11))
        let decoded = try JSONDecoder().decode(JavaGradleProjectModel.SourceSet.self, from: JSONEncoder().encode(set))
        XCTAssertEqual(decoded.compiler, JavaCompilerSettings(release: 11, sourceCompatibility: 11))
        let old = try JSONDecoder().decode(JavaGradleProjectModel.SourceSet.self, from: Data(#"{"name":"main"}"#.utf8))
        XCTAssertNil(old.compiler)
    }

    // MARK: - Maven

    private func element(_ name: String, _ text: String = "", _ children: [MavenXMLElement] = []) -> MavenXMLElement {
        MavenXMLElement(name: name, text: text, children: children)
    }

    func testMavenPluginConfigurationWinsOverProperties() throws {
        let compiler = element("configuration", "", [element("release", "11")])
        let (main, test) = MavenModelBuilder.compilerSettings(
            properties: ["maven.compiler.release": "8", "maven.compiler.source": "1.8"], compiler: compiler, toolchains: nil)
        XCTAssertEqual(main.release, 11)
        XCTAssertEqual(main.sourceCompatibility, 8)
        XCTAssertEqual(test.release, 11, "testRelease falls back to release")
    }

    func testMavenTestReleaseAndToolchain() throws {
        let compiler = element("configuration", "", [element("testRelease", "21")])
        let toolchains = element("configuration", "", [element("toolchains", "", [element("jdk", "", [element("version", "17")])])])
        let (main, test) = MavenModelBuilder.compilerSettings(
            properties: ["maven.compiler.source": "17", "maven.compiler.target": "17"], compiler: compiler, toolchains: toolchains)
        XCTAssertNil(main.release)
        XCTAssertEqual(main.toolchainVersion, 17)
        XCTAssertEqual(JavaPlatformAPI(settings: main, legacyLanguageLevel: 17), .toolchain(17))
        XCTAssertEqual(test.release, 21)
    }

    func testMavenToolchainRangeAndUninterpolatedValuesAreUnknown() throws {
        let toolchains = element("configuration", "", [element("toolchains", "", [element("jdk", "", [element("version", "[17,)")])])])
        let (main, _) = MavenModelBuilder.compilerSettings(
            properties: ["maven.compiler.release": "${java.version}"], compiler: nil, toolchains: toolchains)
        XCTAssertNil(main.toolchainVersion)
        XCTAssertNil(main.release)
        XCTAssertEqual(JavaPlatformAPI(settings: main, legacyLanguageLevel: nil), .compilerJDK(sourceLevel: nil))
    }

    // MARK: - Index: class and member level

    func testReleaseScopeSeesReleaseClassesAndMembers() async throws {
        let index = try await twoPlatformIndex()
        await JavaIndex.$queryScope.withValue([Self.token8]) {
            let jaxb = await index.classStub(qualifiedName: "javax.xml.bind.JAXBContext")
            XCTAssertNotNil(jaxb, "JAXB exists in release 8")
            let httpClient = await index.classStub(qualifiedName: "java.net.http.HttpClient")
            XCTAssertNil(httpClient, "java.net.http is Java 11")
            let list = await index.classStub(qualifiedName: "java.util.List")
            XCTAssertNotNil(list)
            XCTAssertFalse(list?.methods.contains { $0.name == "of" } ?? true, "List.of is Java 9")
            let hasJAXBPackage = await index.hasPackage("javax.xml.bind")
            XCTAssertTrue(hasJAXBPackage)
        }
    }

    func testDefaultScopeSeesTheJDKsOwnPlatform() async throws {
        let index = try await twoPlatformIndex()
        let jaxb = await index.classStub(qualifiedName: "javax.xml.bind.JAXBContext")
        XCTAssertNil(jaxb)
        let hasJAXBPackage = await index.hasPackage("javax.xml.bind")
        XCTAssertFalse(hasJAXBPackage, "the unscoped package pool is the default platform's")
        let release = await index.queryPlatformRelease
        XCTAssertEqual(release, 21)
        // A module scope without a token is also the default platform.
        await JavaIndex.$queryScope.withValue(["/some/jar.idx"]) {
            let names = await Self.memberNames("java.util.List", .staticOnly, index)
            XCTAssertTrue(names.contains("of"))
        }
    }

    func testMemberLookupCacheDoesNotLeakAcrossReleases() async throws {
        let index = try await twoPlatformIndex()
        let modern = await JavaIndex.$queryScope.withValue([Self.token21]) { await Self.memberNames("java.util.List", .staticOnly, index) }
        let legacy = await JavaIndex.$queryScope.withValue([Self.token8]) { await Self.memberNames("java.util.List", .staticOnly, index) }
        let modernAgain = await JavaIndex.$queryScope.withValue([Self.token21]) { await Self.memberNames("java.util.List", .staticOnly, index) }
        XCTAssertTrue(modern.contains("of"))
        XCTAssertFalse(legacy.contains("of"))
        XCTAssertEqual(modern, modernAgain)
    }

    /// Inherited and covariant members follow the release: `ByteBuffer.flip()` returns `Buffer`
    /// in release 8 (inherited) and `ByteBuffer` from 9 on (overridden).
    func testInheritedAndChangedSignaturesFollowTheRelease() async throws {
        let index = try await twoPlatformIndex()
        func flipReturn(_ token: String) async -> String? {
            await JavaIndex.$queryScope.withValue([token]) {
                let members = await JavaMemberLookup.members(of: Self.type("java.nio.ByteBuffer"), mode: .instance, context: Self.context, index: index)
                for member in members {
                    if case .method(let method, _) = member, method.name == "flip" { return method.returnType.simpleDisplayName }
                }
                return nil
            }
        }
        let legacyFlip = await flipReturn(Self.token8)
        let modernFlip = await flipReturn(Self.token21)
        XCTAssertEqual(legacyFlip, "Buffer")
        XCTAssertEqual(modernFlip, "ByteBuffer")
        let defaultMethod = await JavaIndex.$queryScope.withValue([Self.token8]) { await Self.memberNames("java.util.List", .instance, index) }
        XCTAssertTrue(defaultMethod.contains("stream"), "default method inherited from Collection")
    }

    func testCompletionListingsAreReleaseScoped() async throws {
        let index = try await twoPlatformIndex()
        let legacy = await JavaIndex.$queryScope.withValue([Self.token8]) { await index.classes(simpleNamePrefix: "JAXB") }
        let modern = await JavaIndex.$queryScope.withValue([Self.token21]) { await index.classes(simpleNamePrefix: "JAXB") }
        XCTAssertEqual(legacy.map(\.qualifiedName), ["javax.xml.bind.JAXBContext"])
        XCTAssertEqual(modern, [])
        let modernHttp = await JavaIndex.$queryScope.withValue([Self.token21]) { await index.classes(simpleName: "HttpClient", limit: 5) }
        let legacyHttp = await JavaIndex.$queryScope.withValue([Self.token8]) { await index.classes(simpleName: "HttpClient", limit: 5) }
        XCTAssertEqual(modernHttp.count, 1)
        XCTAssertEqual(legacyHttp.count, 0, "an API introduced later is not offered")
    }

    // MARK: - Readiness

    /// A module on a release that is not published yet (still indexing, failed, or not in the
    /// JDK's ct.sym) must not report classes missing from the stand-in platform.
    func testUnpublishedReleaseKeepsAbsenceUnproven() async throws {
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 3, reader: try shard("jdk21", Self.release21), shardPath: Self.token21, isDefaultPlatform: true),
        ])
        await JavaIndex.$queryScope.withValue([Self.token8]) {
            await JavaIndex.$requiredShards.withValue([Self.token8]) {
                let proves = await index.canProveAbsence
                XCTAssertFalse(proves)
                let readiness = await JavaResolutionReadiness(index: index)
                XCTAssertEqual(readiness?.missingShards, [Self.token8])
                // The stand-in still answers completion.
                let string = await index.classStub(qualifiedName: "java.lang.String")
                XCTAssertNotNil(string)
            }
        }
        let release8 = try shard("ct8", Self.release8)
        await index.setSources([
            .init(precedence: 3, reader: try shard("jdk21b", Self.release21), shardPath: Self.token21, isDefaultPlatform: true),
            .init(precedence: 3, reader: release8, shardPath: Self.token8),
        ])
        await JavaIndex.$queryScope.withValue([Self.token8]) {
            await JavaIndex.$requiredShards.withValue([Self.token8]) {
                let proves = await index.canProveAbsence
                XCTAssertTrue(proves)
            }
        }
    }

    // MARK: - Concurrency

    /// An older publication (release 8 platform) overtaken by a newer one (release 21 only)
    /// never applies, even when it finishes last.
    func testOutdatedPlatformPublicationFinishingLastDoesNotApply() async throws {
        let index = JavaIndex()
        let jdk = try shard("jdk21", Self.release21)
        let ct8 = try shard("ct8", Self.release8)
        let gate = AsyncGate()
        let calls = Counter()
        JavaIndex.sourcesBuildHook = {
            // The first build (the older publication) waits until the newer one has applied.
            if await calls.next() == 1 { await gate.wait() }
        }
        let older = Task {
            await index.setSources([
                .init(precedence: 3, reader: jdk, shardPath: Self.token21, isDefaultPlatform: true),
                .init(precedence: 3, reader: ct8, shardPath: Self.token8),
            ])
        }
        while await calls.value < 1 { await Task.yield() }
        await index.setSources([.init(precedence: 3, reader: jdk, shardPath: Self.token21, isDefaultPlatform: true)])
        await gate.open()
        await older.value
        let loaded = await index.loadedShardPaths
        XCTAssertEqual(loaded, [Self.token21])
        let jaxb = await JavaIndex.$queryScope.withValue([Self.token8]) { await index.classStub(qualifiedName: "javax.xml.bind.JAXBContext") }
        XCTAssertNil(jaxb, "release 8 was withdrawn by the newer publication")
    }

    /// Two modules on different releases query one index concurrently and each sees its own.
    func testConcurrentQueriesOnDifferentReleasesStayIsolated() async throws {
        let index = try await twoPlatformIndex()
        try await withThrowingTaskGroup(of: (String, Bool).self) { group in
            for round in 0..<40 {
                let token = round.isMultiple(of: 2) ? Self.token8 : Self.token21
                group.addTask {
                    let names = await JavaIndex.$queryScope.withValue([token]) { await Self.memberNames("java.util.List", .staticOnly, index) }
                    return (token, names.contains("of"))
                }
            }
            for try await (token, hasOf) in group {
                XCTAssertEqual(hasOf, token == Self.token21, token)
            }
        }
    }

    /// Republishing the same platform readers changes nothing: no version bump, no re-analysis.
    func testRepublishingEquivalentPlatformsIsANoOp() async throws {
        let index = JavaIndex()
        let jdk = try shard("jdk21", Self.release21)
        let ct8 = try shard("ct8", Self.release8)
        let sources: [JavaIndex.Source] = [
            .init(precedence: 3, reader: jdk, shardPath: Self.token21, isDefaultPlatform: true),
            .init(precedence: 3, reader: ct8, shardPath: Self.token8),
        ]
        await index.setSources(sources)
        let before = await index.sourcesVersion
        await index.setSources(sources)
        let after = await index.sourcesVersion
        XCTAssertEqual(before, after)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor Counter {
    private(set) var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}
