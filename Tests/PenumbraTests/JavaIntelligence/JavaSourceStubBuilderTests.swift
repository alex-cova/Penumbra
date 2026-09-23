import XCTest
@testable import JavaIntelligence

final class JavaSourceStubBuilderTests: XCTestCase {
    private func build(_ source: String) -> JavaSourceFileStubs {
        JavaSourceStubBuilder.build(source: source, url: URL(fileURLWithPath: "/tmp/Test.java"))
    }

    // MARK: - Package & imports

    func testInterfaceExtendsListIsRecorded() {
        let stub = build("""
        interface StockSet extends StockOperation, Validable,
                MinMaxSetter { }
        """).classes.first
        XCTAssertEqual(stub?.interfaces, [
            .unresolved(simpleName: "StockOperation", arguments: []),
            .unresolved(simpleName: "Validable", arguments: []),
            .unresolved(simpleName: "MinMaxSetter", arguments: [])
        ])
    }

    func testPackageDeclaration() {
        let result = build("package com.example.app;\nclass Foo {}")
        XCTAssertEqual(result.packageName, "com.example.app")
    }

    func testNoPackageDeclarationIsEmptyString() {
        let result = build("class Foo {}")
        XCTAssertEqual(result.packageName, "")
    }

    func testSingleTypeImport() {
        let result = build("import java.util.List;\nclass Foo {}")
        XCTAssertEqual(result.imports, [JavaImportDeclaration(qualifiedName: "java.util.List", isStatic: false, isOnDemand: false)])
    }

    func testOnDemandImport() {
        let result = build("import java.util.*;\nclass Foo {}")
        XCTAssertEqual(result.imports, [JavaImportDeclaration(qualifiedName: "java.util", isStatic: false, isOnDemand: true)])
    }

    func testStaticImport() {
        let result = build("import static java.lang.Math.max;\nclass Foo {}")
        XCTAssertEqual(result.imports, [JavaImportDeclaration(qualifiedName: "java.lang.Math.max", isStatic: true, isOnDemand: false)])
    }

    func testStaticOnDemandImport() {
        let result = build("import static java.lang.Math.*;\nclass Foo {}")
        let decl = try? XCTUnwrap(result.imports.first)
        XCTAssertEqual(decl?.isStatic, true)
        XCTAssertEqual(decl?.isOnDemand, true)
    }

    // MARK: - Class shape

    func testSimpleClassWithSuperclassAndInterfaces() {
        let result = build("public class Foo extends Bar implements Baz, Qux { }")
        let foo = try! XCTUnwrap(result.classes.first)
        XCTAssertEqual(foo.simpleName, "Foo")
        XCTAssertEqual(foo.qualifiedName, "Foo")
        XCTAssertTrue(foo.modifiers.contains(.publicFlag))
        XCTAssertEqual(foo.superclass, .unresolved(simpleName: "Bar", arguments: []))
        XCTAssertEqual(foo.interfaces, [.unresolved(simpleName: "Baz", arguments: []), .unresolved(simpleName: "Qux", arguments: [])])
    }

    func testGenericClassWithBoundedTypeParameter() {
        let result = build("public class Foo<T extends Comparable<T>> { }")
        let foo = try! XCTUnwrap(result.classes.first)
        XCTAssertEqual(foo.typeParameters.count, 1)
        XCTAssertEqual(foo.typeParameters[0].name, "T")
        guard case .unresolved(let simpleName, let args) = foo.typeParameters[0].bounds.first else {
            return XCTFail("expected unresolved Comparable<T> bound")
        }
        XCTAssertEqual(simpleName, "Comparable")
        XCTAssertEqual(args, [.type(.unresolved(simpleName: "T", arguments: []))])
    }

    func testDottedSuperclassBecomesClassTypeDirectly() {
        let result = build("class Foo extends java.util.AbstractList { }")
        let foo = try! XCTUnwrap(result.classes.first)
        XCTAssertEqual(foo.superclass?.erasedQualifiedName, "java.util.AbstractList")
    }

