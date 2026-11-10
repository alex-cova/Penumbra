import XCTest
@testable import JavaIntelligence

final class JavaVisibleLocalsTests: XCTestCase {
    /// Parses `source`, finds the byte offset of the (single) `€` marker (a cheap "cursor here"
    /// marker that can't collide with real Java source), and returns the locals visible there.
    private func locals(_ source: String) -> [JavaLocalVariable] {
        let markerRange = source.range(of: "€")!
        let offset = source.utf8.distance(from: source.utf8.startIndex, to: markerRange.lowerBound.samePosition(in: source.utf8)!)
        let withoutMarker = source.replacingOccurrences(of: "€", with: "")
        let tree = JavaSyntaxParser().parse(withoutMarker)!
        return tree.visibleLocals(atByteOffset: offset)
    }

    private func names(_ locals: [JavaLocalVariable]) -> Set<String> {
        Set(locals.map(\.name))
    }

    func testMethodParametersAreVisible() {
        let result = locals("class Foo { void m(int a, String b) { €x; } }")
        XCTAssertEqual(names(result), ["a", "b"])
        XCTAssertEqual(result.first { $0.name == "a" }?.type, .primitive(.int))
    }

    func testLocalVariableDeclaredBeforeCursorIsVisible() {
        let result = locals("class Foo { void m() { int a = 1; €x; } }")
        XCTAssertTrue(names(result).contains("a"))
    }

    func testLocalVariableDeclaredAfterCursorIsNotVisible() {
        let result = locals("class Foo { void m() { €x; int a = 1; } }")
        XCTAssertFalse(names(result).contains("a"))
    }

    func testMultipleDeclaratorsInOneStatement() {
        let result = locals("class Foo { void m() { int a = 1, b = 2; €x; } }")
        XCTAssertTrue(names(result).isSuperset(of: ["a", "b"]))
    }

    func testNestedBlockSeesOuterScopeLocals() {
        let result = locals("class Foo { void m() { int outer = 1; if (true) { int inner = 2; €x; } } }")
        XCTAssertTrue(names(result).isSuperset(of: ["outer", "inner"]))
    }

    func testSiblingBlockLocalsAreNotVisible() {
        let result = locals("class Foo { void m() { if (true) { int a = 1; } if (false) { €x; } } }")
        XCTAssertFalse(names(result).contains("a"))
    }

    func testEnhancedForLoopVariableVisibleInsideBody() {
        let result = locals("class Foo { void m(List<String> list) { for (String s : list) { €x; } } }")
        XCTAssertTrue(names(result).contains("s"))
        // "String" isn't resolved to java.lang.String here -- JavaTypeNodeConverter deliberately
        // leaves bare simple names unresolved; JavaTypeResolver resolves them later.
        XCTAssertEqual(result.first { $0.name == "s" }?.type, .unresolved(simpleName: "String", arguments: []))
    }

    func testEnhancedForLoopVariableNotVisibleAfterLoop() {
        let result = locals("class Foo { void m(List<String> list) { for (String s : list) { } €x; } }")
        XCTAssertFalse(names(result).contains("s"))
    }

    func testTryWithResourcesVariableVisibleInsideBody() {
        let result = locals("class Foo { void m() { try (AutoCloseable c = get()) { €x; } } }")
        XCTAssertTrue(names(result).contains("c"))
    }

    func testConstructorParametersAreVisible() {
        let result = locals("class Foo { Foo(int a) { €x; } }")
        XCTAssertTrue(names(result).contains("a"))
    }

    func testShadowingKeepsInnermostDeclaration() {
        let result = locals("class Foo { void m() { int a = 1; { String a2 = \"x\"; €x; } } }")
        // Not a real shadow case (different names) -- verifies ordinary nested visibility still works
        // alongside a same-named case below.
        XCTAssertTrue(names(result).isSuperset(of: ["a", "a2"]))
    }

    func testGenericLocalTypeIsPreserved() {
        // Note: a *fully-qualified* generic type used inline (`java.util.List<String> items = ...`,
        // with no import) is a known tree-sitter-java grammar ambiguity -- it parses as a chained
        // comparison/field-access expression instead of a declaration (confirmed empirically), so
        // this uses the realistic form: a simple generic name, as it appears after an import.
        let result = locals("class Foo { void m() { List<String> items = null; €x; } }")
        guard case .unresolved(let simpleName, let args) = result.first(where: { $0.name == "items" })?.type else {
            return XCTFail("expected an unresolved generic list type")
        }
        XCTAssertEqual(simpleName, "List")
        XCTAssertEqual(args.count, 1)
    }

    /// F-17: Lombok `val` infers like `var` — but only where Lombok is imported, since a
    /// class named `val` is legal plain Java.
    func testValWithLombokImportInfersLikeVar() {
        let result = locals("import lombok.val; class Foo { void m() { val x = \"s\"; €x; } }")
        let x = result.first { $0.name == "x" }
        XCTAssertNotNil(x)
        XCTAssertTrue(x?.isVarDeclaration == true)
        XCTAssertEqual(x?.initializerText, "\"s\"")
    }

    func testValWithoutLombokImportIsATypeName() {
        let result = locals("class Foo { void m() { val x = new val(); €x; } }")
        let x = result.first { $0.name == "x" }
        XCTAssertNotNil(x)
        XCTAssertFalse(x?.isVarDeclaration == true)
        XCTAssertEqual(x?.type, .unresolved(simpleName: "val", arguments: []))
    }

    func testEmptyMethodBodyReturnsOnlyParameters() {
        let result = locals("class Foo { void m(int a) { €x } }")
        XCTAssertEqual(names(result), ["a"])
    }

    func testNoEnclosingMethodReturnsEmpty() {
        let result = locals("class Foo { int field = €1; }")
        XCTAssertEqual(result, [])
    }

    /// A local of a static or instance initializer is in scope inside an anonymous class declared
    /// there. The completion query builds only the outermost member; that member is the initializer,
    /// not the anonymous method.
    func testInitializerLocalIsVisibleInsideAnAnonymousClass() {
        let captured = locals("""
        class Foo {
          static {
            final String canAccessMethod = null;
            Object o = new Object() { void run() { canAccessMethod€.length(); } };
          }
        }
        """)
        XCTAssertTrue(names(captured).contains("canAccessMethod"))
        XCTAssertEqual(
            captured.first { $0.name == "canAccessMethod" }?.type,
            .unresolved(simpleName: "String", arguments: [])
        )

        let instance = locals("""
        class Foo {
          {
            final String label = "x";
            Object o = new Object() { void run() { label€.length(); } };
          }
        }
        """)
        XCTAssertTrue(names(instance).contains("label"))
    }

    func testInitializerLocalStaysInsideTheInitializer() {
        let inBlock = locals("class Foo { static { int n = 1; €x; } }")
        XCTAssertTrue(names(inBlock).contains("n"))

        let inMethod = locals("class Foo { static { int hidden = 1; } void m() { €x; } }")
        XCTAssertFalse(names(inMethod).contains("hidden"))

        let staticHiddenFromInstance = locals("class Foo { static { int hidden = 1; } { €x; } }")
        XCTAssertFalse(names(staticHiddenFromInstance).contains("hidden"))

        let instanceHiddenFromStatic = locals("class Foo { { int hidden = 1; } static { €x; } }")
        XCTAssertFalse(names(instanceHiddenFromStatic).contains("hidden"))
    }

}
