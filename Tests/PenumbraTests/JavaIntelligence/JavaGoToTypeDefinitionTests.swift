import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// Go to Type Declaration (⌃⇧B): from a symbol or expression to the declaration of its type.
final class JavaGoToTypeDefinitionTests: XCTestCase {
    private struct Fixture {
        let url: URL
        let source: String
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("java-type-nav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private let bar = "class Bar { void run() {} Baz make() { return null; } Baz baz; }"
    private let baz = "class Baz {}"

    // MARK: - Variables

    func testFromALocalUse() async throws {
        let result = try await typeDeclaration("class T { void m() { Bar b = null; €b.run(); } }")
        XCTAssertEqual(try selected(single(result), in: bar), "Bar")
    }

    func testFromALocalDeclarationName() async throws {
        let result = try await typeDeclaration("class T { void m() { Bar €b = null; } }")
        XCTAssertEqual(try selected(single(result), in: bar), "Bar")
    }

    func testFromAParameterAndItsDeclaration() async throws {
        let use = try await typeDeclaration("class T { void m(Bar p) { €p.run(); } }")
        XCTAssertEqual(try selected(single(use), in: bar), "Bar")
        let declaration = try await typeDeclaration("class T { void m(Bar €p) { } }")
        XCTAssertEqual(try selected(single(declaration), in: bar), "Bar")
    }

    func testFromAFieldOfTheEnclosingClass() async throws {
        let result = try await typeDeclaration("class T { Bar bar; void m() { €bar.run(); } }")
        XCTAssertEqual(try selected(single(result), in: bar), "Bar")
    }

    func testFromAVarDeclarationAndItsUse() async throws {
        let use = try await typeDeclaration("class T { void m() { var b = new Bar(); €b.run(); } }")
        XCTAssertEqual(try selected(single(use), in: bar), "Bar")
        let declaration = try await typeDeclaration("class T { void m() { var €b = new Bar(); } }")
        XCTAssertEqual(try selected(single(declaration), in: bar), "Bar")
    }

    func testAnArrayGoesToItsElementType() async throws {
        let result = try await typeDeclaration("class T { void m(Bar[] items) { €items.toString(); } }")
        XCTAssertEqual(try selected(single(result), in: bar), "Bar")
    }

    // MARK: - Members and calls

    func testFromAMethodCallToItsReturnType() async throws {
        let result = try await typeDeclaration("class T { void m(Bar b) { b.€make(); } }")
        XCTAssertEqual(try selected(single(result), in: baz), "Baz")
    }

    func testFromAFieldAccessToTheFieldType() async throws {
        let result = try await typeDeclaration("class T { void m(Bar b) { Object o = b.€baz; } }")
        XCTAssertEqual(try selected(single(result), in: baz), "Baz")
    }

    func testFromAMethodDeclarationToItsReturnType() async throws {
        let result = try await typeDeclaration("class T { Bar €make() { return null; } }")
        XCTAssertEqual(try selected(single(result), in: bar), "Bar")
    }

    func testGenericSubstitutionGivesTheTypeArgument() async throws {
        let box = "class Box<E> { E get() { return null; } }"
        let result = try await typeDeclaration(
            "class T { void m(Box<Baz> box) { box.€get(); } }", extra: [("Box.java", box)]
        )
        XCTAssertEqual(try selected(single(result), in: baz), "Baz", "The type argument, not the type variable E")
    }

    func testAGenericTypeGoesToItsOuterClass() async throws {
        let box = "class Box<E> { }"
        let result = try await typeDeclaration(
            "class T { void m(Box<Baz> €box) { } }", extra: [("Box.java", box)]
        )
        XCTAssertEqual(try selected(single(result), in: box), "Box")
    }

    // MARK: - Types and keywords

    func testATypeReferenceGoesToTheTypeItself() async throws {
        let result = try await typeDeclaration("class T { void m() { €Bar b = null; } }")
        XCTAssertEqual(try selected(single(result), in: bar), "Bar")
    }

    func testANewExpressionGoesToTheClassNotTheConstructor() async throws {
        let withConstructor = "class Bar { Bar(int x) {} }"
        let result = try await typeDeclaration(
            "class T { void m() { new €Bar(1); } }", bar: withConstructor
        )
        XCTAssertEqual(try selected(single(result), in: withConstructor), "Bar")
    }

    func testThisGoesToTheEnclosingClass() async throws {
        let source = "class T { void m() { €this.toString(); } }"
        let location = try single(try await typeDeclaration(source))
        XCTAssertEqual(selected(location, in: source.replacingOccurrences(of: "€", with: "")), "T")
    }

    func testAnEnumConstantGoesToItsEnum() async throws {
        let source = "enum Color { €RED, GREEN }"
        let location = try single(try await typeDeclaration(source))
        XCTAssertEqual(selected(location, in: source.replacingOccurrences(of: "€", with: "")), "Color")
    }

    func testATypeDeclarationIsItsOwnTypeDeclaration() async throws {
        let source = "class €T { }"
        let location = try single(try await typeDeclaration(source))
        XCTAssertEqual(selected(location, in: source.replacingOccurrences(of: "€", with: "")), "T")
    }

    func testATypeVariableGoesToItsParameterFromTheDeclaration() async throws {
        // At a use site the expression typer gives a value of type `E` its bound, so only the
        // declaration reaches the type parameter itself.
        let source = "class Box<E> { E €value; }"
        let location = try single(try await typeDeclaration(source))
        XCTAssertEqual(selected(location, in: source.replacingOccurrences(of: "€", with: "")), "E")
    }

    // MARK: - Nothing to go to

    func testPrimitivesHaveNoTypeDeclaration() async throws {
        let use = try await typeDeclaration("class T { void m() { int n = 1; int k = €n; } }")
        XCTAssertNil(use)
        let declaration = try await typeDeclaration("class T { void m() { int €n = 1; } }")
        XCTAssertNil(declaration)
    }

    func testVoidMethodHasNoTypeDeclaration() async throws {
        let result = try await typeDeclaration("class T { void €m() { } }")
        XCTAssertNil(result)
    }

    func testOtherKindsOfNavigationAreUnaffected() async throws {
        // Definition still goes to the declaration of the variable, not its type.
        let source = "class T { void m() { Bar b = null; b.run(); } }"
        let marked = "class T { void m() { Bar b = null; €b.run(); } }"
        let result = try await navigate(marked, kind: .definition, files: [("Bar.java", bar), ("Baz.java", baz)])
        let location = try single(result)
        XCTAssertEqual(selected(location, in: source), "b")
    }

    // MARK: - Helpers

    private func typeDeclaration(
        _ marked: String, bar barSource: String? = nil, extra: [(String, String)] = []
    ) async throws -> NavigationResult? {
        try await navigate(marked, kind: .typeDefinition,
                           files: [("Bar.java", barSource ?? bar), ("Baz.java", baz)] + extra)
    }

    private func navigate(_ marked: String, kind: NavigationKind, files: [(String, String)]) async throws -> NavigationResult? {
        var stubs: [JavaClassStub] = []
        for (name, source) in files {
            let url = scratch.appendingPathComponent(name)
            try source.write(to: url, atomically: true, encoding: .utf8)
            stubs.append(contentsOf: JavaSourceStubBuilder.build(source: source, url: url).classes)
        }
        let source = marked.replacingOccurrences(of: "€", with: "")
        let currentURL = scratch.appendingPathComponent("T.java")
        stubs.append(contentsOf: JavaSourceStubBuilder.build(source: source, url: currentURL).classes)
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        let provider = JavaGoToDefinitionProvider(
            index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true))
        )
        let marker = try XCTUnwrap(marked.range(of: "€"))
        let utf16 = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
        let position = JavaNavigationText.position(utf16Offset: utf16, in: source)
        let document = Document(
            url: currentURL, displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
        return await provider.provide(context: NavigationContext(
            document: document, cursor: Cursor(position: position), selection: document.selection, kind: kind
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