    // MARK: - Fields

    func testFieldsWithModifiersAndMultipleDeclarators() {
        let result = build("class Foo { private int a, b; public static final String NAME = \"x\"; }")
        let foo = try! XCTUnwrap(result.classes.first)
        let ab = foo.fields.filter { $0.name == "a" || $0.name == "b" }
        XCTAssertEqual(ab.count, 2)
        XCTAssertTrue(ab.allSatisfy { $0.modifiers.contains(.privateFlag) })
        let name = try! XCTUnwrap(foo.fields.first { $0.name == "NAME" })
        XCTAssertTrue(name.modifiers.contains(.staticFlag))
        XCTAssertTrue(name.modifiers.contains(.finalFlag))
        // Source stubs never resolve simple names against imports themselves (that's
        // JavaTypeResolver's job); "String" stays unresolved even though it's unambiguously
        // java.lang.String.
        XCTAssertEqual(name.type, .unresolved(simpleName: "String", arguments: []))
    }

    func testGenericFieldType() {
        let result = build("class Foo { List<String> items; }")
        let foo = try! XCTUnwrap(result.classes.first)
        let items = try! XCTUnwrap(foo.fields.first)
        guard case .unresolved(let simpleName, let args) = items.type else {
            return XCTFail("expected unresolved List<String>")
        }
        XCTAssertEqual(simpleName, "List")
        XCTAssertEqual(args, [.type(.unresolved(simpleName: "String", arguments: []))])
    }

    func testArrayFieldTypeAndMultiDimensional() {
        let result = build("class Foo { String[] names; int[][] grid; }")
        let foo = try! XCTUnwrap(result.classes.first)
        let names = try! XCTUnwrap(foo.fields.first { $0.name == "names" })
        guard case .array(let element) = names.type else { return XCTFail("expected array") }
        if case .unresolved(let simple, _) = element {
            XCTAssertEqual(simple, "String")
        } else {
            XCTFail("expected unresolved String element")
        }

        let grid = try! XCTUnwrap(foo.fields.first { $0.name == "grid" })
        guard case .array(let outer) = grid.type, case .array(let inner) = outer else {
            return XCTFail("expected int[][]")
        }
        XCTAssertEqual(inner, .primitive(.int))
    }

    // MARK: - Methods

    func testMethodWithParametersAndReturnType() {
        let result = build("class Foo { public int add(int a, int b) { return a + b; } }")
        let foo = try! XCTUnwrap(result.classes.first)
        let add = try! XCTUnwrap(foo.methods.first)
        XCTAssertEqual(add.name, "add")
        XCTAssertEqual(add.parameters.map(\.name), ["a", "b"])
        XCTAssertEqual(add.parameters.map(\.type), [.primitive(.int), .primitive(.int)])
        XCTAssertEqual(add.returnType, .primitive(.int))
        XCTAssertTrue(add.modifiers.contains(.publicFlag))
        XCTAssertFalse(add.isConstructor)
    }

    func testGenericMethodWithVarargs() {
        let result = build("class Foo { public <T> List<T> make(T t, int... rest) { return null; } }")
        let foo = try! XCTUnwrap(result.classes.first)
        let make = try! XCTUnwrap(foo.methods.first)
        XCTAssertEqual(make.typeParameters.map(\.name), ["T"])
        XCTAssertTrue(make.modifiers.contains(.varargs))
        XCTAssertEqual(make.parameters.count, 2)
        guard case .array(let element) = make.parameters[1].type else { return XCTFail("expected int[] for varargs") }
        XCTAssertEqual(element, .primitive(.int))
    }

