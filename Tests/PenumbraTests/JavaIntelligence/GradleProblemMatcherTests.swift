import EditorIntelligence
import JavaIntelligence
import XCTest

final class GradleProblemMatcherTests: XCTestCase {
    func testParsesFailedTask() {
        let output = """
        > Task :app:test FAILED

        FAILURE: Build failed with an exception.

        * What went wrong:
        Execution failed for task ':app:test'.
        """
        let problems = GradleProblemMatcher.parse(output, baseDirectory: URL(fileURLWithPath: "/proj"))
        XCTAssertFalse(problems.isEmpty)
        let diagnostics = GradleProblemMatcher.diagnostics(from: problems, baseDirectory: URL(fileURLWithPath: "/proj"))
        XCTAssertFalse(diagnostics.isEmpty)
    }

    func testGradleTestFailureDoesNotRequireJavacFormat() {
        let output = """
        > Task :app:test FAILED

        com.example.FooTest > bar FAILED
            org.opentest4j.AssertionFailedError at FooTest.java:12
        """
        let problems = GradleProblemMatcher.parse(output, baseDirectory: URL(fileURLWithPath: "/proj"))
        XCTAssertFalse(problems.isEmpty)
    }
}
