import XCTest
@testable import JavaIntelligence

/// `JavaScopeTree`: JLS 6.3 scopes built once per parse, queried by range.
final class JavaScopeTreeTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/proj/Foo.java")

    /// Parses `source`, finds the byte offset of the `€` cursor marker, and returns the parsed
    /// tree, the scope tree, and the offset.
    private func scopes(_ source: String) -> (JavaSyntaxTree, JavaScopeTree, Int) {
        let markerRange = source.range(of: "€")!
        let offset = source.utf8.distance(
            from: source.utf8.startIndex,
            to: markerRange.lowerBound.samePosition(in: source.utf8)!)
        let withoutMarker = source.replacingOccurrences(of: "€", with: "")
        let parsed = JavaSyntaxParser().parse(withoutMarker)!
        return (parsed, JavaScopeTree(tree: parsed, url: file), offset)
    }

    private func names(_ tree: JavaScopeTree, at offset: Int) -> Set<String> {
        Set(tree.locals(atByteOffset: offset).map(\.name))
    }

    // MARK: - parity with JavaLocalScope

    func testLocalsMatchJavaLocalScope() {
        let sources = [
            "class Foo { void m(int a, String b) { int c = a; €x; } }",
            "class Foo { void m() { int outer = 1; if (true) { int inner = 2; €x; } } }",
            "class Foo { void m(java.util.List<String> list) { for (String s : list) { €x; } } }",
            "class Foo { void m() { try (AutoCloseable c = get()) { €x; } } }",
            "class Foo { void m() { int a = 1, b = 2; €x; } }",
        ]
        for source in sources {
            let (parsed, tree, offset) = scopes(source)
            let expected = Set(JavaLocalScope.locals(in: parsed, atByteOffset: offset).map(\.name))
            XCTAssertEqual(names(tree, at: offset), expected, "source: \(source)")
        }
    }

    // MARK: - documented deltas

    func testLocalVisibleInOwnInitializer() {
        // javac reports "might not have been initialized", not "cannot find symbol".
        let (_, tree, offset) = scopes("class Foo { void m() { int x = x€; } }")
        XCTAssertTrue(names(tree, at: offset).contains("x"))
    }

    func testSwitchBlockIsOneScope() {
        let (_, tree, offset) = scopes(
            "class Foo { void m(int n) { switch (n) { case 1: int a = 1; break; case 2: €x; } } }")
        XCTAssertTrue(names(tree, at: offset).contains("a"))
    }

    // MARK: - shadowing

    func testShadowingKeepsInnermostDeclaration() {
        let (_, tree, offset) = scopes(
            #"class Foo { void m() { int a = 1; { String a = "s"; €x; } } }"#)
        let locals = tree.locals(atByteOffset: offset).filter { $0.name == "a" }
        XCTAssertEqual(locals.count, 1)
        XCTAssertEqual(locals.first?.type, .unresolved(simpleName: "String", arguments: []))
    }

    // MARK: - patterns: polarity, operands, flow-out

    func testIfPatternBindingVisibleInThenBranch() {
        let (_, tree, offset) = scopes(
            "class Foo { void m(Object o) { if (o instanceof String s) { €x; } } }")
        XCTAssertTrue(names(tree, at: offset).contains("s"))
    }

    func testIfPatternBindingNotVisibleAfterStatement() {
        let (_, tree, offset) = scopes(
            "class Foo { void m(Object o) { if (o instanceof String s) { } €x; } }")
        XCTAssertFalse(names(tree, at: offset).contains("s"))
    }

    func testAndChainBindingVisibleInRightOperand() {
        let (_, tree, offset) = scopes(
            "class Foo { boolean m(Object o) { return o instanceof String s && s.length()€ > 0; } }")
        XCTAssertTrue(names(tree, at: offset).contains("s"))
    }

    func testOrBindingVisibleInElseBranch() {
        // `else` means the `||` failed, so the negated left failed too, so `s` holds.
        let (_, tree, offset) = scopes(
            "class Foo { void m(Object o, int n) { if (!(o instanceof String s) || n == 0) { } else { €x; } } }")
        XCTAssertTrue(names(tree, at: offset).contains("s"))
    }

    func testOrRightPatternBindsNothingOutside() {
        // The `||` failed in `else`, so the right side failed: `s` is unbound (javac agrees).
        let (_, tree, offset) = scopes(
            "class Foo { void m(Object o, int n) { if (n > 0 || o instanceof String s) { } else { €x; } } }")
        XCTAssertFalse(names(tree, at: offset).contains("s"))
    }

    func testGuardReturnFlowsBindingOut() {
        let (_, tree, offset) = scopes(
            "class Foo { void m(Object o) { if (!(o instanceof String s)) return; s€; } }")
        XCTAssertTrue(names(tree, at: offset).contains("s"))
    }

    func testRecordPatternBindsComponents() {
        let (_, tree, offset) = scopes(
            "class Foo { void m(Object o) { if (o instanceof Point(int x, int y)) { €x; } } }")
        XCTAssertTrue(names(tree, at: offset).isSuperset(of: ["x", "y"]))
    }

    // MARK: - multi-catch, local types, labels

    func testMultiCatchRecordsAlternativeTypes() {
        let (_, tree, offset) = scopes(
            "class Foo { void m() { try { work(); } catch (java.io.IOException | RuntimeException e) { €x; } } }")
        let declarations = tree.scopeChain(atByteOffset: offset)
            .flatMap(\.declarations)
            .filter { $0.symbol.name == "e" }
        XCTAssertEqual(declarations.count, 1)
        XCTAssertEqual(declarations.first?.alternativeTypes.count, 2)
    }

    func testLocalTypeIdentifiedBySite() {
        let (_, tree, offset) = scopes(
            "class Foo { void m() { class Helper { } Helper €h; } }")
        let symbol = tree.symbol(named: "Helper", atByteOffset: offset)
        XCTAssertNotNil(symbol)
        if case .localType(let name, _, _) = symbol {
            XCTAssertEqual(name, "Helper")
        } else {
            XCTFail("expected a local type, got \(String(describing: symbol))")
        }
    }

    func testLabelResolves() {
        let (_, tree, offset) = scopes(
            "class Foo { void m() { outer: for (;;) { break outer; €x; } } }")
        XCTAssertNotNil(tree.symbol(named: "outer", atByteOffset: offset))
    }

    // MARK: - error recovery

    func testCorruptBodyKeepsParameters() {
        let (_, tree, offset) = scopes("class A { void m(int a { €x; } }")
        XCTAssertTrue(names(tree, at: offset).contains("a"))
    }

    func testCorruptMemberKeepsSiblingScopes() {
        let (_, tree, offset) = scopes("class A { this is not java; void n() { €x; } }")
        XCTAssertNotNil(tree.innermostScope(atByteOffset: offset))
    }

    // MARK: - performance

    func testLargeFileBuildsQuickly() {
        var source = "class Big {\n"
        for index in 0..<2000 {
            source += "    int field\(index) = \(index);\n"
            source += "    void method\(index)(int p\(index)) { int local\(index) = p\(index); }\n"
        }
        source += "}\n"
        let parsed = JavaSyntaxParser().parse(source)!
        let start = Date()
        _ = JavaScopeTree(tree: parsed, url: file)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "scope tree build took \(elapsed)s on a 2k-member file")
    }
}
