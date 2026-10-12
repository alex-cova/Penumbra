import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class GradleProblemMatcherTests: XCTestCase {
    private func match(_ out: String = "", _ err: String = "") -> GradleProblemMatches {
        GradleProblemMatcher.match(stdout: out, stderr: err, baseDirectory: URL(fileURLWithPath: "/work"))
    }

    func testJavacFailureMatchesMapperAndAddsNoWrapperMessage() {
        let err = """
        /work/app/src/Main.java:3: error: ';' expected
                int x = 1
                         ^
        1 error

        FAILURE: Build failed with an exception.

        * What went wrong:
        Execution failed for task ':app:compileJava'.
        > Compilation failed; see the compiler error output for details.

        * Try:
        > Run with --stacktrace
        """
        let result = match("> Task :app:compileJava FAILED\n", err)
        let expected = JavacDiagnosticsMapper.diagnostics(
            from: JavacOutputParser.parse(err), source: "gradle", baseDirectory: URL(fileURLWithPath: "/work")
        ) { _ in nil }
        XCTAssertEqual(result.diagnostics.mapValues { $0.map(\.message) }, expected.mapValues { $0.map(\.message) })
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertTrue(result.problems.isEmpty)
    }

    func testKotlinBothForms() throws {
        let out = """
        > Task :app:compileKotlin FAILED
        e: file:///work/app/src/A.kt:4:9: Unresolved reference: foo
        w: /work/app/src/B.kt: (10, 3): Variable 'x' is never used
        e: Compilation error
        """
        let result = match(out)
        let a = try XCTUnwrap(result.diagnostics[URL(fileURLWithPath: "/work/app/src/A.kt")]?.first)
        XCTAssertEqual(a.severity, .error)
        XCTAssertEqual(a.range.start.line, 3)
        XCTAssertEqual(a.range.start.column, 8)
        let b = try XCTUnwrap(result.diagnostics[URL(fileURLWithPath: "/work/app/src/B.kt")]?.first)
        XCTAssertEqual(b.severity, .warning)
        XCTAssertEqual(b.range.start.line, 9)
        XCTAssertEqual(result.problems.map(\.message), ["Compilation error", "Task :app:compileKotlin failed"])
        XCTAssertEqual(result.problems.first?.task, ":app:compileKotlin")
    }

    func testBuildScriptError() {
        let err = """
        FAILURE: Build failed with an exception.

        * Where:
        Build file '/work/build.gradle' line: 12

        * What went wrong:
        A problem occurred evaluating root project 'demo'.
        > Could not find method foo() for arguments [] on root project 'demo'.

        * Try:
        > Run with --stacktrace
        """
        let problem = match("", err).problems.first
        XCTAssertEqual(problem?.file, URL(fileURLWithPath: "/work/build.gradle"))
        XCTAssertEqual(problem?.line, 12)
        XCTAssertEqual(problem?.message, "A problem occurred evaluating root project 'demo'.")
    }

    func testScriptCompilationError() {
        let err = """
        * Where:
        Build file '/work/build.gradle' line: 3

        * What went wrong:
        Script compilation error:

          Line 3: foo bar
                      ^ unexpected token: bar

        1 error

        * Try:
        """
        let problems = match("", err).problems
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems[0].line, 3)
        XCTAssertEqual(problems[0].message, "unexpected token: bar")
        XCTAssertEqual(problems[0].file?.lastPathComponent, "build.gradle")
    }

    func testDependencyResolutionFailure() {
        let err = """
        * What went wrong:
        Execution failed for task ':app:compileJava'.
        > Could not resolve all files for configuration ':app:compileClasspath'.
           > Could not resolve com.example:missing:1.0.
             Required by:
                 project :app

        * Try:
        """
        let problems = match("", err).problems
        XCTAssertEqual(problems.count, 1)
        XCTAssertEqual(problems[0].message, "Could not resolve com.example:missing:1.0.")
        XCTAssertEqual(problems[0].task, ":app:compileJava")
    }

    func testTestFailureSummary() {
        let out = "> Task :test FAILED\n\n5 tests completed, 2 failed\n"
        let err = """
        * What went wrong:
        Execution failed for task ':test'.
        > There were failing tests. See the report at: file:///work/build/reports/tests/test/index.html

        * Try:
        """
        let result = match(out, err)
        XCTAssertEqual(result.problems.map(\.message), ["2 tests failed"])
        XCTAssertEqual(result.problems.first?.kind, .testFailures)
        XCTAssertEqual(result.problems.first?.task, ":test")
        let summary = GradleProblemMatcher.testFailureSummary(in: GradleCommandResult(exitCode: 1, stdout: out, stderr: err))
        XCTAssertEqual(summary?.completed, 5)
        XCTAssertEqual(summary?.failed, 2)
    }

    func testFailingTestsWithoutSummaryLine() {
        let err = "* What went wrong:\nExecution failed for task ':test'.\n> There were failing tests. See the report\n\n* Try:\n"
        XCTAssertEqual(match("", err).problems.map(\.message), ["There were failing tests"])
    }

    func testSuccessfulBuildHasNothing() {
        let out = "> Task :app:compileJava\n> Task :app:test\n\nBUILD SUCCESSFUL in 1s\n2 actionable tasks: 2 executed\n"
        let result = match(out)
        XCTAssertTrue(result.problems.isEmpty)
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertNil(GradleProblemMatcher.testFailureSummary(in: out))
    }

    func testFailedTaskWithoutExplanationIsReported() {
        let result = match("> Task :lib:jar FAILED\n")
        XCTAssertEqual(result.problems.first?.task, ":lib:jar")
    }

    func testInterleavedProjectsAttributeToCurrentTask() {
        let out = """
        > Task :core:compileKotlin
        w: file:///work/core/A.kt:1:1: warn one
        > Task :app:compileKotlin FAILED
        e: Something broke
        """
        let result = match(out)
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.problems.first?.task, ":app:compileKotlin")
    }
}