    func testConstructors() {
        let result = build("class Foo { public Foo() {} public Foo(int x) {} }")
        let foo = try! XCTUnwrap(result.classes.first)
        let ctors = foo.methods.filter(\.isConstructor)
        XCTAssertEqual(ctors.count, 2)
        XCTAssertTrue(ctors.contains { $0.parameters.isEmpty })
        XCTAssertTrue(ctors.contains { $0.parameters.count == 1 })
    }

    func testDeprecatedAnnotationSetsFlag() {
        let result = build("class Foo { @Deprecated public void old() {} }")
        let foo = try! XCTUnwrap(result.classes.first)
        let old = try! XCTUnwrap(foo.methods.first)
        XCTAssertTrue(old.modifiers.contains(.deprecatedFlag))
    }

    func testArrayParameterType() {
        let result = build("class Foo { public static void main(String[] args) {} }")
        let foo = try! XCTUnwrap(result.classes.first)
        let main = try! XCTUnwrap(foo.methods.first)
        guard case .array(let element) = main.parameters.first?.type else { return XCTFail("expected String[] param") }
        XCTAssertEqual(element.simpleDisplayName, "String")
    }

    // MARK: - Interfaces / abstract methods

    func testInterfaceMethodIsImplicitlyPublicAbstract() {
        let result = build("interface Foo { void bar(); }")
        let foo = try! XCTUnwrap(result.classes.first)
        XCTAssertEqual(foo.kind, .interfaceKind)
        let bar = try! XCTUnwrap(foo.methods.first)
        XCTAssertTrue(bar.modifiers.contains(.publicFlag))
        XCTAssertTrue(bar.modifiers.contains(.abstractFlag))
    }

    // MARK: - Enums

    func testEnumConstantsBecomeStaticFinalFields() {
        let result = build("enum Foo { A, B, C }")
        let foo = try! XCTUnwrap(result.classes.first)
        XCTAssertEqual(foo.kind, .enumKind)
        XCTAssertEqual(foo.fields.map(\.name), ["A", "B", "C"])
        XCTAssertTrue(foo.fields.allSatisfy { $0.modifiers.contains(.staticFlag) && $0.modifiers.contains(.enumConstant) })
    }

    func testEnumWithMembersAfterConstants() {
        let result = build("enum Foo { A, B; void bar() {} int x; }")
        let foo = try! XCTUnwrap(result.classes.first)
        XCTAssertEqual(foo.fields.filter { $0.modifiers.contains(.enumConstant) }.map(\.name), ["A", "B"])
        XCTAssertTrue(foo.methods.contains { $0.name == "bar" })
        XCTAssertTrue(foo.fields.contains { $0.name == "x" && !$0.modifiers.contains(.enumConstant) })
    }

    // MARK: - Records

    func testRecordSynthesizesFieldsAndAccessors() {
        let result = build("record Point(int x, int y) {}")
        let point = try! XCTUnwrap(result.classes.first)
        XCTAssertEqual(point.kind, .recordKind)
        XCTAssertEqual(Set(point.fields.map(\.name)), ["x", "y"])
        XCTAssertTrue(point.methods.contains { $0.name == "x" && $0.parameters.isEmpty && $0.returnType == .primitive(.int) })
        XCTAssertTrue(point.methods.contains { $0.name == "y" && $0.parameters.isEmpty && $0.returnType == .primitive(.int) })
    }

    // MARK: - Nested types

    func testNestedTypesGetOuterQualifiedNameAndInnerTypeNames() {
        let result = build("class Foo { class Inner {} static class Nested {} }")
        let foo = try! XCTUnwrap(result.classes.first { $0.simpleName == "Foo" })
        XCTAssertEqual(Set(foo.innerTypeNames), ["Foo.Inner", "Foo.Nested"])

        let inner = try! XCTUnwrap(result.classes.first { $0.simpleName == "Inner" })
        XCTAssertEqual(inner.outerQualifiedName, "Foo")
        XCTAssertEqual(inner.qualifiedName, "Foo.Inner")

        let nested = try! XCTUnwrap(result.classes.first { $0.simpleName == "Nested" })
        XCTAssertTrue(nested.modifiers.contains(.staticFlag))
    }

