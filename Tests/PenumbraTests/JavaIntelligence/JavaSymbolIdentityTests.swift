import XCTest
@testable import JavaIntelligence

final class JavaSymbolIdentityTests: XCTestCase {
    func testTypeReferenceResolvesToQualifiedName() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Foo.java", "package p; public class Foo {}")
        try fixture.add("Use.java", "package p; class Use { €Foo foo; }")
        let id = try await fixture.symbolID()
        XCTAssertEqual(id, .type(qualifiedName: "p.Foo"))
    }

    func testDeclarationNameResolvesToItself() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Foo.java", "package p; public class €Foo {}")
        let id = try await fixture.symbolID()
        XCTAssertEqual(id, .type(qualifiedName: "p.Foo"))
    }

    func testNestedTypeUsesDottedName() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Outer.java", "package p; public class Outer { public static class Inner {} }")
        try fixture.add("Use.java", "package p; class Use { Outer.€Inner x; }")
        let id = try await fixture.symbolID()
        XCTAssertEqual(id, .type(qualifiedName: "p.Outer.Inner"))
    }

    func testMethodDeclarationCarriesDeclaredParameterKeys() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A { void €run(int n, Foo f) {} void run(boolean b) {} } class Foo {}")
        let id = try await fixture.symbolID()
        XCTAssertEqual(id, .method(declaringClass: "A", name: "run", parameterKeys: ["int", "Foo"]))
    }

    func testOverloadDeclarationsWithTheSameArityAreTold() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A { void run(Foo f) {} void €run(Bar b) {} } class Foo {} class Bar {}")
        let id = try await fixture.symbolID()
        XCTAssertEqual(id, .method(declaringClass: "A", name: "run", parameterKeys: ["Bar"]))
    }

    func testCallPicksTheOverloadByArgumentType() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", """
        class A {
            void run(Foo f) {}
            void run(Bar b) {}
            void go() { Bar bar = new Bar(); €run(bar); }
        }
        class Foo {}
        class Bar {}
        """)
        let id = try await fixture.symbolID()
        XCTAssertEqual(id, .method(declaringClass: "A", name: "run", parameterKeys: ["Bar"]))
    }

    func testInheritedMethodIsIdentifiedByItsDeclaringClass() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Base.java", "class Base { void hello() {} }")
        try fixture.add("Sub.java", "class Sub extends Base {}")
        try fixture.add("Use.java", "class Use { void go(Sub s) { s.€hello(); } }")
        let id = try await fixture.symbolID()
        XCTAssertEqual(id, .method(declaringClass: "Base", name: "hello", parameterKeys: []))
    }

    func testGenericMethodKeepsDeclaredKeysNotSubstitutedOnes() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Box.java", "class Box<T> { void put(Other o) {} void put(T value) {} } class Other {}")
        try fixture.add("Use.java", "class Use { void go(Box<Item> b, Item i) { b.€put(i); } } class Item {}")
        let id = try await fixture.symbolID()
        XCTAssertEqual(id, .method(declaringClass: "Box", name: "put", parameterKeys: ["T"]))
    }

    func testConstructorCall() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Foo.java", "class Foo { Foo(int n) {} Foo(String s) {} }")
        try fixture.add("Use.java", "class Use { Object o = new €Foo(1); }")
        let id = try await fixture.symbolID()
        XCTAssertEqual(id, .constructor(declaringClass: "Foo", parameterKeys: ["int"]))
    }

    func testFieldThroughReceiverAndDeclaration() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Foo.java", "class Foo { int count; }")
        try fixture.add("Use.java", "class Use { int go(Foo f) { return f.€count; } }")
        let id = try await fixture.symbolID()
        XCTAssertEqual(id, .field(declaringClass: "Foo", name: "count"))

        let declaration = try JavaReferenceFixture()
        try declaration.add("Foo.java", "class Foo { int €count; }")
        let declared = try await declaration.symbolID()
        XCTAssertEqual(declared, .field(declaringClass: "Foo", name: "count"))
    }

    func testEnumConstantAndRecordComponent() async throws {
        let enumFixture = try JavaReferenceFixture()
        try enumFixture.add("Color.java", "enum Color { RED, GREEN }")
        try enumFixture.add("Use.java", "class Use { Color c = Color.€RED; }")
        let constant = try await enumFixture.symbolID()
        XCTAssertEqual(constant, .field(declaringClass: "Color", name: "RED"))

        let recordFixture = try JavaReferenceFixture()
        try recordFixture.add("P.java", "record P(int €x, int y) {}")
        let component = try await recordFixture.symbolID()
        XCTAssertEqual(component, .field(declaringClass: "P", name: "x"))
    }

    func testLocalAndParameterAreKeyedByDeclarationRange() async throws {
        let fixture = try JavaReferenceFixture()
        let source = "class A { void go(int limit) { int total = 0; total += €limit; } }"
        try fixture.add("A.java", source)
        let id = try await fixture.symbolID()
        let declaration = try XCTUnwrap(source.range(of: "limit"))
        let start = source.utf8.distance(from: source.startIndex, to: declaration.lowerBound)
        XCTAssertEqual(id, .local(file: fixture.url("A.java"), declarationRange: start..<(start + 5)))
    }

    func testLocalDeclarationUnderCaret() async throws {
        let fixture = try JavaReferenceFixture()
        let source = "class A { void go() { int €total = 0; } }"
        try fixture.add("A.java", source)
        let id = try await fixture.symbolID()
        guard case .local(_, let range)? = id else { return XCTFail("expected a local, got \(String(describing: id))") }
        XCTAssertEqual(String(decoding: Array(fixture.sources["A.java"]!.utf8)[range], as: UTF8.self), "total")
    }

    func testNothingUnderTheCaretGivesNil() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A { int x = €1; }")
        let id = try await fixture.symbolID()
        XCTAssertNil(id)
    }

    func testStaticImportedMethod() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Util.java", "package p; public class Util { public static void helper() {} }")
        try fixture.add("Use.java", "package q; import static p.Util.helper; class Use { void go() { €helper(); } }")
        let id = try await fixture.symbolID()
        XCTAssertEqual(id, .method(declaringClass: "p.Util", name: "helper", parameterKeys: []))
    }
}
