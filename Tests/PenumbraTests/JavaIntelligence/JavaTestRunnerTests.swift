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

    func testAnUnqualifiedRunUsesEveryTestTaskTheModelLists() {
        let app = URL(fileURLWithPath: "/proj/app")
        let lib = URL(fileURLWithPath: "/proj/lib")
        let model = JavaGradleProjectModel(formatVersion: 5, gradleVersion: "9.0", subprojects: [
            .init(
                path: ":app", directory: app,
                sourceSets: [
                    .init(name: "test", outputDirs: [app.appendingPathComponent("build/classes/java/test")]),
                    .init(name: "integrationTest", outputDirs: [app.appendingPathComponent("build/classes/java/integrationTest")])
                ],
                tasks: [
                    .init(path: ":app:test", name: "test", group: "verification"),
                    .init(path: ":app:integrationTest", name: "integrationTest", group: "verification"),
                    .init(path: ":app:cleanTest", name: "cleanTest", group: "verification"),
                    .init(path: ":app:build", name: "build", group: "build")
                ]
            ),
            .init(
                path: ":lib", directory: lib,
                sourceSets: [.init(name: "test", outputDirs: [lib.appendingPathComponent("build/classes/java/test")])],
                tasks: [.init(path: ":lib:test", name: "test", group: "verification")]
            )
        ])

        XCTAssertEqual(
            JavaTestRunner.projectTestTaskPaths(model: model),
            [":app:test", ":app:integrationTest", ":lib:test"]
        )
        XCTAssertEqual(JavaTestRunner.projectTestTaskPaths(model: nil), ["test"])
        XCTAssertEqual(
            JavaTestRunner.executionTaskPaths(scope: .allInModule(gradleTaskPath: "test"), model: model, debug: false),
            [":app:test", ":app:integrationTest", ":lib:test"]
        )
        // A saved configuration names one task. It must not grow into the other modules.
        XCTAssertEqual(
            JavaTestRunner.executionTaskPaths(scope: .allInModule(gradleTaskPath: ":app:test"), model: model, debug: false),
            [":app:test"]
        )
        XCTAssertEqual(
            JavaTestRunner.executionTaskPaths(scope: .allInModule(gradleTaskPath: "test"), model: model, debug: true),
            [":app:cleanTest", ":app:test", ":app:cleanIntegrationTest", ":app:integrationTest", ":lib:cleanTest", ":lib:test"]
        )

        let reports = JavaTestRunner.reportDirectories(
            forTaskPaths: [":app:cleanTest", ":app:test", ":lib:test"], model: model
        ).map(\.path)
        XCTAssertEqual(reports, [
            "/proj/app/build/classes/test-results/test",
            "/proj/lib/build/classes/test-results/test"
        ])
    }

    func testAModelWithoutATaskListUsesTestSourceSets() {
        let root = URL(fileURLWithPath: "/proj")
        let model = JavaGradleProjectModel(formatVersion: 5, gradleVersion: "8.5", subprojects: [
            .init(path: ":", directory: root, sourceSets: [
                .init(name: "main", sourceDirs: [root.appendingPathComponent("src/main/java")]),
                .init(name: "test", sourceDirs: [root.appendingPathComponent("src/test/java")])
            ])
        ])
        XCTAssertEqual(JavaTestRunner.projectTestTaskPaths(model: model), [":test"])
        let reports = JavaTestRunner.reportDirectories(forTaskPaths: ["test"], model: model).map(\.path)
        XCTAssertEqual(reports, ["/proj/build/test-results/test"])
    }
}
