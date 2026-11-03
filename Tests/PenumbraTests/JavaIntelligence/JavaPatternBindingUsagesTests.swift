import XCTest
@testable import JavaIntelligence

/// Locals bound by patterns: `o instanceof String s`, `Point(int x, int y)`, `case T t ->`. Find
/// Usages, Rename and highlighting share `JavaSemanticWalker`'s scopes, and it used to bind only the
/// `case` form, so the others produced no declaration and no usages at all.
final class JavaPatternBindingUsagesTests: XCTestCase {
    /// `€` marks the declaration's first character; the name is `length` characters long.
    private func usages(_ marked: String, nameLength: Int = 1) -> [String] {
        let marker = marked.range(of: "€")!
        let source = marked.replacingOccurrences(of: "€", with: "")
        let offset = source.utf8.distance(from: source.utf8.startIndex, to: marker.lowerBound.samePosition(in: source.utf8)!)
        let tree = JavaSyntaxParser().parse(source)!
        let found = JavaLocalUsages.usages(
            ofDeclaration: offset..<(offset + nameLength), file: URL(fileURLWithPath: "/A.java"), source: source, tree: tree
        )
        return found.map { usage in
            let text = String(decoding: Array(source.utf8)[usage.byteRange], as: UTF8.self)
            return "\(text):\(usage.kind)"
        }
    }

    func testInstanceofBinding() {
        XCTAssertEqual(
            usages("class A { void m(Object o) { if (o instanceof String €s) { s.length(); } } }"),
            ["s:declaration", "s:read"]
        )
    }

    /// Flow scoping: the binding outlives the `if` whose condition introduced it.
    func testNegatedInstanceofBindingIsVisibleAfterTheIf() {
        XCTAssertEqual(
            usages("class A { void m(Object o) { if (!(o instanceof String €s)) return; s.length(); } }"),
            ["s:declaration", "s:read"]
        )
    }

    func testBindingUsedInTheRightOperandOfAnd() {
        XCTAssertEqual(
            usages("class A { boolean m(Object o) { return o instanceof String €s && s.isEmpty(); } }"),
            ["s:declaration", "s:read"]
        )
    }

    func testRecordPatternComponents() {
        let source = "class A { record Point(int x, int y) {} int m(Object o) { if (o instanceof Point(int €x, int y)) { return x + y; } return 0; } }"
        XCTAssertEqual(usages(source), ["x:declaration", "x:read"])
    }

    func testNestedRecordPatternComponent() {
        let source = "class A { record Box(String v) {} record Pair(Box a, Box b) {} void m(Object o) { if (o instanceof Pair(Box(String €v), Box b)) { v.length(); } } }"
        XCTAssertEqual(usages(source), ["v:declaration", "v:read"])
    }

    func testSwitchPatternBindingsStillWork() {
        XCTAssertEqual(
            usages("class A { int m(Object o) { return switch (o) { case String €s -> s.length(); default -> 0; }; } }"),
            ["s:declaration", "s:read"]
        )
        XCTAssertEqual(
            usages("class A { int m(Object o) { return switch (o) { case Integer €i when i > 3 -> i; default -> 0; }; } }"),
            ["i:declaration", "i:read", "i:read"]
        )
    }

    /// Two bindings of one name in one block are two variables: each has its own usages.
    func testSequentialBindingsOfTheSameNameStaySeparate() {
        let first = "class A { void m(Object o, Object p) { if (o instanceof String €x) { x.length(); } if (p instanceof Integer x) { x.intValue(); } } }"
        let second = "class A { void m(Object o, Object p) { if (o instanceof String x) { x.length(); } if (p instanceof Integer €x) { x.intValue(); } } }"
        XCTAssertEqual(usages(first), ["x:declaration", "x:read"])
        XCTAssertEqual(usages(second), ["x:declaration", "x:read"])
    }

    func testBindingDoesNotCaptureAFieldOfTheSameNameElsewhere() {
        let source = "class A { int s; int f() { return s; } void m(Object o) { if (o instanceof String €s) { s.length(); } } }"
        XCTAssertEqual(usages(source), ["s:declaration", "s:read"])
    }

    func testInstanceofBindingIsHighlightedAsALocal() async {
        let source = "class A { void m(Object o) { if (o instanceof String s && s.isEmpty()) { s.length(); } } }"
        let tokens = await JavaSemanticTokenProvider(index: nil).tokens(for: source) ?? []
        let ns = source as NSString
        let kinds = tokens.filter { ns.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) == "s" }.map(\.kind)
        XCTAssertEqual(kinds.count, 3)
        XCTAssertTrue(kinds.allSatisfy { $0 == .localVariable }, "\(kinds)")
    }
}
