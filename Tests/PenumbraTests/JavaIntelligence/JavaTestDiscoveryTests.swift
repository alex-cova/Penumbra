import JavaIntelligence
import XCTest

final class JavaTestDiscoveryTests: XCTestCase {
    func testDiscoversJUnit5Test() {
        let source = """
        package com.example;

        import org.junit.jupiter.api.Test;

        class FooTest {
            @Test
            void bar() {}
        }
        """
        let methods = JavaTestDiscovery.discover(source: source, url: URL(fileURLWithPath: "/proj/src/test/java/FooTest.java"))
        XCTAssertEqual(methods["com.example.FooTest"]?.map(\.methodName), ["bar"])
        XCTAssertEqual(methods["com.example.FooTest"]?.first?.framework, .junit5)
    }

    func testDiscoversJUnit4TestWithImport() {
        let source = """
        package com.example;

        import org.junit.Test;

        public class LegacyTest {
            @Test
            public void old() {}
        }
        """
        let methods = JavaTestDiscovery.discover(source: source, url: URL(fileURLWithPath: "/x/LegacyTest.java"))
        XCTAssertEqual(methods["com.example.LegacyTest"]?.first?.framework, .junit4)
    }

    func testIgnoresNonTestMethods() {
        let source = """
        package com.example;

        import org.junit.jupiter.api.Test;

        class FooTest {
            void helper() {}
            @Test
            void bar() {}
        }
        """
        let methods = JavaTestDiscovery.discover(source: source, url: URL(fileURLWithPath: "/x/FooTest.java"))
        XCTAssertEqual(methods["com.example.FooTest"]?.map(\.methodName), ["bar"])
    }

    func testNestedClassTest() {
        let source = """
        package com.example;

        import org.junit.jupiter.api.Test;

        class OuterTest {
            static class Inner {
                @Test
                void innerMethod() {}
            }
        }
        """
        let methods = JavaTestDiscovery.discover(source: source, url: URL(fileURLWithPath: "/x/OuterTest.java"))
        XCTAssertEqual(methods["com.example.OuterTest.Inner"]?.map(\.methodName), ["innerMethod"])
    }
}
