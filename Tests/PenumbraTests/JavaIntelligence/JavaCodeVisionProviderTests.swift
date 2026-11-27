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

    func testClassesWithSubclassesAndMethodsWithOverridesAreCounted() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Base.java", """
        public class Base {
            public void run() {}
            public void leaf() {}
            public final void sealedMethod() {}
            public static void helper() {}
            private void hidden() {}
        }
        """)
        try fixture.add("Left.java", "public class Left extends Base { @Override public void run() {} }")
        try fixture.add("Right.java", "public class Right extends Base { @Override public void run() {} }")
        let provider = try await makeProvider(fixture)
        let document = try document(fixture, "Base.java")
        let anchors = await provider.codeVisionAnchors(for: document)
        let lenses = await provider.codeVision(for: document, anchors: anchors)
        let result = labels(lenses, in: try XCTUnwrap(fixture.sources["Base.java"]))

        XCTAssertEqual(result["Base"]?.last, "2 subclasses")
        XCTAssertEqual(result["run"]?.last, "2 overrides")
        XCTAssertEqual(result["leaf"], ["no usages"], "nothing overrides it, so no label")
        XCTAssertEqual(result["sealedMethod"], ["no usages"], "a final method cannot be overridden")
        XCTAssertEqual(result["helper"], ["no usages"], "a static method is not overridden")
        XCTAssertEqual(result["hidden"], ["no usages"], "a private method is not overridden")

        let leftDocument = try self.document(fixture, "Left.java")
        let leftAnchors = await provider.codeVisionAnchors(for: leftDocument)
        let left = labels(await provider.codeVision(for: leftDocument, anchors: leftAnchors), in: try XCTUnwrap(fixture.sources["Left.java"]))
        XCTAssertEqual(left["Left"], ["no usages"], "a class with no subclasses carries no subclass label")
    }

    func testFinalClassesEnumsRecordsAndTheirMethodsGetNoInheritanceLabels() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Sealed.java", "public final class Sealed { public void run() {} }")
        try fixture.add("Kind.java", "public enum Kind { A; public void run() {} }")
        try fixture.add("Point.java", "public record Point(int x) { public void run() {} }")
        let provider = try await makeProvider(fixture)
        for name in ["Sealed.java", "Kind.java", "Point.java"] {
            let file = try document(fixture, name)
            let anchors = await provider.codeVisionAnchors(for: file)
            let lenses = await provider.codeVision(for: file, anchors: anchors)
            let entries = lenses.flatMap(\.entries).map(\.id)
            XCTAssertEqual(Set(entries), ["usages"], "\(name): \(entries)")
        }
    }

    func testAnOverriddenInterfaceDefaultMethodIsCounted() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Greeter.java", "public interface Greeter { default String hello() { return \"hi\"; } }")
        try fixture.add("Polite.java", "public class Polite implements Greeter { public String hello() { return \"good day\"; } }")
        let provider = try await makeProvider(fixture)
        let document = try document(fixture, "Greeter.java")
        let anchors = await provider.codeVisionAnchors(for: document)
        let lenses = await provider.codeVision(for: document, anchors: anchors)
        let result = labels(lenses, in: try XCTUnwrap(fixture.sources["Greeter.java"]))
        XCTAssertEqual(result["Greeter"]?.last, "1 implementation")
        XCTAssertEqual(result["hello"]?.last, "1 override")
    }

    func testImplementationOptionAlsoControlsSubclassAndOverrideLabels() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Base.java", "public class Base { public void run() {} }")
        try fixture.add("Left.java", "public class Left extends Base { @Override public void run() {} }")
        let provider = try await makeProvider(fixture, options: JavaCodeVisionOptions(usages: true, implementations: false))
        let document = try document(fixture, "Base.java")
        let anchors = await provider.codeVisionAnchors(for: document)
        let result = labels(await provider.codeVision(for: document, anchors: anchors), in: try XCTUnwrap(fixture.sources["Base.java"]))
        XCTAssertEqual(result["Base"]?.count, 1)
        XCTAssertEqual(result["run"]?.count, 1)
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