    func testDeeplyNestedGenericType() {
        let result = build("class Foo<T> { T value; static class Nested<U> {} }")
        XCTAssertEqual(result.classes.count, 2)
        let nested = try! XCTUnwrap(result.classes.first { $0.simpleName == "Nested" })
        XCTAssertEqual(nested.typeParameters.map(\.name), ["U"])
        XCTAssertEqual(nested.qualifiedName, "Foo.Nested")
    }

    // MARK: - Javadoc

    func testJavadocOnClassAndMember() {
        let source = """
        /**
         * A javadoc comment on the class.
         */
        public class Foo {
            /**
             * A javadoc comment on the method.
             * @param a the value
             */
            public void bar(int a) {}
        }
        """
        let result = build(source)
        let foo = try! XCTUnwrap(result.classes.first)
        XCTAssertEqual(foo.javadoc, "A javadoc comment on the class.")
        let bar = try! XCTUnwrap(foo.methods.first)
        XCTAssertTrue(bar.javadoc?.contains("A javadoc comment on the method.") == true)
        XCTAssertTrue(bar.javadoc?.contains("@param a the value") == true)
    }

    func testNoJavadocWhenNoPrecedingComment() {
        let result = build("public class Foo { public void bar() {} }")
        XCTAssertNil(result.classes.first?.javadoc)
    }

    func testOrdinaryLineCommentIsNotTreatedAsJavadoc() {
        let result = build("// not a javadoc\npublic class Foo {}")
        XCTAssertNil(result.classes.first?.javadoc)
    }

    // MARK: - Origin

    func testOriginIsSourceWithNameByteRange() {
        let source = "class Foo {}"
        let url = URL(fileURLWithPath: "/tmp/Foo.java")
        let result = JavaSourceStubBuilder.build(source: source, url: url)
        let foo = try! XCTUnwrap(result.classes.first)
        guard case .source(let origin, let range) = foo.origin else { return XCTFail("expected .source origin") }
        XCTAssertEqual(origin, url)
        let utf8 = Array(source.utf8)
        XCTAssertEqual(String(decoding: utf8[range], as: UTF8.self), "Foo")
    }

    // MARK: - Real fixture file, end-to-end

    func testBuildsFromRealFixtureFile() throws {
        let url = JavaFixtures.directory.appendingPathComponent("src/Fixture.java")
        let source = try String(contentsOf: url, encoding: .utf8)
        let result = JavaSourceStubBuilder.build(source: source, url: url)

        XCTAssertEqual(result.packageName, "com.penumbra.fixture")
        XCTAssertEqual(Set(result.imports.map(\.qualifiedName)), ["java.util.List", "java.util.Map"])

        let names = Set(result.classes.map(\.qualifiedName))
        XCTAssertTrue(names.contains("com.penumbra.fixture.Fixture"))
        XCTAssertTrue(names.contains("com.penumbra.fixture.Fixture.Kind"))
        XCTAssertTrue(names.contains("com.penumbra.fixture.Fixture.Listener"))
        XCTAssertTrue(names.contains("com.penumbra.fixture.Fixture.Nested"))
        XCTAssertTrue(names.contains("com.penumbra.fixture.Fixture.Point"))

        let fixture = try XCTUnwrap(result.classes.first { $0.qualifiedName == "com.penumbra.fixture.Fixture" })
        XCTAssertEqual(fixture.javadoc, "A javadoc comment on the class.")
        XCTAssertTrue(fixture.methods.contains { $0.name == "add" })
        XCTAssertTrue(fixture.methods.contains { $0.name == "oldMethod" && $0.modifiers.contains(.deprecatedFlag) })
        XCTAssertTrue(fixture.methods.contains { $0.isConstructor })
        XCTAssertNotNil(fixture.fields.first { $0.name == "name" }) // private field, kept for source stubs
    }
}
