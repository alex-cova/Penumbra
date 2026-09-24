import JavaIntelligence
import XCTest

final class JavaTestRunnerTests: XCTestCase {
    func testGradleArgumentsForMethod() {
        let request = JavaTestRunRequest(
            gradleTaskPath: ":app:test",
            testFilter: "com.example.FooTest.bar",
            projectRoot: URL(fileURLWithPath: "/proj"),
            reportDirectories: []
        )
        let args = JavaTestRunner.gradleArguments(for: request)
        XCTAssertTrue(args.contains("--tests"))
        XCTAssertTrue(args.contains("com.example.FooTest.bar"))
        XCTAssertTrue(args.contains("--continue"))
    }

    func testIsTestTask() {
        XCTAssertTrue(JavaTestRunner.isTestTask(":test"))
        XCTAssertTrue(JavaTestRunner.isTestTask(":app:test"))
        XCTAssertTrue(JavaTestRunner.isTestTask(":app:integrationTest"))
        XCTAssertFalse(JavaTestRunner.isTestTask(":app:build"))
    }
}
