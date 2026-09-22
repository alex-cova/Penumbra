import XCTest
@testable import JavaIntelligence

/// Not a real assertion-driven test suite -- dumps tree-sitter-java's real S-expression for known
/// source shapes so `JavaSourceStubBuilder` can be built against verified grammar node types
/// instead of assumed ones. Kept in the suite (rather than deleted) as living documentation of the
/// exact grammar shape `JavaSourceStubBuilder` depends on; if a tree-sitter-java upgrade changes
/// these shapes, this is the first place that will need updating.
final class JavaSyntaxTreeGroundTruthTests: XCTestCase {
    func testDumpFixtureSExpression() throws {
        let source = try String(contentsOf: JavaFixtures.directory.appendingPathComponent("src/Fixture.java"), encoding: .utf8)
        let parser = JavaSyntaxParser()
        let tree = try XCTUnwrap(parser.parse(source))
        print("=== Fixture.java ===")
        print(tree.rootNode.sExpression)
    }

    func testDumpSmallSnippets() throws {
        let parser = JavaSyntaxParser()
        let snippets = [
            "package com.example;",
            "import java.util.List;",
            "import java.util.*;",
            "import static java.lang.Math.max;",
            "public class Foo extends Bar implements Baz, Qux { }",
            "public class Foo<T extends Comparable<T>> { }",
            "class Foo { int x; public String name; }",
            "class Foo { public int add(int a, int b) { return a + b; } }",
            "class Foo { public <T> List<T> make(T t, int... rest) { return null; } }",
            "class Foo { public Foo() {} public Foo(int x) {} }",
            "class Foo { @Deprecated public void old() {} }",
            "class Foo { class Inner {} static class Nested {} }",
            "interface Foo { void bar(); }",
            "enum Foo { A, B, C }",
            "record Point(int x, int y) {}",
            "class Foo { public static void main(String[] args) {} }",
            "class Foo { List<? extends Number> a; List<? super Integer> b; List<?> c; }",
            "class Foo { int[][] grid; }",
            "@interface Foo { String value(); int count() default 1; }",
            "class Foo { static { x = 1; } }",
            "class Foo<T> { T value; static class Nested<U> {} }",
            "enum Foo { A, B; void bar() {} int x; }",
            "class Foo { final int x = 1; }"
        ]
        for snippet in snippets {
            guard let tree = parser.parse(snippet) else { continue }
            print("=== \(snippet) ===")
            print(tree.rootNode.sExpression)
        }
    }
}
