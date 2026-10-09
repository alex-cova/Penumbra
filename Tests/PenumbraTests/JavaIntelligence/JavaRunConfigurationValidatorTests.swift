import XCTest
@testable import JavaIntelligence

final class JavaRunConfigurationValidatorTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/proj")

    private func context(
        model: JavaGradleProjectModel? = nil,
        others: [JavaRunConfiguration] = [],
        existing: Set<String> = [],
        directories: Set<String> = [],
        jdkVersion: Int? = nil
    ) -> JavaRunConfigurationValidator.Context {
        JavaRunConfigurationValidator.Context(
            projectRoot: root,
            gradleModel: model,
            configurations: others,
            jdkFeatureVersion: jdkVersion,
            fileExists: { existing.contains($0) },
            directoryExists: { directories.contains($0) }
        )
    }

    private func model(tasks: [JavaGradleProjectModel.GradleTask] = []) throws -> JavaGradleProjectModel {
        try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("runtime-classpath"))
    }

    private func messages(_ configuration: JavaRunConfiguration, _ context: JavaRunConfigurationValidator.Context) -> [String] {
        JavaRunConfigurationValidator.problems(for: configuration, context: context).map(\.message)
    }

    func testAHealthyFileAndClassHaveNoProblems() {
        let file = JavaRunConfiguration(target: .singleFile(path: "/proj/A.java"))
        XCTAssertEqual(messages(file, context(existing: ["/proj/A.java"])), [])
        let main = JavaRunConfiguration(target: .classpathMain(className: "app.Main", sourceFile: "/proj/Main.java"))
        XCTAssertEqual(messages(main, context(existing: ["/proj/Main.java"])), [])
    }

    func testAMissingOrWrongFileIsReported() {
        let missing = JavaRunConfiguration(target: .singleFile(path: "/proj/A.java"))
        XCTAssertEqual(messages(missing, context()), ["A.java does not exist."])
        let notJava = JavaRunConfiguration(target: .singleFile(path: "/proj/A.txt"))
        XCTAssertEqual(messages(notJava, context(existing: ["/proj/A.txt"])), ["Choose a .java file."])
    }

    func testAClassNeedsAPlainNameAndItsSourceFile() {
        let empty = JavaRunConfiguration(target: .classpathMain(className: "", sourceFile: ""))
        XCTAssertEqual(messages(empty, context()), ["Choose a main class.", "Choose the source file of the class."])
        XCTAssertEqual(
            JavaRunConfigurationValidator.problems(for: empty, context: context()).map(\.field), [.target, .sourceFile],
            "each message belongs to its own field"
        )
        let bad = JavaRunConfiguration(target: .classpathMain(className: "a..B", sourceFile: "/proj/B.java"))
        XCTAssertEqual(messages(bad, context(existing: ["/proj/B.java"])), ["“a..B” is not a class name."])
    }

    func testGradleChecksWaitForASyncedModel() throws {
        let run = JavaRunConfiguration(target: .gradleRun(projectPath: ":nowhere"))
        XCTAssertEqual(messages(run, context()), [], "nothing to check against before the first sync")
        let synced = try model()
        XCTAssertEqual(messages(run, context(model: synced)), ["There is no Gradle project “:nowhere”."])
    }

    /// A synced model with `:` (a `build` task) and `:app` (`run` and `test`).
    private func modelWithTasks() -> JavaGradleProjectModel {
        func task(_ path: String) -> JavaGradleProjectModel.GradleTask {
            JavaGradleProjectModel.GradleTask(path: path, name: String(path.split(separator: ":").last ?? ""), group: "x")
        }
        return JavaGradleProjectModel(formatVersion: 5, gradleVersion: "8.5", subprojects: [
            JavaGradleProjectModel.Subproject(
                path: ":", directory: URL(fileURLWithPath: "/proj"), sourceSets: [], tasks: [task(":build")]
            ),
            JavaGradleProjectModel.Subproject(
                path: ":app", directory: URL(fileURLWithPath: "/proj/app"), sourceSets: [], tasks: [task(":app:run"), task(":app:test")]
            )
        ])
    }

    func testAGradleRunNeedsAProjectAndATaskThatExist() {
        let synced = modelWithTasks()
        XCTAssertEqual(messages(JavaRunConfiguration(target: .gradleRun(projectPath: ":app")), context(model: synced)), [])
        XCTAssertEqual(
            messages(JavaRunConfiguration(target: .gradleRun(projectPath: ":app", taskName: "bootRun")), context(model: synced)),
            [":app has no task named “bootRun”."]
        )
        XCTAssertEqual(
            messages(JavaRunConfiguration(target: .gradleRun(projectPath: ":")), context(model: synced)),
            ["The root project has no task named “run”."]
        )
        XCTAssertEqual(
            messages(JavaRunConfiguration(target: .gradleRun(projectPath: ":lib")), context(model: synced)),
            ["There is no Gradle project “:lib”."]
        )
    }

    func testATestTaskMustBeOneOfTheProjectsTasks() {
        let synced = modelWithTasks()
        func check(_ path: String) -> [String] {
            messages(JavaRunConfiguration(target: .gradleTest(taskPath: path, filters: [], sourceFile: nil)), context(model: synced))
        }
        XCTAssertEqual(check(":app:test"), [])
        XCTAssertEqual(check(":app:integrationTest"), ["There is no task “:app:integrationTest”."])
        XCTAssertEqual(check(":lib:test"), ["There is no Gradle project “:lib”."])
        XCTAssertEqual(check(":test"), ["There is no task “:test”."])
    }

    func testTestTaskPathsMustLookLikeOne() {
        for path in ["test", ":", ":app:"] {
            let configuration = JavaRunConfiguration(target: .gradleTest(taskPath: path, filters: [], sourceFile: nil))
            XCTAssertEqual(messages(configuration, context()), ["“\(path)” is not a Gradle task path."], path)
        }
        XCTAssertEqual(
            messages(JavaRunConfiguration(target: .gradleTest(taskPath: ":app:test", filters: [], sourceFile: nil)), context()),
            []
        )
    }

    func testEnvironmentInputAndWorkingDirectoryAreCheckedOnlyWhereTheyApply() {
        var main = JavaRunConfiguration(target: .classpathMain(className: "a.B", sourceFile: "/proj/B.java"))
        main.workingDirectory = "/nope"
        main.redirectInputPath = "/nope.txt"
        main.jdkHome = "/jdk"
        let found = JavaRunConfigurationValidator.problems(for: main, context: context(existing: ["/proj/B.java"]))
        XCTAssertEqual(found.map(\.field), [.workingDirectory, .redirectInput, .jdk])

        var gradle = JavaRunConfiguration(target: .gradleRun(projectPath: ":"))
        gradle.workingDirectory = "/nope"
        gradle.redirectInputPath = "/nope.txt"
        XCTAssertEqual(messages(gradle, context()), [], "a Gradle task ignores both")

        main.workingDirectory = "/work"
        main.redirectInputPath = "/in.txt"
        main.jdkHome = "/jdk"
        XCTAssertEqual(
            messages(main, context(existing: ["/proj/B.java", "/in.txt", "/jdk/bin/java"], directories: ["/work"])),
            []
        )
    }

    func testBeforeLaunchStepsMustExistAndNotWaitOnEachOther() {
        let a = JavaRunConfiguration(name: "A", target: .singleFile(path: "/a.java"))
        var b = JavaRunConfiguration(name: "B", target: .singleFile(path: "/b.java"))
        var c = JavaRunConfiguration(name: "C", target: .singleFile(path: "/c.java"))
        let ghost = UUID()
        let files: Set<String> = ["/a.java", "/b.java", "/c.java"]

        var configuration = a
        configuration.beforeLaunch = [.runConfiguration(ghost)]
        XCTAssertEqual(messages(configuration, context(existing: files)), ["A configuration it runs first was deleted."])

        configuration.beforeLaunch = [.runConfiguration(configuration.id)]
        XCTAssertEqual(messages(configuration, context(existing: files)), ["A configuration cannot run itself first."])

        configuration.beforeLaunch = [.gradleTasks([" "])]
        XCTAssertEqual(messages(configuration, context(existing: files)), ["A Gradle step has no task."])

        // A runs B, B runs C, C runs A.
        configuration.beforeLaunch = [.runConfiguration(b.id)]
        b.beforeLaunch = [.runConfiguration(c.id)]
        c.beforeLaunch = [.runConfiguration(configuration.id)]
        XCTAssertEqual(
            messages(configuration, context(others: [b, c], existing: files)),
            ["“B” runs this configuration first, so they wait on each other."]
        )

        c.beforeLaunch = []
        XCTAssertEqual(messages(configuration, context(others: [b, c], existing: files)), [])
    }
}
