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

    // MARK: - what is visible where

    /// The scope model's basic shapes, with the answers the old per-query walk (`JavaLocalScope`,
    /// since removed) gave on the same sources.
    func testBasicVisibility() {
        let cases: [(source: String, expected: Set<String>)] = [
            ("class Foo { void m(int a, String b) { int c = a; €x; } }", ["a", "b", "c"]),
            ("class Foo { void m() { int outer = 1; if (true) { int inner = 2; €x; } } }", ["outer", "inner"]),
            ("class Foo { void m(java.util.List<String> list) { for (String s : list) { €x; } } }", ["list", "s"]),
            ("class Foo { void m() { try (AutoCloseable c = get()) { €x; } } }", ["c"]),
            ("class Foo { void m() { int a = 1, b = 2; €x; } }", ["a", "b"]),
        ]
        for (source, expected) in cases {
            let (_, tree, offset) = scopes(source)
            XCTAssertEqual(names(tree, at: offset), expected, "source: \(source)")
        }
    }

    /// Callers depend on the order: an inner scope's locals first, a scope's locals in source order,
    /// then its parameters in source order (extract method lists captured parameters in declaration
    /// order, and `var` locals are resolved against the ones before them).
    func testOrderIsInnermostScopeFirstThenSourceOrderThenParameters() {
        let (_, tree, offset) = scopes(
            "class Foo { void m(int p, int q) { int a = 1, b = 2; { int c = 3; €x; } } }")
        XCTAssertEqual(tree.locals(atByteOffset: offset).map(\.name), ["c", "a", "b", "p", "q"])
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

    // MARK: - switch used as a value

    /// A `switch` that is an initializer, argument or `return` value builds its rule scopes too.
    func testSwitchExpressionAsInitializerBindsPatterns() {
        let (_, tree, offset) = scopes(
            "class Foo { void m(Object o) { int n = switch (o) { case String s -> s.length€(); default -> 0; }; } }")
        XCTAssertTrue(names(tree, at: offset).contains("s"))
    }

    func testSwitchExpressionAsArgumentAndReturnBindPatterns() {
        for source in [
            "class Foo { void m(Object o) { use(switch (o) { case Integer i -> i€; default -> 0; }); } }",
            "class Foo { int m(Object o) { return switch (o) { case Integer i -> i€; default -> 0; }; } }",
        ] {
            let (_, tree, offset) = scopes(source)
            XCTAssertTrue(names(tree, at: offset).contains("i"), "source: \(source)")
        }
    }

    func testSwitchExpressionBindingDoesNotEscapeItsRule() {
        let (_, tree, offset) = scopes(
            "class Foo { void m(Object o) { int n = switch (o) { case String s -> 1; default -> 0; }; €x; } }")
        XCTAssertFalse(names(tree, at: offset).contains("s"))
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

    func testVarargsParameterIsAnArrayVisibleInTheBody() {
        let (_, tree, offset) = scopes("class Foo { void m(String... values) { values€; } }")
        let values = tree.locals(atByteOffset: offset).first { $0.name == "values" }
        XCTAssertEqual(values?.type, .array(element: .unresolved(simpleName: "String", arguments: [])))
    }

    func testCStyleArrayParameterAndLocalKeepTheirDimensions() {
        let parameter = scopes("class Foo { void m(byte buffer[]) { buffer€; } }")
        let buffer = parameter.1.locals(atByteOffset: parameter.2).first { $0.name == "buffer" }
        XCTAssertEqual(buffer?.type, .array(element: .primitive(.byte)))

        let local = scopes("class Foo { void m() { byte buffer[] = null; buffer€; } }")
        let declared = local.1.locals(atByteOffset: local.2).first { $0.name == "buffer" }
        XCTAssertEqual(declared?.type, .array(element: .primitive(.byte)))
    }

    func testForHeaderVariableScopesConditionAndUpdateButNotTheCodeAfter() {
        let condition = scopes("class Foo { void m() { for (java.util.Iterator<String> it = xs.iterator(); it.hasNext€(); ) { } } }")
        XCTAssertTrue(names(condition.1, at: condition.2).contains("it"))

        let update = scopes("class Foo { void m() { for (int i = 0; i < n; i€++) { } } }")
        XCTAssertTrue(names(update.1, at: update.2).contains("i"))

        let after = scopes("class Foo { void m() { for (int i = 0; i < n; i++) { } €x; } }")
        XCTAssertFalse(names(after.1, at: after.2).contains("i"))
    }

    func testEnhancedForVariableScopesTheBodyOnly() {
        let body = scopes("class Foo { void m(java.util.List<String> list) { for (String s : list) { s€; } } }")
        XCTAssertTrue(names(body.1, at: body.2).contains("s"))

        let iterated = scopes("class Foo { void m(java.util.List<String> list) { for (String s : list€) { } } }")
        XCTAssertFalse(names(iterated.1, at: iterated.2).contains("s"))
        XCTAssertTrue(names(iterated.1, at: iterated.2).contains("list"))

        let after = scopes("class Foo { void m(java.util.List<String> list) { for (String s : list) { } €x; } }")
        XCTAssertFalse(names(after.1, at: after.2).contains("s"))
    }

    func testMultiCatchRecordsAlternativeTypes() {
        let (_, tree, offset) = scopes(
            "class Foo { void m() { try { work(); } catch (java.io.IOException | RuntimeException e) { €x; } } }")
        let declarations = tree.scopeChain(atByteOffset: offset)
            .flatMap(\.declarations)
            .filter { $0.symbol.name == "e" }
        XCTAssertEqual(declarations.count, 1)
        XCTAssertEqual(declarations.first?.alternativeTypes.count, 2)
    }

    func testForVariableShadowsTheParameterInsideTheLoopOnly() {
        let inside = scopes("class Foo { void m(String i) { for (int i = 0; i < 1; i++) { i€; } } }")
        let shadowed = inside.1.locals(atByteOffset: inside.2).filter { $0.name == "i" }
        XCTAssertEqual(shadowed.count, 1)
        XCTAssertEqual(shadowed.first?.type, .primitive(.int))

        let after = scopes("class Foo { void m(String i) { for (int i = 0; i < 1; i++) { } i€; } }")
        let parameter = after.1.locals(atByteOffset: after.2).filter { $0.name == "i" }
        XCTAssertEqual(parameter.count, 1)
        XCTAssertEqual(parameter.first?.type, .unresolved(simpleName: "String", arguments: []))
    }

    func testEnhancedForVariableShadowsOnlyInsideTheBody() {
        let body = scopes("class Foo { void m(String s) { for (int s : xs) { s€; } } }")
        let shadowed = body.1.locals(atByteOffset: body.2).filter { $0.name == "s" }
        XCTAssertEqual(shadowed.count, 1)
        XCTAssertEqual(shadowed.first?.type, .primitive(.int))

        let after = scopes("class Foo { void m(String s) { for (int s : xs) { } s€; } }")
        let parameter = after.1.locals(atByteOffset: after.2).filter { $0.name == "s" }
        XCTAssertEqual(parameter.count, 1)
        XCTAssertEqual(parameter.first?.type, .unresolved(simpleName: "String", arguments: []))
    }

    func testCatchParameterDoesNotEscapeTheCatch() {
        let inside = scopes("class Foo { void m(String e) { try { } catch (Exception e) { e€; } } }")
        let caught = inside.1.locals(atByteOffset: inside.2).filter { $0.name == "e" }
        XCTAssertEqual(caught.count, 1)
        XCTAssertEqual(caught.first?.type, .unresolved(simpleName: "Exception", arguments: []))

        let after = scopes("class Foo { void m(String e) { try { } catch (Exception e) { } e€; } }")
        let parameter = after.1.locals(atByteOffset: after.2).filter { $0.name == "e" }
        XCTAssertEqual(parameter.count, 1)
        XCTAssertEqual(parameter.first?.type, .unresolved(simpleName: "String", arguments: []))
    }

    func testVarargsParameterDoesNotEscapeItsMethod() {
        let body = scopes("class Foo { java.util.List values; void m(String... values) { values€; } }")
        let parameter = body.1.locals(atByteOffset: body.2).first { $0.name == "values" }
        XCTAssertEqual(parameter?.type, .array(element: .unresolved(simpleName: "String", arguments: [])))

        let other = scopes("class Foo { java.util.List values; void m(String... values) { } void n() { values€; } }")
        XCTAssertFalse(names(other.1, at: other.2).contains("values"))
    }

    func testCStyleArrayLocalDoesNotEscapeItsBlock() {
        let inside = scopes("class Foo { void m() { { byte buffer[] = null; buffer€; } } }")
        let buffer = inside.1.locals(atByteOffset: inside.2).first { $0.name == "buffer" }
        XCTAssertEqual(buffer?.type, .array(element: .primitive(.byte)))

        let outside = scopes("class Foo { void m() { { byte buffer[] = null; } buffer€; } }")
        XCTAssertFalse(names(outside.1, at: outside.2).contains("buffer"))

        let otherMethod = scopes("class Foo { void m(byte buffer[]) { } void n() { buffer€; } }")
        XCTAssertFalse(names(otherMethod.1, at: otherMethod.2).contains("buffer"))
    }

    func testLocalClassIsVisibleThroughItsBlockOnly() {
        let inside = scopes("class Foo { void m() { class Acc { } Acc €a; } }")
        XCTAssertNotNil(inside.1.symbol(named: "Acc", atByteOffset: inside.2))

        let sibling = scopes("class Foo { void m() { { class Acc { } } { Acc €a; } } }")
        XCTAssertNil(sibling.1.symbol(named: "Acc", atByteOffset: sibling.2))

        let later = scopes("class Foo { void m() { { class Acc { } } Acc €a; } }")
        XCTAssertNil(later.1.symbol(named: "Acc", atByteOffset: later.2))

        let other = scopes("class Foo { void m() { class Acc { } } void n() { Acc €a; } }")
        XCTAssertNil(other.1.symbol(named: "Acc", atByteOffset: other.2))
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
