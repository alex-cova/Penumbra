import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaGoToImplementationTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-impl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Types

    func testInterfaceNameInAReferenceListsEveryImplementor() async throws {
        let shape = try write("Shape.java", "interface Shape { double area(); }")
        let circle = try write("Circle.java", "class Circle implements Shape { public double area() { return 1; } }")
        let square = try write("Square.java", "class Square implements Shape { public double area() { return 2; } }")
        let other = try write("Other.java", "class Other { }")
        let hits = try await implementations("class T { €Shape s; }", indexing: [shape, circle, square, other])
        XCTAssertEqual(hits.map(\.text).sorted(), ["Circle", "Square"])
    }

    func testCaretOnATypeDeclarationNameListsSubtypesTransitively() async throws {
        let base = try write("Base.java", "abstract class Base { }")
        let mid = try write("Mid.java", "abstract class Mid extends Base { }")
        let leaf = try write("Leaf.java", "class Leaf extends Mid { }")
        let hits = try await implementations("abstract class €Base { }", url: base.url, indexing: [base, mid, leaf])
        XCTAssertEqual(hits.map(\.text).sorted(), ["Leaf", "Mid"])
    }

    func testTypeWithoutSubtypesResolvesToNothing() async throws {
        let lonely = try write("Lonely.java", "class Lonely { }")
        let result = try await navigate("class T { €Lonely l; }", indexing: [lonely])
        XCTAssertNil(result)
    }

    // MARK: - Methods

    func testAbstractMethodCallListsEveryOverride() async throws {
        let shape = try write("Shape.java", "interface Shape { double area(); }")
        let circle = try write("Circle.java", "class Circle implements Shape { public double area() { return 1; } }")
        let square = try write("Square.java", "class Square implements Shape { public double area() { return 2; } }")
        let hits = try await implementations(
            "class T { double m(Shape s) { return s.€area(); } }", indexing: [shape, circle, square]
        )
        XCTAssertEqual(hits.map(\.text), ["area", "area"])
        XCTAssertEqual(hits.compactMap { $0.location.url?.lastPathComponent }.sorted(), ["Circle.java", "Square.java"])
    }

    func testCaretOnAMethodDeclarationListsOverridesInSubclasses() async throws {
        let base = try write("Base.java", "abstract class Base { abstract void run(); }")
        let child = try write("Child.java", "class Child extends Base { void run() {} }")
        let hits = try await implementations(
            "abstract class Base { abstract void €run(); }", url: base.url, indexing: [base, child]
        )
        XCTAssertEqual(hits.map(\.text), ["run"])
        XCTAssertEqual(hits.first?.location.url?.lastPathComponent, "Child.java")
    }

    func testOverloadsWithDifferentParametersAreNotOverrides() async throws {
        let base = try write("Base.java", "abstract class Base { abstract void run(String s); }")
        let child = try write("Child.java", "class Child extends Base { void run(String s) {} void run(int n) {} }")
        let hits = try await implementations(
            "abstract class Base { abstract void €run(String s); }", url: base.url, indexing: [base, child]
        )
        XCTAssertEqual(hits.count, 1)
        let source = try XCTUnwrap(hits.first).source
        let location = try XCTUnwrap(hits.first).location
        let nsSource = source as NSString
        // The single hit is the `String` overload: the `int` one is declared after it.
        let intOverload = nsSource.range(of: "run(int n)").location
        XCTAssertLessThan(location.range.start.utf16Offset, intOverload)
    }

    func testInterfaceRedeclarationIsNotAnImplementation() async throws {
        let base = try write("Base.java", "interface Base { void run(); }")
        let sub = try write("Sub.java", "interface Sub extends Base { void run(); }")
        let impl = try write("Impl.java", "class Impl implements Sub { public void run() {} }")
        let hits = try await implementations(
            "interface Base { void €run(); }", url: base.url, indexing: [base, sub, impl]
        )
        XCTAssertEqual(hits.compactMap { $0.location.url?.lastPathComponent }, ["Impl.java"])
    }

    func testStaticAndConstructorMembersAreNotImplementations() async throws {
        let base = try write("Base.java", "class Base { void run() {} }")
        let child = try write("Child.java", "class Child extends Base { static void run() {} Child() {} }")
        let result = try await navigate("class Base { void €run() {} }", url: base.url, indexing: [base, child])
        XCTAssertNil(result)
    }

    // MARK: - Scope

    func testMainSourceSetDoesNotSeeATestOnlyImplementor() async throws {
        let mainDir = scratch.appendingPathComponent("src/main/java", isDirectory: true)
        let testDir = scratch.appendingPathComponent("src/test/java", isDirectory: true)
        let service = try write("Service.java", "interface Service { }", in: mainDir)
        let fake = try write("FakeService.java", "class FakeService implements Service { }", in: testDir)
        let paths = JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true))
        let mainShard = paths.projectSourcesShard(for: mainDir.standardizedFileURL)
        let testShard = paths.projectSourcesShard(for: testDir.standardizedFileURL)
        let index = JavaIndex()
        await index.setSources([
            .init(precedence: 1, reader: try writeShard(stubs(of: service), to: mainShard), shardPath: mainShard.path),
            .init(precedence: 1, reader: try writeShard(stubs(of: fake), to: testShard), shardPath: testShard.path)
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

        let fromMain = await provide(
            "class App { €Service s; }", url: mainDir.appendingPathComponent("App.java"), provider: provider
        )
        XCTAssertNil(fromMain)
        let fromTest = await provide(
            "class AppTest { €Service s; }", url: testDir.appendingPathComponent("AppTest.java"), provider: provider
        )
        guard case .single(let location)? = fromTest else { return XCTFail("Expected FakeService, got \(String(describing: fromTest))") }
        XCTAssertEqual(location.url?.lastPathComponent, "FakeService.java")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let url: URL
        let source: String
    }

    private struct Hit {
        let location: Location
        let source: String
        var text: String {
            let ns = source as NSString
            let start = max(0, min(location.range.start.utf16Offset, ns.length))
            let end = max(start, min(location.range.end.utf16Offset, ns.length))
            return ns.substring(with: NSRange(location: start, length: end - start))
        }
    }

    private func write(_ name: String, _ source: String, in directory: URL? = nil) throws -> Fixture {
        let folder = directory ?? scratch!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return Fixture(url: url, source: source)
    }

    private func stubs(of fixture: Fixture) -> [JavaClassStub] {
        JavaSourceStubBuilder.build(source: fixture.source, url: fixture.url).classes
    }

    private func writeShard(_ stubs: [JavaClassStub], to url: URL? = nil) throws -> JavaIndexShardReader {
        let url = url ?? scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        return try JavaIndexShardReader(url: url)
    }

    private func navigate(_ marked: String, url: URL? = nil, indexing files: [Fixture]) async throws -> NavigationResult? {
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try writeShard(files.flatMap(stubs(of:))))])
        let provider = JavaGoToDefinitionProvider(
            index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true))
        )
        return await provide(marked, url: url ?? scratch.appendingPathComponent("T.java"), provider: provider)
    }

    private func implementations(_ marked: String, url: URL? = nil, indexing files: [Fixture]) async throws -> [Hit] {
        let result = try await navigate(marked, url: url, indexing: files)
        let locations: [Location]
        switch result {
        case .single(let location)?: locations = [location]
        case .multiple(let all)?: locations = all
        case nil: return []
        }
        return try locations.map { location in
            let url = try XCTUnwrap(location.url)
            return Hit(location: location, source: try String(contentsOf: url, encoding: .utf8))
        }
    }

    private func provide(_ marked: String, url: URL, provider: JavaGoToDefinitionProvider) async -> NavigationResult? {
        let marker = marked.range(of: "€")!
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
            document: document, cursor: Cursor(position: position), selection: document.selection, kind: .implementation
        ))
    }
}
