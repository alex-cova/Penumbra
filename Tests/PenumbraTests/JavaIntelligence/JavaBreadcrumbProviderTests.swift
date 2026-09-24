import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaBreadcrumbProviderTests: XCTestCase {
    private let source = """
    package demo;

    import java.util.List;

    public class Outer<T> {
        int field = compute();

        static class Inner<K, V extends Comparable<V>> {
            void put(String key, int count) {
                int local = 1;
            }

            void put(java.util.List<java.lang.String> keys, int... counts) {}

            Inner(K first) {}
        }

        void top() {}
    }

    interface Shape { double area(); }
    """

    private func titles(at marker: String, in source: String? = nil, language: String = "java") async -> [String]? {
        let text = source ?? self.source
        let offset = (text as NSString).range(of: marker).location
        let position = JavaNavigationText.position(utf16Offset: offset, in: text)
        let document = Document(
            displayName: "Outer.java", contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 10, height: 10),
            languageIdentifier: language
        )
        return await JavaBreadcrumbProvider().breadcrumbs(for: document)?.map(\.title)
    }

    func testCaretInAMethodBodyListsTypesThenMethodWithParameterTypes() async {
        let result = await titles(at: "int local")
        XCTAssertEqual(result, ["Outer<T>", "Inner<K, V>", "put(String, int)"])
    }

    func testOverloadsAreDistinguishedAndQualifiersAndVarargsAreSimplified() async {
        let result = await titles(at: "void put(java.util")
        XCTAssertEqual(result, ["Outer<T>", "Inner<K, V>", "put(List<String>, int...)"])
    }

    func testConstructorIsLabeledByItsClassName() async {
        let result = await titles(at: "Inner(K first)")
        XCTAssertEqual(result, ["Outer<T>", "Inner<K, V>", "Inner(K)"])
    }

    func testCaretInAFieldInitializerShowsOnlyTheType() async {
        let result = await titles(at: "compute()")
        XCTAssertEqual(result, ["Outer<T>"])
    }

    func testCaretBetweenMembersShowsTheEnclosingType() async {
        let result = await titles(at: "void top")
        XCTAssertEqual(result, ["Outer<T>", "top()"])
    }

    func testTopLevelInterfaceMethod() async {
        let result = await titles(at: "double area")
        XCTAssertEqual(result, ["Shape", "area()"])
    }

    func testCaretOutsideEveryDeclarationIsEmptyButHandled() async {
        let result = await titles(at: "import java")
        XCTAssertEqual(result, [])
    }

    func testSegmentRangeSelectsTheDeclarationName() async throws {
        let text = source
        let offset = (text as NSString).range(of: "int local").location
        let position = JavaNavigationText.position(utf16Offset: offset, in: text)
        let document = Document(
            displayName: "Outer.java", contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 10, height: 10),
            languageIdentifier: "java"
        )
        let found = await JavaBreadcrumbProvider().breadcrumbs(for: document)
        let segments = try XCTUnwrap(found)
        let ns = text as NSString
        let names = segments.map { segment in
            ns.substring(with: NSRange(location: segment.range.start.utf16Offset, length: segment.range.end.utf16Offset - segment.range.start.utf16Offset))
        }
        XCTAssertEqual(names, ["Outer", "Inner", "put"])
    }

    func testOtherLanguagesFallBackToTheGenericBreadcrumbs() async {
        let result = await titles(at: "int local", language: "swift")
        XCTAssertNil(result)
    }

    func testEditingTheTextRefreshesTheCachedOutline() async {
        let provider = JavaBreadcrumbProvider()
        func names(_ text: String) async -> [String]? {
            let offset = (text as NSString).range(of: "x;").location
            let position = JavaNavigationText.position(utf16Offset: offset, in: text)
            let document = Document(
                displayName: "A.java", contentSnapshot: TextSnapshot(version: 0, text: text),
                selection: Selection(range: TextRange(start: position, end: position)),
                cursor: Cursor(position: position),
                viewport: Viewport(x: 0, y: 0, width: 10, height: 10),
                languageIdentifier: "java"
            )
            return await provider.breadcrumbs(for: document)?.map(\.title)
        }
        let before = await names("class A { void m() { int x; } }")
        let after = await names("class B { void run(int n) { int x; } }")
        XCTAssertEqual(before, ["A", "m()"])
        XCTAssertEqual(after, ["B", "run(int)"])
    }
}
