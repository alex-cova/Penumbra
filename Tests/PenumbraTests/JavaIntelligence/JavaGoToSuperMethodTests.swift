import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaGoToSuperMethodTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-super-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Methods

    func testImplementationJumpsToInterfaceDeclaration() async throws {
        let shape = try write("Shape.java", "interface Shape { double area(); }")
        let hits = try await superHits("class Circle implements Shape { public double €area() { return 1; } }", indexing: [shape])
        XCTAssertEqual(hits.map(\.text), ["area"])
        XCTAssertEqual(hits.first?.location.url?.lastPathComponent, "Shape.java")
    }

    func testOverrideOfInterfaceDefaultMethod() async throws {
        let greeter = try write("Greeter.java", "interface Greeter { default String greet() { return \"hi\"; } }")
        let hits = try await superHits("class Loud implements Greeter { public String €greet() { return \"HI\"; } }", indexing: [greeter])
        XCTAssertEqual(hits.map(\.text), ["greet"])
        XCTAssertEqual(hits.first?.location.displayName, "Greeter.greet()")
    }

    func testOverrideOfAbstractClassMethodSkipsClassesThatDoNotDeclareIt() async throws {
        let base = try write("Base.java", "abstract class Base { abstract void run(String s); void run(int n) {} }")
        let mid = try write("Mid.java", "abstract class Mid extends Base { }")
        let hits = try await superHits("class Leaf extends Mid { void €run(String s) {} }", indexing: [base, mid])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.location.url?.lastPathComponent, "Base.java")
        // The `String` overload, not the `int` one declared after it.
        let hit = try XCTUnwrap(hits.first)
        XCTAssertLessThan(hit.location.range.start.utf16Offset, (hit.source as NSString).range(of: "run(int n)").location)
    }

    func testGenericInterfaceParameterMatchesTheTypeArgument() async throws {
        let cmp = try write("Cmp.java", "interface Cmp<T> { int compareTo(T other); }")
        let hits = try await superHits(
            "class Foo implements Cmp<Foo> { public int €compareTo(Foo other) { return 0; } }", indexing: [cmp]
        )
        XCTAssertEqual(hits.map(\.text), ["compareTo"])
        XCTAssertEqual(hits.first?.location.url?.lastPathComponent, "Cmp.java")
    }

    func testMultipleInterfacesListEachDeclaration() async throws {
        let a = try write("A.java", "interface A { void go(); }")
        let b = try write("B.java", "interface B { void go(); }")
        let hits = try await superHits("class C implements A, B { public void €go() {} }", indexing: [a, b])
        XCTAssertEqual(hits.compactMap { $0.location.url?.lastPathComponent }.sorted(), ["A.java", "B.java"])
    }

    func testMethodThatOverridesNothingResolvesToNothing() async throws {
        let base = try write("Base.java", "class Base { void other() {} }")
        let result = try await navigate("class Leaf extends Base { void €unrelated() {} }", indexing: [base])
        XCTAssertNil(result)
    }

    func testCaretInsideTheMethodBodyStillFindsTheSuperMethod() async throws {
        let shape = try write("Shape.java", "interface Shape { double area(); }")
        let hits = try await superHits("class Circle implements Shape { public double area() { return €1; } }", indexing: [shape])
        XCTAssertEqual(hits.map(\.text), ["area"])
    }

    // MARK: - Types

    func testClassNameListsSuperclassAndInterfaces() async throws {
        let base = try write("Base.java", "class Base { }")
        let runner = try write("Runner.java", "interface Runner { }")
        let hits = try await superHits("class €Leaf extends Base implements Runner { }", indexing: [base, runner])
        XCTAssertEqual(hits.compactMap { $0.location.url?.lastPathComponent }.sorted(), ["Base.java", "Runner.java"])
    }

    func testClassWithOnlyImplicitObjectResolvesToNothing() async throws {
        let result = try await navigate("class €Lonely { }", indexing: [])
        XCTAssertNil(result)
    }

    // MARK: - Family

    func testMethodFamilyCollectsSupersAndSiblingOverriders() async throws {
        let shape = try write("Shape.java", "interface Shape { double area(); }")
        let base = try write("Base.java", "abstract class Base implements Shape { public double area() { return 0; } }")
        let circle = try write("Circle.java", "class Circle extends Base { public double area() { return 1; } }")
        let square = try write("Square.java", "class Square implements Shape { public double area() { return 2; } }")
        let index = try await makeIndex([shape, base, circle, square])
        let baseStub = try XCTUnwrap(stubs(of: base).first)
        let method = try XCTUnwrap(baseStub.methods.first)
        let family = await JavaMethodFamily.family(of: method, declaringClass: "Base", index: index)
        XCTAssertEqual(family.first?.declaringClass, "Base")
        XCTAssertEqual(Set(family.map(\.declaringClass)), ["Base", "Shape", "Circle", "Square"])
        XCTAssertEqual(family.count, 4)
    }

    func testStaticMethodIsItsOwnFamily() async throws {
        let util = try write("Util.java", "class Util { static void help() {} } class Sub extends Util { static void help() {} }")
        let index = try await makeIndex([util])
        let stub = try XCTUnwrap(stubs(of: util).first { $0.qualifiedName == "Util" })
        let family = await JavaMethodFamily.family(of: try XCTUnwrap(stub.methods.first), declaringClass: "Util", index: index)
        XCTAssertEqual(family.count, 1)
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

    private func write(_ name: String, _ source: String) throws -> Fixture {
        let url = scratch.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return Fixture(url: url, source: source)
    }

    private func stubs(of fixture: Fixture) -> [JavaClassStub] {
        JavaSourceStubBuilder.build(source: fixture.source, url: fixture.url).classes
    }

    private func makeIndex(_ files: [Fixture]) async throws -> JavaIndex {
        let url = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(files.flatMap(stubs(of:)), stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: url))])
        return index
    }

    private func navigate(_ marked: String, indexing files: [Fixture]) async throws -> NavigationResult? {
        let index = try await makeIndex(files)
        let provider = JavaGoToDefinitionProvider(
            index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true))
        )
        return await provide(marked, url: scratch.appendingPathComponent("T.java"), provider: provider)
    }

    private func superHits(_ marked: String, indexing files: [Fixture]) async throws -> [Hit] {
        let locations: [Location]
        switch try await navigate(marked, indexing: files) {
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
            document: document, cursor: Cursor(position: position), selection: document.selection, kind: .superMethod
        ))
    }
}
