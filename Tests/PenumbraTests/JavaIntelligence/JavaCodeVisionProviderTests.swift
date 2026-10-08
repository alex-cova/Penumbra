import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaCodeVisionProviderTests: XCTestCase {
    private func makeProvider(_ fixture: JavaReferenceFixture, options: JavaCodeVisionOptions = JavaCodeVisionOptions()) async throws -> JavaCodeVisionProvider {
        let environment = try await fixture.build()
        let paths = JavaIndexPaths(root: fixture.root.appendingPathComponent("cache"))
        let usages = JavaFindUsagesProvider(index: environment.index, indexPaths: paths)
        await usages.setProjectRoots([fixture.root])
        let provider = JavaCodeVisionProvider(index: environment.index, indexPaths: paths, findUsages: usages)
        await provider.setOptions(options)
        return provider
    }

    private func document(_ fixture: JavaReferenceFixture, _ name: String) throws -> Document {
        let source = try XCTUnwrap(fixture.sources[name])
        let start = JavaNavigationText.position(utf16Offset: 0, in: source)
        return Document(
            url: fixture.url(name), displayName: name,
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: EditorIntelligence.TextRange(start: start, end: start)),
            cursor: Cursor(position: start),
            viewport: Viewport(x: 0, y: 0, width: 10, height: 10),
            languageIdentifier: "java"
        )
    }

    /// Labels by the text that follows each anchor, e.g. `["Foo": ["2 usages"]]`.
    private func labels(_ lenses: [CodeVisionLens], in source: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        let ns = source as NSString
        for lens in lenses {
            let rest = ns.substring(from: lens.utf16Offset)
            let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            result[name] = lens.entries.map(\.text)
        }
        return result
    }

    func testAnchorsAreTheNamesOfTypesMethodsAndConstructors() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A { int field; A() {} void run() {} class Inner { void deep() {} } }")
        let provider = try await makeProvider(fixture)
        let document = try document(fixture, "A.java")
        let anchors = await provider.codeVisionAnchors(for: document)
        let source = try XCTUnwrap(fixture.sources["A.java"]) as NSString
        let names = anchors.map { offset -> String in
            let rest = source.substring(from: offset)
            return String(rest.prefix { $0.isLetter })
        }
        XCTAssertEqual(names, ["A", "A", "run", "Inner", "deep"], "no lens above a field")
    }

    func testUsageCountsAndNoUsages() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Foo.java", "public class Foo { void used() {} void unused() {} }")
        try fixture.add("A.java", "class A { Foo f; void go(Foo g) { g.used(); } }")
        let provider = try await makeProvider(fixture)
        let document = try document(fixture, "Foo.java")
        let anchors = await provider.codeVisionAnchors(for: document)
        let lenses = await provider.codeVision(for: document, anchors: anchors)
        let result = labels(lenses, in: try XCTUnwrap(fixture.sources["Foo.java"]))

        XCTAssertEqual(result["Foo"], ["2 usages"])
        XCTAssertEqual(result["used"], ["1 usage"])
        XCTAssertEqual(result["unused"], ["no usages"])
    }

    func testAbstractDeclarationsAlsoCountTheirImplementations() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Shape.java", "public interface Shape { double area(); }")
        try fixture.add("Circle.java", "public class Circle implements Shape { public double area() { return 1; } }")
        try fixture.add("Square.java", "public class Square implements Shape { public double area() { return 2; } }")
        let provider = try await makeProvider(fixture)
        let document = try document(fixture, "Shape.java")
        let anchors = await provider.codeVisionAnchors(for: document)
        let lenses = await provider.codeVision(for: document, anchors: anchors)
        let result = labels(lenses, in: try XCTUnwrap(fixture.sources["Shape.java"]))

        XCTAssertEqual(result["Shape"]?.last, "2 implementations")
        XCTAssertEqual(result["area"]?.last, "2 implementations")
        XCTAssertEqual(result["area"]?.count, 2, "usages first, then implementations")
    }

    func testOptionsSelectTheLabels() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Shape.java", "public interface Shape { double area(); }")
        try fixture.add("Circle.java", "public class Circle implements Shape { public double area() { return 1; } }")
        let document = try document(fixture, "Shape.java")

        let onlyUsages = try await makeProvider(fixture, options: JavaCodeVisionOptions(usages: true, implementations: false))
        var anchors = await onlyUsages.codeVisionAnchors(for: document)
        var lenses = await onlyUsages.codeVision(for: document, anchors: anchors)
        XCTAssertTrue(lenses.allSatisfy { $0.entries.map(\.id) == ["usages"] })

        let onlyImplementations = try await makeProvider(fixture, options: JavaCodeVisionOptions(usages: false, implementations: true))
        anchors = await onlyImplementations.codeVisionAnchors(for: document)
        lenses = await onlyImplementations.codeVision(for: document, anchors: anchors)
        XCTAssertTrue(lenses.allSatisfy { $0.entries.map(\.id) == ["implementations"] })

        let none = try await makeProvider(fixture, options: JavaCodeVisionOptions(usages: false, implementations: false))
        anchors = await none.codeVisionAnchors(for: document)
        XCTAssertEqual(anchors, [])
    }

    func testOnlyTheRequestedAnchorsAreSearched() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Foo.java", "public class Foo { void a() {} void b() {} }")
        let provider = try await makeProvider(fixture)
        let document = try document(fixture, "Foo.java")
        let anchors = await provider.codeVisionAnchors(for: document)
        let lenses = await provider.codeVision(for: document, anchors: [anchors[1]])
        XCTAssertEqual(lenses.map(\.utf16Offset), [anchors[1]])
    }

    func testNonJavaDocumentsGetNothing() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Foo.java", "public class Foo {}")
        let provider = try await makeProvider(fixture)
        var document = try document(fixture, "Foo.java")
        document = Document(
            url: document.url, displayName: "Foo.txt", contentSnapshot: document.contentSnapshot, selection: document.selection,
            cursor: document.cursor, viewport: document.viewport, languageIdentifier: "plaintext"
        )
        let anchors = await provider.codeVisionAnchors(for: document)
        XCTAssertEqual(anchors, [])
    }
}
