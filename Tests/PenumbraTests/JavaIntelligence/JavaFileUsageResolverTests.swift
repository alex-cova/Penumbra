import XCTest
@testable import JavaIntelligence

final class JavaFileUsageResolverTests: XCTestCase {
    // MARK: - Overloads

    func testOverloadSiblingsAreExcluded() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", """
        class A {
            void €run(Foo f) {}
            void run(Bar b) {}
            void go() {
                Foo foo = new Foo();
                Bar bar = new Bar();
                run(foo);
                run(bar);
                this.run(foo);
            }
        }
        class Foo {}
        class Bar {}
        """)
        let id = try await fixture.requireID()
        let usages = try await fixture.fileUsages(of: id, in: "A.java")
        XCTAssertEqual(fixture.lines(usages), [
            "A.java: void run(Foo f) {}", "A.java: run(foo);", "A.java: this.run(foo);"
        ])
        XCTAssertEqual(usages.map(\.kind), [.declaration, .call, .call])
        XCTAssertTrue(usages.allSatisfy { $0.confidence == .exact })
    }

    func testUntypedArgumentsMakeOverloadCallsAmbiguous() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", """
        class A {
            void €run(Foo f) {}
            void run(Bar b) {}
            void go() { run(unknown()); }
        }
        class Foo {}
        class Bar {}
        """)
        let id = try await fixture.requireID()
        let usages = try await fixture.fileUsages(of: id, in: "A.java")
        let call = try XCTUnwrap(usages.first { $0.kind == .call })
        XCTAssertEqual(call.confidence, .ambiguous)
    }

    // MARK: - Shadowing

    func testFieldUsagesExcludeShadowingLocals() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", """
        class A {
            int €x;
            void a() { x = 1; }
            void b() { int x = 2; x++; }
            void c(int x) { System.out.println(x); }
            int d() { return this.x + x; }
        }
        """)
        let id = try await fixture.requireID()
        XCTAssertEqual(id, .field(declaringClass: "A", name: "x"))
        let usages = try await fixture.fileUsages(of: id, in: "A.java")
        XCTAssertEqual(fixture.lines(usages), [
            "A.java: int x;", "A.java: void a() { x = 1; }", "A.java: int d() { return this.x + x; }",
            "A.java: int d() { return this.x + x; }"
        ])
        XCTAssertEqual(usages.map(\.kind), [.declaration, .write, .read, .read])
    }

    func testLocalUsagesExcludeTheShadowedField() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", """
        class A {
            int x;
            void b() { int €x = 2; x++; use(x); }
            void c() { x = 3; }
            void use(int v) {}
        }
        """)
        let id = try await fixture.requireID()
        let usages = try await fixture.fileUsages(of: id, in: "A.java")
        XCTAssertEqual(usages.map(\.kind), [.declaration, .write, .read])
        XCTAssertEqual(Set(usages.map(\.line)), [2])
        XCTAssertEqual(usages.map { fixture.text(of: $0) }, ["x", "x", "x"])
    }

    func testParametersAndLambdaParametersAreLocals() async throws {
        let fixture = try JavaReferenceFixture()
        let source = """
        class A {
            void go(int €limit) {
                Runnable r = () -> System.out.println(limit);
                java.util.function.Consumer<String> c = s -> use(s, limit);
                int other = limit;
            }
            void use(String s, int n) {}
        }
        """
        try fixture.add("A.java", source)
        let id = try await fixture.requireID()
        let usages = JavaLocalUsages.usages(of: id, in: fixture.sources["A.java"]!)
        XCTAssertEqual(usages.count, 4)
        XCTAssertEqual(usages.first?.kind, .declaration)

        let lambda = try JavaReferenceFixture()
        let lambdaSource = "class B { void go() { java.util.function.Consumer<String> c = €s -> use(s, s); } void use(String a, String b) {} }"
        try lambda.add("B.java", lambdaSource)
        let lambdaID = try await lambda.requireID()
        XCTAssertEqual(JavaLocalUsages.usages(of: lambdaID, in: lambda.sources["B.java"]!).count, 3)
    }

    // MARK: - Imports

    func testStaticImportsAndTheirCalls() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Util.java", "package p; public class Util { public static void €helper() {} public static void other() {} }")
        try fixture.add("Use.java", """
        package q;
        import static p.Util.helper;
        import static p.Util.other;
        class Use { void go() { helper(); other(); } }
        """)
        let id = try await fixture.requireID()
        let usages = try await fixture.fileUsages(of: id, in: "Use.java")
        XCTAssertEqual(fixture.lines(usages), ["Use.java: import static p.Util.helper;", "Use.java: class Use { void go() { helper(); other(); } }"])
        XCTAssertEqual(usages.map(\.kind), [.import, .call])
    }

    func testStaticImportedField() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Consts.java", "package p; public class Consts { public static final int €LIMIT = 3; }")
        try fixture.add("Use.java", "package q; import static p.Consts.LIMIT; class Use { int go() { return LIMIT; } }")
        let id = try await fixture.requireID()
        let usages = try await fixture.fileUsages(of: id, in: "Use.java")
        XCTAssertEqual(usages.map(\.kind), [.import, .read])
    }

    func testTypeImportAndQualifiedNames() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Foo.java", "package p; public class €Foo { public static void make() {} }")
        try fixture.add("Use.java", """
        package q;
        import p.Foo;
        class Use {
            Foo a;
            p.Foo b = new p.Foo();
            void go() { p.Foo.make(); Foo.make(); }
        }
        """)
        let id = try await fixture.requireID()
        let usages = try await fixture.fileUsages(of: id, in: "Use.java")
        XCTAssertEqual(usages.count, 6)
        XCTAssertEqual(usages.first?.kind, .import)
        XCTAssertTrue(usages.allSatisfy { fixture.text(of: $0) == "Foo" })
    }

    func testSameSimpleNameInAnotherPackageIsNotAUsage() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Foo.java", "package p; public class €Foo {}")
        try fixture.add("Other.java", "package other; public class Foo {}")
        try fixture.add("Use.java", "package q; import other.Foo; class Use { Foo f; }")
        let id = try await fixture.requireID()
        let usages = try await fixture.fileUsages(of: id, in: "Use.java")
        XCTAssertTrue(usages.isEmpty)
    }

    // MARK: - Nested types

    func testNestedTypeUsages() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Outer.java", """
        package p;
        public class Outer {
            public static class €Inner {}
            Inner a;
            static class Deep { Inner b; }
        }
        """)
        try fixture.add("Use.java", "package p; class Use { Outer.Inner x = new Outer.Inner(); }")
        let id = try await fixture.requireID()
        XCTAssertEqual(id, .type(qualifiedName: "p.Outer.Inner"))
        let outer = try await fixture.fileUsages(of: id, in: "Outer.java")
        XCTAssertEqual(outer.map(\.kind), [.declaration, .typeReference, .typeReference])
        let use = try await fixture.fileUsages(of: id, in: "Use.java")
        XCTAssertEqual(use.count, 2)
    }

    func testUnqualifiedCallToAnOuterClassMethodFromAnInnerClass() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Outer.java", """
        class Outer {
            void €ping() {}
            class Inner { void go() { ping(); } }
        }
        """)
        let id = try await fixture.requireID()
        let usages = try await fixture.fileUsages(of: id, in: "Outer.java")
        XCTAssertEqual(usages.map(\.kind), [.declaration, .call])
    }

    // MARK: - Inheritance

    func testInheritedMemberCallsThroughSubtypeReceivers() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Base.java", "class Base { void €hello() {} }")
        try fixture.add("Sub.java", "class Sub extends Base { void own() { hello(); super.hello(); this.hello(); } }")
        try fixture.add("Other.java", "class Other { void hello() {} }")
        try fixture.add("Use.java", "class Use { void go(Sub s, Other o) { s.hello(); o.hello(); } }")
        let id = try await fixture.requireID()
        let sub = try await fixture.fileUsages(of: id, in: "Sub.java")
        XCTAssertEqual(sub.count, 3)
        let use = try await fixture.fileUsages(of: id, in: "Use.java")
        XCTAssertEqual(fixture.lines(use), ["Use.java: class Use { void go(Sub s, Other o) { s.hello(); o.hello(); } }"])
        XCTAssertEqual(use.map(\.column), [Array("class Use { void go(Sub s, Other o) { s.".utf16).count])
        let other = try await fixture.fileUsages(of: id, in: "Other.java")
        XCTAssertTrue(other.isEmpty)
    }

    func testFieldInheritedThroughSubtype() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Base.java", "class Base { int €size; }")
        try fixture.add("Sub.java", "class Sub extends Base { int total() { return size + this.size; } }")
        let id = try await fixture.requireID()
        let usages = try await fixture.fileUsages(of: id, in: "Sub.java")
        XCTAssertEqual(usages.count, 2)
    }

    // MARK: - Method references

    func testMethodReferences() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Base.java", "class Base { void €hello() {} }")
        try fixture.add("Use.java", """
        class Use {
            void go(Base b) {
                Runnable r = b::hello;
                java.util.function.Consumer<Base> c = Base::hello;
            }
        }
        """)
        let id = try await fixture.requireID()
        let usages = try await fixture.fileUsages(of: id, in: "Use.java")
        XCTAssertEqual(usages.map(\.kind), [.methodReference, .methodReference])
        XCTAssertTrue(usages.allSatisfy { fixture.text(of: $0) == "hello" })
    }

    // MARK: - Constructors

    func testConstructorUsagesIncludeNewThisAndSuper() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Foo.java", """
        class Foo {
            Foo() { this(1); }
            €Foo(int n) {}
            Foo(Bar b) {}
        }
        class Sub extends Foo {
            Sub() { super(2); }
            Object make() { return new Foo(3); }
            Object other() { return new Foo(new Bar()); }
        }
        class Bar {}
        """)
        let id = try await fixture.requireID()
        XCTAssertEqual(id, .constructor(declaringClass: "Foo", parameterKeys: ["int"]))
        let usages = try await fixture.fileUsages(of: id, in: "Foo.java")
        XCTAssertEqual(usages.map(\.kind), [.constructorCall, .declaration, .constructorCall, .constructorCall], "\(usages.map { ($0.lineText, $0.confidence) })")
        XCTAssertEqual(fixture.text(of: usages[0]), "this")
        XCTAssertEqual(fixture.text(of: usages[2]), "super")
    }

    func testTypeUsagesIncludeConstructorCallsAndConstructorNames() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Foo.java", """
        class €Foo {
            Foo(int n) {}
            static Foo make() { return new Foo(1); }
        }
        """)
        let id = try await fixture.requireID()
        let usages = try await fixture.fileUsages(of: id, in: "Foo.java")
        XCTAssertEqual(usages.map(\.kind), [.declaration, .declaration, .typeReference, .constructorCall])
    }

    // MARK: - Annotations

    func testAnnotationTypeUsages() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("Marker.java", "@interface €Marker {}")
        try fixture.add("Use.java", "@Marker class Use { @Marker void go() {} }")
        let id = try await fixture.requireID()
        let usages = try await fixture.fileUsages(of: id, in: "Use.java")
        XCTAssertEqual(usages.map(\.kind), [.typeReference, .typeReference])
    }

    // MARK: - Unknown receivers

    func testCallOnAnUntypeableReceiverIsAmbiguous() async throws {
        let fixture = try JavaReferenceFixture()
        try fixture.add("A.java", "class A { void €hello() {} }")
        try fixture.add("Use.java", "class Use { void go() { mystery().hello(); } }")
        let id = try await fixture.requireID()
        let usages = try await fixture.fileUsages(of: id, in: "Use.java")
        XCTAssertEqual(usages.map(\.confidence), [.ambiguous])
    }
}
