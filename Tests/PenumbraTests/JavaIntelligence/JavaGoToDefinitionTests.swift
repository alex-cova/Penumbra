import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// Counts how many times a decompiler-consent `request` closure was invoked.
private actor DecompileAskCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

final class JavaGoToDefinitionTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("java-nav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Project sources

    func testNavigatesToTypeInAnotherFileIncludingNestedType() async throws {
        let outer = try await write("Outer.java", """
        class Outer {
            static class Inner {}
        }
        """)
        let result = try await navigate("class T { Outer.€Inner x; }", indexing: [outer])
        let location = try single(result)
        XCTAssertEqual(selected(location, in: outer.source), "Inner")
        XCTAssertEqual(location.url?.lastPathComponent, "Outer.java")
    }

    func testNavigatesToMethodOnALocalWhoseTypeIsAnotherFile() async throws {
        let bar = try await write("Bar.java", """
        class Bar {
            void run() {}
        }
        """)
        let result = try await navigate("class T { void m() { Bar b = null; b.€run(); } }", indexing: [bar])
        let location = try single(result)
        XCTAssertEqual(selected(location, in: bar.source), "run")
        XCTAssertEqual(location.url?.standardizedFileURL.path, bar.url.standardizedFileURL.path)
    }

    func testNavigatesInheritedMethodToTheSuperclassDeclaration() async throws {
        let animal = try await write("Animal.java", """
        class Animal {
            void speak() {}
        }
        """)
        let dog = try await write("Dog.java", """
        class Dog extends Animal {}
        """)
        let result = try await navigate("class T { void m() { Dog d = null; d.€speak(); } }", indexing: [animal, dog])
        let location = try single(result)
        XCTAssertEqual(selected(location, in: animal.source), "speak")
        XCTAssertEqual(location.url?.lastPathComponent, "Animal.java")
    }

    func testNavigatesToFieldAndEnumConstant() async throws {
        let bar = try await write("Bar.java", """
        class Bar {
            int value;
        }
        """)
        let color = try await write("Color.java", """
        enum Color { RED, GREEN }
        """)
        let field = try await navigate("class T { void m(Bar b) { int n = b.€value; } }", indexing: [bar, color])
        XCTAssertEqual(selected(try single(field), in: bar.source), "value")
        let constant = try await navigate("class T { void m() { Color c = Color.€RED; } }", indexing: [bar, color])
        XCTAssertEqual(selected(try single(constant), in: color.source), "RED")
    }

    func testNavigatesToLocalAndParameterInTheSameFile() async throws {
        let local = try await navigate("class T { void m() { int value = 1; int copy = €value; } }")
        let localHit = try single(local)
        XCTAssertEqual(selected(localHit, in: "class T { void m() { int value = 1; int copy = value; } }"), "value")
        XCTAssertLessThan(localHit.range.start.utf16Offset, "class T { void m() { int value = 1; int copy = ".utf16.count)

        let parameter = try await navigate("class T { void m(int count) { int copy = €count; } }")
        let parameterHit = try single(parameter)
        XCTAssertEqual(selected(parameterHit, in: "class T { void m(int count) { int copy = count; } }"), "count")
        XCTAssertLessThan(parameterHit.range.start.utf16Offset, "class T { void m(int count) { int copy = ".utf16.count)
    }

    func testClickingADeclarationDoesNothing() async throws {
        let result = try await navigate("class T { void m() { int €value = 1; } }")
        XCTAssertNil(result)
    }

    func testNavigatesToTheMatchingConstructor() async throws {
        let bar = try await write("Bar.java", """
        class Bar {
            Bar(int x) {}
        }
        """)
        let result = try await navigate("class T { void m() { new €Bar(1); } }", indexing: [bar])
        let location = try single(result)
        XCTAssertEqual(selected(location, in: bar.source), "Bar")
        XCTAssertEqual(location.displayName, "Bar(int x)")
    }

    func testSameArityConstructorsReturnEveryMatch() async throws {
        let bar = try await write("Bar.java", """
        class Bar {
            Bar(int x) {}
            Bar(String s) {}
        }
        """)
        let result = try await navigate("class T { void m() { new €Bar(1); } }", indexing: [bar])
        guard case .multiple(let locations) = result else {
            return XCTFail("Expected both constructors, got \(String(describing: result))")
        }
        XCTAssertEqual(locations.count, 2)
        XCTAssertEqual(Set(locations.map(\.displayName)), ["Bar(int x)", "Bar(String s)"])
        let offsets = Set(locations.map { selected($0, in: bar.source) })
        XCTAssertEqual(offsets, ["Bar"])
        XCTAssertNotEqual(locations[0].range.start.utf16Offset, locations[1].range.start.utf16Offset)
    }

    func testNavigatesSingleTypeImportAndStaticImportCall() async throws {
        let bar = try await write("Bar.java", """
        package demo;
        class Bar {}
        """)
        let maths = try await write("Maths.java", """
        package demo;
        class Maths {
            public static int max(int a, int b) { return a; }
        }
        """)
        let imported = try await navigate("import demo.€Bar;\nclass T {}", indexing: [bar, maths])
        XCTAssertEqual(selected(try single(imported), in: bar.source), "Bar")

        let call = try await navigate("import static demo.Maths.max;\nclass T { void m() { int n = €max(1, 2); } }", indexing: [bar, maths])
        let location = try single(call)
        XCTAssertEqual(selected(location, in: maths.source), "max")
        XCTAssertEqual(location.url?.lastPathComponent, "Maths.java")
    }

    func testMainSourceSetDoesNotNavigateToATestOnlyType() async throws {
        let mainDir = scratch.appendingPathComponent("src/main/java", isDirectory: true)
        let testDir = scratch.appendingPathComponent("src/test/java", isDirectory: true)
        try FileManager.default.createDirectory(at: mainDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        let testOnly = try await write("TestOnly.java", "class TestOnly {}", in: testDir)
        let paths = JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true))
        let mainShard = paths.projectSourcesShard(for: mainDir.standardizedFileURL)
        let testShard = paths.projectSourcesShard(for: testDir.standardizedFileURL)
        let mainClass = JavaClassStub(
            binaryName: "Main", qualifiedName: "Main", simpleName: "Main", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            origin: .source(mainDir.appendingPathComponent("Main.java"), nameRange: 6..<10)
        )
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 1, reader: try writeShard([mainClass], to: mainShard), shardPath: mainShard.path),
            .init(precedence: 1, reader: try writeShard(stubs(of: testOnly), to: testShard), shardPath: testShard.path)
        ])
        let model = JavaGradleProjectModel(
            formatVersion: 2, gradleVersion: "9.0",
            subprojects: [.init(
                path: ":", directory: scratch,
                sourceSets: [
                    .init(name: "main", sourceDirs: [mainDir]),
                    .init(name: "test", sourceDirs: [testDir], projectDependencies: [.init(projectPath: ":", sourceSetName: "main")])
                ]
            )]
        )
        let provider = JavaGoToDefinitionProvider(index: index, indexPaths: paths)
        await provider.setSourceSetClasspath(model, indexPaths: paths)

        let fromMain = try await navigate(
            "class App { €TestOnly x; }", url: mainDir.appendingPathComponent("App.java"), provider: provider
        )
        XCTAssertNil(fromMain)

        let fromTest = try await navigate(
            "class AppTest { €TestOnly x; }", url: testDir.appendingPathComponent("AppTest.java"), provider: provider
        )
        XCTAssertEqual(selected(try single(fromTest), in: testOnly.source), "TestOnly")
    }

    // MARK: - Attached sources

    func testNavigatesJDKTypeThroughSrcZip() async throws {
        let jdk = scratch.appendingPathComponent("jdk", isDirectory: true)
        let sourceDir = jdk.appendingPathComponent("java.base/java/lang", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = "package java.lang;\npublic final class String {\n    public int length() { return 0; }\n}\n"
        try source.write(to: sourceDir.appendingPathComponent("String.java"), atomically: true, encoding: .utf8)
        let srcZip = jdk.appendingPathComponent("lib/src.zip")
        try FileManager.default.createDirectory(at: srcZip.deletingLastPathComponent(), withIntermediateDirectories: true)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = jdk
        zip.arguments = ["-qr", srcZip.path, "java.base"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let stringStub = JavaClassStub(
            binaryName: "java.lang.String", qualifiedName: "java.lang.String", simpleName: "String", packageName: "java.lang",
            kind: .classKind, modifiers: [.publicFlag, .finalFlag],
            methods: [JavaMethodStub(name: "length", parameters: [], returnType: .primitive(.int), modifiers: [.publicFlag])],
            origin: .jdkModule("java.base")
        )
        let index = try await makeIndex([stringStub])
        let paths = JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true))
        let provider = JavaGoToDefinitionProvider(index: index, indexPaths: paths)
        await provider.setJDKHome(jdk)

        let result = try await navigate(
            "class T { void m(String s) { int n = s.€length(); } }", provider: provider
        )
        let location = try single(result)
        let extracted = try String(contentsOf: try XCTUnwrap(location.url), encoding: .utf8)
        XCTAssertEqual(selected(location, in: extracted), "length")
        XCTAssertTrue(JavaAttachedSources.isExtractedSource(try XCTUnwrap(location.url)))
    }

    func testJarWithoutSourcesDoesNotNavigate() async throws {
        let jar = scratch.appendingPathComponent("lib.jar")
        FileManager.default.createFile(atPath: jar.path, contents: Data())
        let stub = JavaClassStub(
            binaryName: "Lib", qualifiedName: "Lib", simpleName: "Lib", packageName: "",
            kind: .classKind, modifiers: [.publicFlag], origin: .jar(jar)
        )
        let index = try await makeIndex([stub])
        let result = try await navigate("class T { €Lib x; }", index: index)
        XCTAssertNil(result)
    }

    // MARK: - Sunflower decompile fallback

    func testDecompilesJarClassWhenAgreementAccepted() async throws {
        let fixtureStub = try jarStub("Fixture")
        let index = try await makeIndex([fixtureStub])
        let paths = JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true))
        let provider = JavaGoToDefinitionProvider(index: index, indexPaths: paths)
        await provider.setDecompilerConsent(accepted: true, request: nil)

        let result = try await navigate(
            "import com.penumbra.fixture.Fixture;\nclass T { void m(Fixture f) { f.€add(1, 2); } }",
            index: index, provider: provider
        )
        let location = try single(result)
        XCTAssertEqual(location.displayName, "add(int a, int b)")
        let url = try XCTUnwrap(location.url)
        XCTAssertTrue(JavaAttachedSources.isExtractedSource(url))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(JavaDecompilerAgreement.sourceNotice))
        XCTAssertEqual(selected(location, in: text), "add")
    }

    func testDecompilesNestedClassMember() async throws {
        // Sunflower gives a nested type its own compilation unit, printed as `class Outer.Inner`
        // (see testNormalizesNestedDeclarationAndConstructorNames) — this checks the whole path
        // end to end: decompile, normalize, and locate a member inside that file.
        let fixtureStub = try jarStub("Fixture")
        let nestedStub = try jarStub("Fixture$Nested")
        let index = try await makeIndex([fixtureStub, nestedStub])
        let paths = JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true))
        let provider = JavaGoToDefinitionProvider(index: index, indexPaths: paths)
        await provider.setDecompilerConsent(accepted: true, request: nil)

        let result = try await navigate(
            "class T { void m(com.penumbra.fixture.Fixture.Nested n) { int v = n.€value; } }",
            index: index, provider: provider
        )
        let location = try single(result)
        let url = try XCTUnwrap(location.url)
        XCTAssertEqual(url.lastPathComponent, "Fixture$Nested.java")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(selected(location, in: text), "value")
        XCTAssertFalse(text.contains("Fixture.Nested"))
    }

    func testManualNavigationAsksOnceForAgreementThenPersists() async throws {
        let fixtureStub = try jarStub("Fixture")
        let index = try await makeIndex([fixtureStub])
        let paths = JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true))
        let provider = JavaGoToDefinitionProvider(index: index, indexPaths: paths)
        let asks = DecompileAskCounter()
        await provider.setDecompilerConsent(accepted: false, request: {
            await asks.increment()
            return true
        })

        let source = "import com.penumbra.fixture.Fixture;\nclass T { void m(Fixture f) { f.€add(1, 2); } }"
        let first = try await navigate(source, index: index, provider: provider)
        XCTAssertNotNil(first)
        let afterFirst = await asks.count
        XCTAssertEqual(afterFirst, 1)

        let second = try await navigate(source, index: index, provider: provider)
        XCTAssertNotNil(second)
        let afterSecond = await asks.count
        XCTAssertEqual(afterSecond, 1, "standing consent persisted on the provider; the agreement should not reappear")
    }

    func testDecliningConsentReturnsNilAndAsksAgainNextTime() async throws {
        let fixtureStub = try jarStub("Fixture")
        let index = try await makeIndex([fixtureStub])
        let paths = JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true))
        let provider = JavaGoToDefinitionProvider(index: index, indexPaths: paths)
        await provider.setDecompilerConsent(accepted: false, request: { false })

        let result = try await navigate(
            "import com.penumbra.fixture.Fixture;\nclass T { void m(Fixture f) { f.€add(1, 2); } }",
            index: index, provider: provider
        )
        XCTAssertNil(result)
    }

    func testHoverTriggerNeverAsksForConsent() async throws {
        let fixtureStub = try jarStub("Fixture")
        let index = try await makeIndex([fixtureStub])
        let paths = JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true))
        let provider = JavaGoToDefinitionProvider(index: index, indexPaths: paths)
        let asks = DecompileAskCounter()
        await provider.setDecompilerConsent(accepted: false, request: {
            await asks.increment()
            return true
        })

        let source = "import com.penumbra.fixture.Fixture;\nclass T { void m(Fixture f) { f.add(1, 2); } }"
        let marker = try XCTUnwrap(source.range(of: "add"))
        let utf16 = source.utf16.distance(from: source.utf16.startIndex, to: marker.lowerBound.samePosition(in: source.utf16)!)
        let position = JavaNavigationText.position(utf16Offset: utf16, in: source)
        let document = Document(
            url: scratch.appendingPathComponent("T.java"), displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        let result = await provider.provide(context: NavigationContext(
            document: document, cursor: Cursor(position: position), selection: document.selection,
            trigger: .idle, kind: .definition
        ))
        XCTAssertNil(result)
        let count = await asks.count
        XCTAssertEqual(count, 0, "Cmd-hover must never pop the Sunflower agreement")
    }

    func testNormalizesNestedDeclarationAndConstructorNames() {
        let source = """
        package com.penumbra.fixture;

        public final record Fixture.Point(int x, int y) {
            public Fixture.Point(int value, int value1) {
                this.x = value;
                this.y = value1;
            }

            public int x() {
                return this.x;
            }
        }
        """
        let normalized = JavaClassDecompiler.normalizeTypeName(source, simpleName: "Point", dottedName: "Fixture.Point")
        XCTAssertTrue(normalized.contains("record Point(int x, int y)"))
        XCTAssertTrue(normalized.contains("public Point(int value, int value1)"))
        XCTAssertFalse(normalized.contains("Fixture.Point"))
    }

    func testNonJavaDocumentReturnsNil() async throws {
        let index = try await makeIndex([])
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let document = Document(
            url: scratch.appendingPathComponent("Test.kt"), displayName: "Test.kt",
            contentSnapshot: TextSnapshot(version: 0, text: "class T { Lib x; }"),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "kotlin"
        )
        let provider = JavaGoToDefinitionProvider(index: index, indexPaths: JavaIndexPaths(root: scratch))
        let result = await provider.provide(context: NavigationContext(
            document: document, cursor: document.cursor, selection: document.selection, kind: .definition
        ))
        XCTAssertNil(result)
    }

    func testGenericProviderSkipsJava() async throws {
        let index = SymbolIndex()
        let documentID = DocumentID()
        let range = TextRange(
            start: TextPosition(line: 0, column: 0, utf16Offset: 0),
            end: TextPosition(line: 0, column: 3, utf16Offset: 3)
        )
        await index.index([Symbol(name: "Bar", kind: .type, documentID: documentID, range: range)], for: documentID)
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let document = Document(
            id: documentID, displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 0, text: "Bar"),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 10, height: 10),
            languageIdentifier: "java"
        )
        let provider = GoToDefinitionProvider(index: index, skippingLanguages: ["java"])
        let result = await provider.provide(context: NavigationContext(
            document: document, cursor: document.cursor, selection: document.selection, kind: .definition
        ))
        XCTAssertNil(result)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let url: URL
        let source: String
    }

    private func write(_ name: String, _ source: String, in directory: URL? = nil) async throws -> Fixture {
        let folder = directory ?? scratch!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return Fixture(url: url, source: source)
    }

    private func stubs(of fixture: Fixture) -> [JavaClassStub] {
        JavaSourceStubBuilder.build(source: fixture.source, url: fixture.url).classes
    }

    /// A stub read from a real `.class` fixture (`Tests/PenumbraTests/Fixtures/Java`), attributed
    /// to `JavaFixtures.jarURL` so the decompile fallback has real bytecode and a real archive to
    /// key its cache off of. `name` is the `.class` file's base name, e.g. `"Fixture$Point"`.
    private func jarStub(_ name: String) throws -> JavaClassStub {
        try ClassFileReader.read(JavaFixtures.classFile(name), origin: .jar(JavaFixtures.jarURL))
    }

    private func writeShard(_ stubs: [JavaClassStub], to url: URL? = nil) throws -> JavaIndexShardReader {
        let url = url ?? scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        return try JavaIndexShardReader(url: url)
    }

    private func makeIndex(_ stubs: [JavaClassStub]) async throws -> JavaIndex {
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try writeShard(stubs))])
        return index
    }

    private func navigate(
        _ marked: String,
        indexing files: [Fixture] = [],
        url: URL? = nil,
        index existing: JavaIndex? = nil,
        provider existingProvider: JavaGoToDefinitionProvider? = nil
    ) async throws -> NavigationResult? {
        let index: JavaIndex
        if let existing {
            index = existing
        } else {
            index = try await makeIndex(files.flatMap(stubs(of:)))
        }
        let provider = existingProvider ?? JavaGoToDefinitionProvider(
            index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true))
        )
        return try await navigate(marked, url: url ?? scratch.appendingPathComponent("T.java"), provider: provider)
    }

    private func navigate(_ marked: String, url: URL, provider: JavaGoToDefinitionProvider) async throws -> NavigationResult? {
        let marker = try XCTUnwrap(marked.range(of: "€"))
        let source = marked.replacingOccurrences(of: "€", with: "")
        let utf16 = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
        let position = JavaNavigationText.position(utf16Offset: utf16, in: source)
        let document = Document(
            url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        return await provider.provide(context: NavigationContext(
            document: document, cursor: Cursor(position: position), selection: document.selection, kind: .definition
        ))
    }

    private func single(_ result: NavigationResult?) throws -> Location {
        guard case .single(let location) = result else {
            XCTFail("Expected one location, got \(String(describing: result))")
            throw CancellationError()
        }
        return location
    }

    private func selected(_ location: Location, in source: String) -> String {
        let ns = source as NSString
        let start = max(0, min(location.range.start.utf16Offset, ns.length))
        let end = max(start, min(location.range.end.utf16Offset, ns.length))
        return ns.substring(with: NSRange(location: start, length: end - start))
    }
}
