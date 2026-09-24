import XCTest
@testable import JavaIntelligence

final class JavaTestCommandTests: XCTestCase {
    private let script = URL(fileURLWithPath: "/tmp/s.gradle")

    private var model: JavaGradleProjectModel {
        let app = JavaGradleProjectModel.Subproject(
            path: ":app", directory: URL(fileURLWithPath: "/p/app"),
            sourceSets: [
                .init(name: "test", sourceDirs: [URL(fileURLWithPath: "/p/app/src/test/java")]),
                .init(name: "integrationTest", sourceDirs: [URL(fileURLWithPath: "/p/app/src/integrationTest/java")])
            ],
            testTasks: [
                .init(path: ":app:test", name: "test", sourceSetName: "test"),
                .init(path: ":app:integrationTest", name: "integrationTest", sourceSetName: "integrationTest")
            ]
        )
        return JavaGradleProjectModel(formatVersion: 6, gradleVersion: "8.5", subprojects: [app])
    }

    func testClassRequest() {
        let r = JavaTestCommand.make(request: .class(binaryName: "pkg.Outer$Inner", taskPath: ":app:test"), model: model, initScriptURL: script)
        XCTAssertEqual(r.tasks, [":app:cleanTest", ":app:test", "--tests", "pkg.Outer$Inner"])
        XCTAssertEqual(r.arguments, ["-I", "/tmp/s.gradle"])
    }

    func testMethodRequest() {
        let r = JavaTestCommand.make(request: .method(binaryName: "pkg.A", methodName: "square", taskPath: ":app:integrationTest"), model: nil, initScriptURL: script)
        XCTAssertEqual(r.tasks, [":app:cleanIntegrationTest", ":app:integrationTest", "--tests", "pkg.A.square"])
    }

    func testAllInSubprojectRunsEveryTestTask() {
        let r = JavaTestCommand.make(request: .allInSubproject(":app"), model: model, initScriptURL: script)
        XCTAssertEqual(r.tasks, [":app:cleanTest", ":app:test", ":app:cleanIntegrationTest", ":app:integrationTest"])
    }

    func testFallbackToTestTaskAndRootProject() {
        XCTAssertEqual(JavaTestCommand.make(request: .allInSubproject(":lib"), model: model, initScriptURL: script).tasks, [":lib:cleanTest", ":lib:test"])
        XCTAssertEqual(JavaTestCommand.make(request: .allInSubproject(":"), model: nil, initScriptURL: script).tasks, [":cleanTest", ":test"])
    }

    func testFailedGroupsFiltersPerTaskKeepingOrder() {
        let r = JavaTestCommand.make(request: .failed([
            .init(className: "a.A", methodName: "x", taskPath: ":app:test"),
            .init(className: "b.B", taskPath: ":lib:test"),
            .init(className: "a.A", methodName: "y", taskPath: ":app:test"),
            .init(className: "a.A", methodName: "x", taskPath: ":app:test")
        ]), model: model, initScriptURL: script)
        XCTAssertEqual(r.tasks, [
            ":app:cleanTest", ":app:test", "--tests", "a.A.x", "--tests", "a.A.y",
            ":lib:cleanTest", ":lib:test", "--tests", "b.B"
        ])
    }

    func testSourceSetTaskAndFileResolution() {
        XCTAssertEqual(JavaTestCommand.make(request: .sourceSetTask(":app:test"), model: model, initScriptURL: script).tasks, [":app:cleanTest", ":app:test"])
        let file = URL(fileURLWithPath: "/p/app/src/integrationTest/java/pkg/IT.java")
        XCTAssertEqual(JavaTestCommand.testTaskPath(forFile: file, model: model), ":app:integrationTest")
    }
}
