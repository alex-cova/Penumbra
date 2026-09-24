import XCTest
@testable import JavaIntelligence

final class JavaStackTraceParserTests: XCTestCase {
    func testParsesFrameKinds() {
        let f = JavaStackTraceParser.frame(fromLine: "\tat com.acme.Calc.add(Calc.java:42)")
        XCTAssertEqual(f, JavaStackFrame(className: "com.acme.Calc", methodName: "add", fileName: "Calc.java", line: 42))
        let n = JavaStackTraceParser.frame(fromLine: "at java.lang.Object.wait(Native Method)")
        XCTAssertEqual(n?.isNative, true)
        XCTAssertNil(n?.line)
        let u = JavaStackTraceParser.frame(fromLine: "at a.B.c(Unknown Source)")
        XCTAssertNil(u?.fileName)
        let mod = JavaStackTraceParser.frame(fromLine: "at java.base/java.util.ArrayList.get(ArrayList.java:427)")
        XCTAssertEqual(mod?.className, "java.util.ArrayList")
        let app = JavaStackTraceParser.frame(fromLine: "at app//com.acme.Outer$Inner.run(Outer.java:7)")
        XCTAssertEqual(app?.className, "com.acme.Outer$Inner")
        XCTAssertEqual(JavaStackTraceParser.frame(fromLine: "at com.acme.Lambda.lambda$0(Lambda.java:3)")?.methodName, "lambda$0")
        XCTAssertNil(JavaStackTraceParser.frame(fromLine: "Caused by: java.lang.Foo: bar"))
        XCTAssertNil(JavaStackTraceParser.frame(fromLine: "\t... 5 more"))
    }

    func testFirstProjectFrameSkipsFrameworkCode() {
        let trace = """
        org.opentest4j.AssertionFailedError: x
        \tat org.junit.jupiter.api.Assertions.fail(Assertions.java:1)
        \tat java.base/jdk.internal.Foo.bar(Foo.java:2)
        \tat com.acme.CalcTest.divides(CalcTest.java:42)
        \tat org.gradle.Worker.run(Worker.java:9)
        """
        XCTAssertEqual(JavaStackTraceParser.frames(in: trace).count, 4)
        let first = JavaStackTraceParser.firstProjectFrame(in: trace)
        XCTAssertEqual(first?.className, "com.acme.CalcTest")
        XCTAssertEqual(first?.line, 42)
        XCTAssertNil(JavaStackTraceParser.firstProjectFrame(in: "at java.lang.X.y(X.java:1)"))
    }
}
