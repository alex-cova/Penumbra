import XCTest
@testable import JavaIntelligence

final class JavaStructureProviderTests: XCTestCase {
    private let source = """
    package demo;

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

    enum Color {
        RED, GREEN;
        void paint() {}
    }

    record Point(int x, int y) {}
    """

    private func root(at marker: String, in text: String? = nil) async -> JavaStructureNode? {
        let text = text ?? self.source
        let offset = (text as NSString).range(of: marker).location
        return await JavaStructureProvider().structure(for: text, atUTF16Offset: offset)
    }

    private func titles(_ node: JavaStructureNode?) -> [String] {
        node?.children.map(\.title) ?? []
    }

    func testCaretInInnerClassShowsInnerMembers() async {
        let root = await root(at: "int local")
        XCTAssertEqual(root?.title, "Inner<K, V>")
        XCTAssertEqual(titles(root), [
            "put(String, int)",
            "put(List<String>, int...)",
            "Inner(K)"
        ])
    }

    func testCaretInOuterFieldInitializerShowsOuterMembers() async {
        let root = await root(at: "compute()")
        XCTAssertEqual(root?.title, "Outer<T>")
        XCTAssertTrue(titles(root).contains("field: int"))
        XCTAssertTrue(titles(root).contains { $0.hasPrefix("Inner<") })
        XCTAssertTrue(titles(root).contains("top()"))
    }

    func testCaretBetweenMembersShowsEnclosingType() async {
        let root = await root(at: "void top")
        XCTAssertEqual(root?.title, "Outer<T>")
        XCTAssertTrue(titles(root).contains("top()"))
    }

    func testEnumConstantsAndMethodsAppear() async {
        let root = await root(at: "void paint")
        XCTAssertEqual(root?.title, "Color")
        XCTAssertTrue(titles(root).contains("RED"))
        XCTAssertTrue(titles(root).contains("GREEN"))
        XCTAssertTrue(titles(root).contains("paint()"))
    }

    func testRecordComponentsAppear() async {
        let root = await root(at: "int y")
        XCTAssertEqual(root?.title, "Point")
        XCTAssertEqual(titles(root), ["x: int", "y: int"])
    }

    func testCaretOutsideTypesFallsBackToFirstTopLevelType() async {
        let root = await root(at: "package demo")
        XCTAssertEqual(root?.title, "Outer<T>")
    }

    func testSelectedNodeFollowsCaretWithinRoot() async throws {
        let provider = JavaStructureProvider()
        let text = source
        let root = await provider.structure(for: text, atUTF16Offset: (text as NSString).range(of: "int local").location)
        let selected = await provider.selectedNode(
            in: try XCTUnwrap(root),
            text: text,
            atUTF16Offset: (text as NSString).range(of: "int local").location
        )
        XCTAssertEqual(selected?.title, "put(String, int)")
    }

    func testEditingTheTextRefreshesTheCachedOutline() async {
        let provider = JavaStructureProvider()
        func title(_ text: String) async -> String? {
            let offset = (text as NSString).range(of: "x;").location
            return await provider.structure(for: text, atUTF16Offset: offset)?.title
        }
        let before = await title("class A { void m() { int x; } }")
        let after = await title("class B { void run(int n) { int x; } }")
        XCTAssertEqual(before, "A")
        XCTAssertEqual(after, "B")
    }
}
