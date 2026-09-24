import XCTest
@testable import JavaIntelligence

final class JavaTestScannerTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/FooTest.java")

    private func scan(_ source: String, _ frameworks: Set<JavaTestFramework> = []) -> [JavaTestClass] {
        JavaTestScanner.scan(source: source, url: url, frameworks: frameworks)
    }

    func testJUnit5Kinds() {
        let classes = scan("""
        package a.b;
        import org.junit.jupiter.api.*;
        import org.junit.jupiter.params.ParameterizedTest;
        class FooTest {
            @Test void plain() {}
            @ParameterizedTest void param(int x) {}
            @RepeatedTest(3) void rep() {}
            @TestFactory Object fac() { return null; }
            @TestTemplate void tpl() {}
            void helper() {}
        }
        """)
        XCTAssertEqual(classes.count, 1)
        XCTAssertEqual(classes[0].qualifiedName, "a.b.FooTest")
        XCTAssertEqual(classes[0].framework, .junit5)
        XCTAssertEqual(classes[0].methods.map(\.kind), [.test, .parameterized, .repeated, .factory, .template])
        XCTAssertEqual(classes[0].methods.map(\.name), ["plain", "param", "rep", "fac", "tpl"])
    }

    func testNameRangeIsMethodName() {
        let source = "import org.junit.jupiter.api.Test;\nclass T { @Test void go() {} }"
        let method = scan(source)[0].methods[0]
        XCTAssertEqual(String(decoding: Array(source.utf8)[method.nameRange], as: UTF8.self), "go")
    }

    func testJUnit4AndIgnoreAndRunWith() {
        let classes = scan("""
        import org.junit.Test;
        import org.junit.Ignore;
        import org.junit.runner.RunWith;
        @RunWith(Parameterized.class)
        public class LegacyTest {
            @Test public void a() {}
            @Ignore @Test public void b() {}
        }
        """)
        XCTAssertEqual(classes[0].framework, .junit4)
        XCTAssertEqual(classes[0].runner, "Parameterized.class")
        XCTAssertEqual(classes[0].methods.map(\.isDisabled), [false, true])
    }

    func testNestedClassesAndDisplayNames() {
        let classes = scan("""
        package p;
        import org.junit.jupiter.api.*;
        @DisplayName("Outer tests")
        class OuterTest {
            @Test @DisplayName("does \\"it\\"") void one() {}
            @Nested @Disabled class InnerTest {
                @Test void two() {}
            }
        }
        """)
        XCTAssertEqual(classes.count, 2)
        XCTAssertEqual(classes[0].displayName, "Outer tests")
        XCTAssertEqual(classes[0].methods[0].displayName, "does \"it\"")
        XCTAssertEqual(classes[1].binaryName, "p.OuterTest$InnerTest")
        XCTAssertEqual(classes[1].qualifiedName, "p.OuterTest.InnerTest")
        XCTAssertTrue(classes[1].isNested)
        XCTAssertTrue(classes[1].isDisabled)
        XCTAssertFalse(classes[0].isDisabled)
        XCTAssertEqual(classes[1].displayName, "InnerTest")
    }

    func testDisabledMethodJUnit5() {
        let c = scan("import org.junit.jupiter.api.*;\nclass T { @Disabled @Test void a() {} @Test void b() {} }")[0]
        XCTAssertEqual(c.methods.map(\.isDisabled), [true, false])
    }

    func testFullyQualifiedAnnotation() {
        let classes = scan("class T { @org.junit.Test public void a() {} @org.junit.jupiter.api.Test void b() {} }")
        XCTAssertEqual(classes[0].methods.map(\.framework), [.junit4, .junit5])
    }

    func testExplicitImportOfOtherLibraryIsNotATest() {
        let classes = scan("import org.testng.annotations.Test;\nclass T { @Test void a() {} }", [.junit5, .junit4])
        XCTAssertTrue(classes.isEmpty)
    }

    func testImportDistinguishesJUnit4And5() {
        XCTAssertEqual(scan("import org.junit.Test;\nclass T { @Test void a() {} }", [.junit5])[0].framework, .junit4)
        XCTAssertEqual(scan("import org.junit.jupiter.api.Test;\nclass T { @Test void a() {} }")[0].framework, .junit5)
    }

    func testOnDemandJUnit4Import() {
        XCTAssertEqual(scan("import org.junit.*;\nclass T { @Test public void a() {} }")[0].framework, .junit4)
    }

    func testUnresolvableSimpleNameNeedsFrameworkOnClasspath() {
        let source = "import com.example.*;\nclass T { @Test void a() {} }"
        XCTAssertTrue(scan(source, []).isEmpty)
        XCTAssertEqual(scan(source, [.junit5])[0].framework, .junit5)
        XCTAssertEqual(scan(source, [.junit4])[0].framework, .junit4)
    }

    func testNonTestClassesIgnored() {
        let classes = scan("""
        import org.junit.jupiter.api.Test;
        class Plain { void a() {} @Deprecated void b() {} }
        interface I { @Test void x(); }
        class NoTests { private @Test void hidden() {} }
        """)
        XCTAssertTrue(classes.isEmpty)
    }

    func testAbstractBaseInSameFile() {
        let classes = scan("""
        import org.junit.jupiter.api.Test;
        abstract class Base { @Test void shared() {} @Test void over() {} }
        class Impl extends Base { @Test void own() {} @Test void over() {} }
        class Unrelated extends Other {}
        """)
        let base = classes.first { $0.simpleName == "Base" }
        XCTAssertEqual(base?.isAbstract, true)
        let impl = classes.first { $0.simpleName == "Impl" }
        XCTAssertEqual(impl?.methods.map(\.name), ["own", "over", "shared"])
        XCTAssertEqual(impl?.methods.last?.inheritedFrom, "Base")
        XCTAssertNil(impl?.methods.first?.inheritedFrom)
        XCTAssertNil(classes.first { $0.simpleName == "Unrelated" })
    }

    func testFrameworkDetectionByJarName() {
        func jars(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/m/\($0)") } }
        XCTAssertEqual(JavaTestFramework.detect(classpathJars: jars("junit-jupiter-api-5.10.0.jar")), [.junit5])
        XCTAssertEqual(JavaTestFramework.detect(classpathJars: jars("junit-jupiter-5.10.0.jar", "junit-4.13.2.jar")), [.junit4, .junit5])
        XCTAssertEqual(JavaTestFramework.detect(classpathJars: jars("junit-4.jar")), [.junit4])
        XCTAssertTrue(JavaTestFramework.detect(classpathJars: jars("guava-32.jar", "junit-platform-commons-1.10.jar")).isEmpty)
    }
}
