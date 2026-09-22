import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaCompletionProviderTests: XCTestCase {
    private func tempShardURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
    }

    private func makeIndex(withStubs stubs: [JavaClassStub]) async throws -> JavaIndex {
        let url = tempShardURL()
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let reader = try JavaIndexShardReader(url: url)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])
        return index
    }

    private func classType(_ name: String) -> JavaTypeRef {
        .classType(qualifiedName: name, arguments: [], outer: nil)
    }

    /// `€` marks the cursor. Builds a `Document` + `CompletionContext` (via the real
    /// `makeCompletionContext`, exercising the same prefix/range logic Umbra itself uses) and runs
    /// the provider.
    private func complete(
        _ source: String,
        index: JavaIndex,
        trigger: RequestTrigger = .manual,
        url: URL? = URL(fileURLWithPath: "/tmp/Test.java"),
        provider: JavaCompletionProvider? = nil
    ) async -> [CompletionItem] {
        let markerRange = source.range(of: "€")!
        let withoutMarker = source.replacingOccurrences(of: "€", with: "")
        let utf16Offset = source.utf16.distance(from: source.utf16.startIndex, to: markerRange.lowerBound.samePosition(in: source.utf16)!)
        let position = textPosition(in: withoutMarker, utf16Offset: utf16Offset)
        let snapshot = TextSnapshot(version: 0, text: withoutMarker)
        let document = Document(
            id: DocumentID(), url: url, displayName: url?.lastPathComponent ?? "Test.java",
            contentSnapshot: snapshot, selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position), viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        let context = makeCompletionContext(document: document, trigger: trigger)
        let resolved = provider ?? JavaCompletionProvider(index: index)
        return await resolved.provide(context: context)
    }

    private func textPosition(in text: String, utf16Offset: Int) -> TextPosition {
        let prefix = String(text.utf16.prefix(utf16Offset)) ?? ""
        let lines = prefix.components(separatedBy: "\n")
        let line = lines.count - 1
        let column = (lines.last ?? "").utf16.count
        return TextPosition(line: line, column: column, utf16Offset: utf16Offset)
    }

    private func names(_ items: [CompletionItem]) -> Set<String> {
        Set(items.map(\.label))
    }

    private func stringStub() -> JavaClassStub {
        JavaClassStub(
            binaryName: "java.lang.String", qualifiedName: "java.lang.String", simpleName: "String", packageName: "java.lang",
            kind: .classKind, modifiers: [.publicFlag, .finalFlag],
            methods: [
                JavaMethodStub(name: "length", parameters: [], returnType: .primitive(.int), modifiers: [.publicFlag]),
                JavaMethodStub(name: "trim", parameters: [], returnType: classType("java.lang.String"), modifiers: [.publicFlag])
            ],
            origin: .jdkModule("test")
        )
    }

    // MARK: - Non-Java documents are ignored

    func testIgnoresNonJavaDocuments() async throws {
        let index = try await makeIndex(withStubs: [])
        let snapshot = TextSnapshot(version: 0, text: "class Foo { void m() { foo; } }")
        let position = TextPosition(line: 0, column: 24, utf16Offset: 24)
        let document = Document(
            id: DocumentID(), url: nil, displayName: "Test.kt", contentSnapshot: snapshot,
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "kotlin"
        )
        let context = makeCompletionContext(document: document, trigger: .manual)
        let items = await JavaCompletionProvider(index: index).provide(context: context)
        XCTAssertEqual(items, [])
    }

    // MARK: - Member access

    func testMemberAccessOffersFieldsAndMethods() async throws {
        let bar = JavaClassStub(
            binaryName: "Bar", qualifiedName: "Bar", simpleName: "Bar", packageName: "", kind: .classKind, modifiers: [.publicFlag],
            fields: [JavaFieldStub(name: "value", type: .primitive(.int), modifiers: [.publicFlag])],
            methods: [JavaMethodStub(name: "getValue", parameters: [], returnType: .primitive(.int), modifiers: [.publicFlag])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [bar])
        let items = await complete("class Foo { void m(Bar bar) { bar.€ } }", index: index)
        XCTAssertTrue(names(items).contains("value"))
        XCTAssertTrue(names(items).contains("getValue"))
        let getValue = try XCTUnwrap(items.first { $0.label == "getValue" })
        XCTAssertEqual(getValue.kind, .method)
        XCTAssertEqual(getValue.insertText, "getValue()")
        let value = try XCTUnwrap(items.first { $0.label == "value" })
        XCTAssertEqual(value.kind, .property)
        XCTAssertEqual(value.insertText, "value")
    }

    func testMemberAccessFiltersByPrefix() async throws {
        let index = try await makeIndex(withStubs: [stringStub()])
        let items = await complete("class Foo { void m(String s) { s.tr€ } }", index: index)
        XCTAssertEqual(names(items), ["trim"])
    }

    func testMemberAccessOnRealChainedMethodCall() async throws {
        let bar = JavaClassStub(
            binaryName: "Bar", qualifiedName: "Bar", simpleName: "Bar", packageName: "", kind: .classKind, modifiers: [.publicFlag],
            methods: [JavaMethodStub(name: "getName", parameters: [], returnType: classType("java.lang.String"), modifiers: [.publicFlag])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [bar, stringStub()])
        let items = await complete("class Foo { void m(Bar bar) { bar.getName().€ } }", index: index)
        XCTAssertTrue(names(items).contains("trim"))
        XCTAssertTrue(names(items).contains("length"))
    }

    func testMemberAccessOnTypeQualifierOffersOnlyStaticMembers() async throws {
        let util = JavaClassStub(
            binaryName: "Util", qualifiedName: "Util", simpleName: "Util", packageName: "", kind: .classKind, modifiers: [.publicFlag],
            methods: [
                JavaMethodStub(name: "staticHelper", parameters: [], returnType: .void, modifiers: [.publicFlag, .staticFlag]),
                JavaMethodStub(name: "instanceHelper", parameters: [], returnType: .void, modifiers: [.publicFlag])
            ],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [util])
        let items = await complete("class Foo { void m() { Util.€ } }", index: index)
        XCTAssertTrue(names(items).contains("staticHelper"))
        XCTAssertFalse(names(items).contains("instanceHelper"))
    }

    func testMemberAccessOnUnresolvableReceiverReturnsEmpty() async throws {
        let index = try await makeIndex(withStubs: [])
        let items = await complete("class Foo { void m() { totallyUnknown.€ } }", index: index)
        XCTAssertEqual(items, [])
    }

    // MARK: - General / statement position

    func testGeneralPositionOffersLocalsMatchingPrefix() async throws {
        let index = try await makeIndex(withStubs: [])
        let items = await complete("class Foo { void m() { int alpha = 1; int beta = 2; al€ } }", index: index)
        XCTAssertTrue(names(items).contains("alpha"))
        XCTAssertFalse(names(items).contains("beta"))
        let alpha = try XCTUnwrap(items.first { $0.label == "alpha" })
        XCTAssertEqual(alpha.kind, .variable)
    }

    func testGeneralPositionOffersParameters() async throws {
        let index = try await makeIndex(withStubs: [])
        let items = await complete("class Foo { void m(int count) { co€ } }", index: index)
        XCTAssertTrue(names(items).contains("count"))
    }

    func testGeneralPositionOffersImplicitThisMembers() async throws {
        let foo = JavaClassStub(
            binaryName: "Foo", qualifiedName: "Foo", simpleName: "Foo", packageName: "", kind: .classKind, modifiers: [.publicFlag],
            fields: [JavaFieldStub(name: "counter", type: .primitive(.int), modifiers: [.privateFlag])],
            origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [foo])
        let items = await complete("class Foo { void m() { coun€ } }", index: index)
        XCTAssertTrue(names(items).contains("counter"))
    }

    func testGeneralPositionOffersClassNamesByPrefix() async throws {
        let list = JavaClassStub(
            binaryName: "java.util.ArrayList", qualifiedName: "java.util.ArrayList", simpleName: "ArrayList", packageName: "java.util",
            kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("test")
        )
        let index = try await makeIndex(withStubs: [list])
        let items = await complete("class Foo { void m() { Array€ } }", index: index)
        XCTAssertTrue(names(items).contains("ArrayList"))
        let item = try XCTUnwrap(items.first { $0.label == "ArrayList" })
        XCTAssertEqual(item.kind, .type)
    }

    func testGeneralPositionOffersMatchingKeywords() async throws {
        let index = try await makeIndex(withStubs: [])
        let items = await complete("class Foo { void m() { ret€ } }", index: index)
        XCTAssertTrue(items.contains { $0.label == "return" && $0.kind == .keyword })
    }

    func testGeneralPositionWithEmptyPrefixDoesNotOfferClassNamesOrKeywords() async throws {
        // An empty prefix (e.g. right after whitespace) would make prefix-based class/keyword
        // completion meaninglessly broad; locals/fields are still offered since those come from a
        // small, already-scoped set.
        let index = try await makeIndex(withStubs: [])
        let items = await complete("class Foo { void m() { int alpha = 1; €} }", index: index)
        XCTAssertFalse(items.contains { $0.kind == .keyword })
        XCTAssertFalse(items.contains { $0.kind == .type })
    }

    // MARK: - Source-set classpath scope

    func testSourceSetScopeHidesTestOnlyClassesFromMain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let mainDir = root.appendingPathComponent("src/main/java", isDirectory: true)
        let testDir = root.appendingPathComponent("src/test/java", isDirectory: true)
        try FileManager.default.createDirectory(at: mainDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mainJar = URL(fileURLWithPath: "/deps/main.jar")
        let testJar = URL(fileURLWithPath: "/deps/test-only.jar")
        let paths = JavaIndexPaths(root: root.appendingPathComponent("index"))
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let mainShard = paths.jarShard(mainJar)
        let testShard = paths.jarShard(testJar)
        let mainStub = JavaClassStub(
            binaryName: "com.example.MainDep", qualifiedName: "com.example.MainDep", simpleName: "MainDep",
            packageName: "com.example", kind: .classKind, modifiers: [.publicFlag], origin: .jar(mainJar)
        )
        let testStub = JavaClassStub(
            binaryName: "com.example.TestOnly", qualifiedName: "com.example.TestOnly", simpleName: "TestOnly",
            packageName: "com.example", kind: .classKind, modifiers: [.publicFlag], origin: .jar(testJar)
        )
        try JavaIndexShardWriter().write([mainStub], stamp: JavaStamp(size: 1, modificationDate: 0), to: mainShard)
        try JavaIndexShardWriter().write([testStub], stamp: JavaStamp(size: 1, modificationDate: 0), to: testShard)
        let jdkURL = tempShardURL()
        defer { try? FileManager.default.removeItem(at: jdkURL) }
        try JavaIndexShardWriter().write([stringStub()], stamp: JavaStamp(size: 0, modificationDate: 0), to: jdkURL)

        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 3, reader: try JavaIndexShardReader(url: jdkURL)),
            .init(precedence: 2, reader: try JavaIndexShardReader(url: mainShard), shardPath: mainShard.path),
            .init(precedence: 2, reader: try JavaIndexShardReader(url: testShard), shardPath: testShard.path)
        ])
        let model = JavaGradleProjectModel(
            formatVersion: 2,
            gradleVersion: "9.0",
            subprojects: [
                .init(
                    path: ":",
                    directory: root,
                    sourceSets: [
                        .init(name: "main", sourceDirs: [mainDir], compileClasspathJars: [mainJar]),
                        .init(
                            name: "test",
                            sourceDirs: [testDir],
                            compileClasspathJars: [mainJar, testJar],
                            projectDependencies: [.init(projectPath: ":", sourceSetName: "main")]
                        )
                    ]
                )
            ]
        )
        let mainScope = try XCTUnwrap(model.visibleShardPaths(forFile: mainDir.appendingPathComponent("App.java"), paths: paths))
        let unscopedTestOnly = await index.classStub(qualifiedName: "com.example.TestOnly")
        XCTAssertNotNil(unscopedTestOnly)
        let scoped = await JavaIndex.$queryScope.withValue(mainScope) {
            (
                await index.classStub(qualifiedName: "com.example.TestOnly"),
                await index.classStub(qualifiedName: "com.example.MainDep"),
                await index.classStub(qualifiedName: "java.lang.String"),
                await index.classes(simpleNamePrefix: "Test", limit: 20).map(\.qualifiedName)
            )
        }
        XCTAssertNil(scoped.0, "test-only jar is not on the main compile classpath")
        XCTAssertNotNil(scoped.1)
        XCTAssertNotNil(scoped.2, "the JDK stays visible inside a source-set scope")
        XCTAssertFalse(scoped.3.contains("com.example.TestOnly"))

        let provider = JavaCompletionProvider(index: index)
        await provider.setSourceSetClasspath(model, indexPaths: paths)
        let fromMain = await complete("class Foo { Te€ }", index: index, url: mainDir.appendingPathComponent("App.java"), provider: provider)
        let fromTest = await complete("class Foo { Te€ }", index: index, url: testDir.appendingPathComponent("AppTest.java"), provider: provider)
        XCTAssertFalse(names(fromMain).contains("TestOnly"))
        XCTAssertTrue(names(fromTest).contains("TestOnly"))
    }

    // MARK: - Real JDK, end-to-end (opt-in)

    func testRealMemberAccessOnJavaLangString() async throws {
        guard let found = TestJDK.discovered, let installation = ReleaseFileParser.parse(found.home), installation.hasCtSym else {
            throw XCTSkip("No JDK with ct.sym found on this machine")
        }
        let stubs = try JDKCtSymRoot(installation: installation).readStubs()
        let url = tempShardURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: try JavaIndexShardReader(url: url))])

        let items = await complete("class Foo { void m(String s) { s.isBla€ } }", index: index)
        XCTAssertTrue(names(items).contains("isBlank"))
    }
}
