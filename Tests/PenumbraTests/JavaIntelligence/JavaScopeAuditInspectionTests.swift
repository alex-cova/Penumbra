import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// Regressions from auditing the inspections for scoping mistakes: a name resolved to the wrong
/// declaration, a nested or anonymous class counted against its enclosing one, and a JDK type
/// name matched against a project class of the same name.
final class JavaScopeAuditInspectionTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/proj/T.java")

    private func findings(_ rule: JavaInspectionRule, _ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> [JavaInspection] {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source), file: file, line: line)
        let context = try XCTUnwrap(
            JavaInspectionContext(source: source, tree: tree, url: url, index: JavaIndex(), languageLevel: 21),
            "source must parse", file: file, line: line
        )
        return JavaInspectionRunner.run(context: context, enabled: [rule])
    }

    private func count(_ rule: JavaInspectionRule, _ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        try findings(rule, source, file: file, line: line).count
    }

    // MARK: Declared types

    /// The declared type of `v` at the receiver of the first `v.probe()` call.
    private func typeOfV(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> JavaDeclaredType? {
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source), file: file, line: line)
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            if node.type == "method_invocation", node.child(byFieldName: "name")?.text == "probe",
               let object = node.child(byFieldName: "object") {
                return JavaDeclaredTypes.variableType(named: "v", at: object)
            }
            stack.append(contentsOf: node.namedChildren)
        }
        XCTFail("no v.probe() call", file: file, line: line)
        return nil
    }

    private func member(_ body: String) -> String {
        "class C {\n    String v;\n    void m(Object o, java.util.List<String> list) {\n\(body)\n    }\n}\n"
    }

    func testFieldIsFoundWhenNothingShadowsIt() throws {
        XCTAssertEqual(try typeOfV(member("        v.probe();"))?.name, "String")
    }

    func testLambdaParameterShadowsAField() throws {
        XCTAssertNil(try typeOfV(member("        list.forEach(v -> v.probe());")))
        XCTAssertNil(try typeOfV(member("        list.forEach((v, w) -> v.probe());")))
        XCTAssertEqual(try typeOfV(member("        list.forEach((Integer v) -> v.probe());"))?.name, "Integer")
    }

    func testCatchParameterShadowsAField() throws {
        XCTAssertEqual(try typeOfV(member("        try { } catch (java.io.IOException v) { v.probe(); }"))?.name, "IOException")
        XCTAssertNil(try typeOfV(member("        try { } catch (IOException | RuntimeException v) { v.probe(); }")))
    }

    func testTryResourceShadowsAFieldOnlyInTheBody() throws {
        XCTAssertEqual(try typeOfV(member("        try (Reader v = open()) { v.probe(); }"))?.name, "Reader")
        XCTAssertEqual(try typeOfV(member("        try (Reader v = open()) { } catch (Exception e) { v.probe(); }"))?.name, "String")
    }

    func testPatternVariableShadowsAField() throws {
        XCTAssertNil(try typeOfV(member("        if (o instanceof Foo v) { v.probe(); }")))
        XCTAssertNil(try typeOfV(member("        switch (o) { case Foo v -> v.probe(); default -> { } }")))
    }

    func testVarargsParameterIsAnArray() throws {
        let source = "class C {\n    String v;\n    void m(Integer... v) {\n        v.probe();\n    }\n}\n"
        let type = try XCTUnwrap(try typeOfV(source))
        XCTAssertEqual(type.name, "Integer")
        XCTAssertTrue(type.isArray)
    }

    func testRecordComponentShadowsAnOuterField() throws {
        let source = "class C {\n    String v;\n    record R(int v) {\n        void f() { v.probe(); }\n    }\n}\n"
        XCTAssertEqual(try typeOfV(source)?.name, "int")
    }

    func testShadowedFieldDoesNotTriggerTypedRules() throws {
        let source = member("        list.forEach(v -> v.length());\n        boolean b = v.length() == 0;")
        // Only the real String field use is reported, not the lambda parameter of unknown type.
        XCTAssertEqual(try count(.stringLengthZeroCheck, member("        list.forEach(v -> { boolean b = v.length() == 0; });")), 0)
        XCTAssertEqual(try count(.stringLengthZeroCheck, source), 1)
    }

    // MARK: Class structure

    func testInnerClassExtendingAnotherInnerClassMustStayInner() throws {
        let source = "class T {\n    class A { }\n    class B extends A { }\n}\n"
        let reported = try findings(.innerClassMayBeStatic, source)
        XCTAssertEqual(reported.count, 1)
        XCTAssertTrue(reported.first?.message.contains("'A'") == true)
    }

    func testInnerClassWithABoundOnAnOuterTypeParameterMustStayInner() throws {
        XCTAssertEqual(try count(.innerClassMayBeStatic, "class T<E> {\n    class Inner<U extends E> { }\n}\n"), 0)
        XCTAssertEqual(try count(.innerClassMayBeStatic, "class T<E> {\n    class Inner implements java.util.function.Supplier<E> {\n        public E get() { return null; }\n    }\n}\n"), 0)
    }

    func testMethodOfAClassInsideAnEnumMayUseTheEnumsFields() throws {
        let source = "enum E {\n    A;\n    int x;\n    class In {\n        private int f() { return x; }\n    }\n}\n"
        XCTAssertEqual(try count(.methodMayBeStatic, source), 0)
    }

    func testNonSerializableFieldIgnoresSameNamedProjectTypes() throws {
        let shape = "class T implements java.io.Serializable {\n    private Logger log;\n}\n"
        XCTAssertEqual(try count(.nonSerializableField, "import org.slf4j.Logger;\n" + shape), 1)
        XCTAssertEqual(try count(.nonSerializableField, "import com.acme.Logger;\n" + shape), 0)
        XCTAssertEqual(try count(.nonSerializableField, shape + "class Logger implements java.io.Serializable { }\n"), 0)
    }

    func testSerializableOnlyAsATypeArgumentDoesNotCount() throws {
        XCTAssertEqual(try count(.nonSerializableField, "class T implements Comparable<java.io.Serializable> {\n    private Thread t;\n}\n"), 0)
    }

    func testRawTypeIgnoresSameNamedProjectTypes() throws {
        XCTAssertEqual(try count(.rawTypeUsage, "class Queue { }\nclass T {\n    Queue q;\n}\n"), 0)
        XCTAssertEqual(try count(.rawTypeUsage, "import com.acme.Callable;\nclass T {\n    Callable c;\n}\n"), 0)
        XCTAssertEqual(try count(.rawTypeUsage, "import java.util.Queue;\nclass T {\n    Queue q;\n}\n"), 1)
    }

    // MARK: Metrics and throwables

    func testComplexityIgnoresTheMethodsOfAnAnonymousClass() throws {
        let branches = (0..<12).map { "if (a == \($0)) { }" }.joined(separator: " ")
        let source = "class T {\n    void f(int a) {\n        Runnable r = new Runnable() { public void run() { \(branches) } };\n    }\n}\n"
        let reported = try findings(.cyclomaticComplexity, source)
        XCTAssertEqual(reported.count, 1)
        XCTAssertTrue(reported.first?.message.contains("'run'") == true)
    }

    func testNestingIgnoresTheMethodsOfALocalClass() throws {
        let deep = "if (a) { if (a) { if (a) { if (a) { if (a) { if (a) { } } } } } }"
        let source = "class T {\n    void f(boolean a) {\n        if (a) {\n            class Local { void g(boolean a) { \(deep) } }\n        }\n    }\n}\n"
        let reported = try findings(.nestingDepth, source)
        XCTAssertEqual(reported.count, 1)
        XCTAssertTrue(reported.first?.message.contains("'g'") == true)
    }

    func testClassNamedLikeAnErrorThatIsNotThrowableIsNotFlagged() throws {
        let plain = "class ParseError { }\nclass T {\n    void f() { new ParseError(); }\n}\n"
        XCTAssertEqual(try count(.throwableNotThrown, plain), 0)
        let throwable = "class ParseError extends RuntimeException { }\nclass T {\n    void f() { new ParseError(); }\n}\n"
        XCTAssertEqual(try count(.throwableNotThrown, throwable), 1)
        XCTAssertEqual(try count(.throwableNotThrown, "class T {\n    void f() { new IllegalStateException(); }\n}\n"), 1)
    }

    // MARK: Inherited fields and repeated type names

    func testInheritedFieldHidesAnOuterField() throws {
        let inner = "class Base { Integer v; }\nclass C {\n    String v;\n    class In extends Base {\n        void m() { v.probe(); }\n    }\n}\n"
        XCTAssertEqual(try typeOfV(inner)?.name, "Integer")
        let grandparent = "class Root { Long v; }\nclass Base extends Root { }\nclass C {\n    String v;\n    class In extends Base {\n        void m() { v.probe(); }\n    }\n}\n"
        XCTAssertEqual(try typeOfV(grandparent)?.name, "Long")
        let anonymous = "class Base { Integer v; }\nclass C {\n    String v;\n    void m() { new Base() { void n() { v.probe(); } }; }\n}\n"
        XCTAssertEqual(try typeOfV(anonymous)?.name, "Integer")
        let direct = "class Base { Integer v; }\nclass C extends Base {\n    void m() { v.probe(); }\n}\n"
        XCTAssertEqual(try typeOfV(direct)?.name, "Integer")
    }

    func testFieldOfAnUnseenExternalHierarchyIsUnknown() throws {
        // Nothing says what `External` brings, so the lookup ends unknown instead of
        // guessing the outer field, which an inherited member would shadow.
        let source = "class C {\n    String v;\n    class In extends External {\n        void m() { v.probe(); }\n    }\n}\n"
        XCTAssertNil(try typeOfV(source))
    }

    func testFieldAccessUsesTheNearestOfTwoSameNamedNestedTypes() throws {
        let source = """
        class A { static class Entry { String f; } void m(Entry e) { Object x = e.f; } }
        class B { static class Entry { Integer f; } void m(Entry e) { Object x = e.f; } }
        """
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        var accesses: [SyntaxNode] = []
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            if node.type == "field_access", node.child(byFieldName: "field")?.text == "f" { accesses.append(node) }
            stack.append(contentsOf: node.namedChildren)
        }
        let types = accesses.sorted { $0.startByte < $1.startByte }.map { JavaDeclaredTypes.type(of: $0)?.name }
        XCTAssertEqual(types, ["String", "Integer"])
    }

    func testSwitchOverASameNamedEnumUsesItsOwnConstants() throws {
        let source = """
        class A { enum Mode { X, Y } void f(Mode m) { switch (m) { case X: break; } } }
        class B { enum Mode { X } void f(Mode m) { switch (m) { case X: break; } } }
        """
        XCTAssertEqual(try count(.switchEnumMissingCases, source), 1)
    }

    func testThrowableNamesUseTheNearestOfTwoSameNamedClasses() throws {
        let source = """
        class A { static class FooError extends RuntimeException { } void f() { new FooError(); } }
        class B { static class FooError { } void g() { new FooError(); } }
        """
        XCTAssertEqual(try count(.throwableNotThrown, source), 1)
    }
}
