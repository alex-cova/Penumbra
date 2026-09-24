import XCTest
@testable import JavaIntelligence

final class JavaRunConfigurationTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/proj")

    // MARK: - Commands

    func testGradleRunWithArgumentsAndEnvironment() {
        let configuration = JavaRunConfiguration(
            target: .gradleRun(projectPath: ":app"),
            programArguments: "--port 8080 \"two words\"",
            vmArguments: "-Xmx1g",
            environment: ["MODE": "dev mode", "A": "1"]
        )
        let command = JavaLaunchCommand.make(configuration: configuration, projectRoot: root, gradleWrapperExists: true)
        // VM arguments are not passed to Gradle's run task; the rest are.
        XCTAssertEqual(
            command?.shellCommand,
            "cd '/proj' && A='1' MODE='dev mode' ./gradlew :app:run --args='--port 8080 \"two words\"'"
        )
    }

    func testRootGradleRunWithoutArgumentsIsJustRun() {
        let command = JavaLaunchCommand.make(
            configuration: JavaRunConfiguration(target: .gradleRun(projectPath: ":")), projectRoot: root, gradleWrapperExists: false
        )
        XCTAssertEqual(command?.shellCommand, "cd '/proj' && gradle run")
    }

    func testArgumentsWithASingleQuoteAreEscaped() {
        let command = JavaLaunchCommand.make(
            configuration: JavaRunConfiguration(target: .gradleRun(projectPath: ":"), programArguments: "it's"),
            projectRoot: root, gradleWrapperExists: true
        )
        XCTAssertEqual(command?.shellCommand, "cd '/proj' && ./gradlew run --args='it'\\''s'")
    }

    func testSingleFileWithVMAndProgramArgumentsAndEnvironment() {
        let configuration = JavaRunConfiguration(
            target: .singleFile(path: "/tmp/My App.java"),
            programArguments: "one \"two words\"",
            vmArguments: "-Xmx512m -Dmode=fast",
            environment: ["TOKEN": "abc"]
        )
        let command = JavaLaunchCommand.make(configuration: configuration, projectRoot: nil, gradleWrapperExists: false)
        XCTAssertEqual(
            command?.shellCommand,
            "TOKEN='abc' java -Xmx512m -Dmode=fast '/tmp/My App.java' one \"two words\""
        )
    }

    func testEmptySettingsLeaveNoExtraSpaces() {
        let command = JavaLaunchCommand.make(
            configuration: JavaRunConfiguration(target: .singleFile(path: "/tmp/A.java"), programArguments: "  ", vmArguments: "\n"),
            projectRoot: nil, gradleWrapperExists: false
        )
        XCTAssertEqual(command?.shellCommand, "java '/tmp/A.java'")
    }

    func testInvalidEnvironmentNamesAreDropped() {
        let command = JavaLaunchCommand.make(
            configuration: JavaRunConfiguration(target: .singleFile(path: "/tmp/A.java"), environment: ["BAD NAME": "x", "1BAD": "y", "GOOD_1": "z"]),
            projectRoot: nil, gradleWrapperExists: false
        )
        XCTAssertEqual(command?.shellCommand, "GOOD_1='z' java '/tmp/A.java'")
    }

    func testGradleTargetNeedsAProjectRoot() {
        XCTAssertNil(JavaLaunchCommand.make(
            configuration: JavaRunConfiguration(target: .gradleRun(projectPath: ":")), projectRoot: nil, gradleWrapperExists: false
        ))
    }

    // MARK: - Defaults and inheritance

    func testDefaultTargetsFollowTheProjectKind() {
        let file = URL(fileURLWithPath: "/proj/app/src/main/java/App.java")
        let model = JavaGradleProjectModel(
            formatVersion: 2, gradleVersion: "9.0",
            subprojects: [.init(path: ":app", directory: root.appendingPathComponent("app"), sourceDirs: [file.deletingLastPathComponent()])]
        )
        XCTAssertEqual(
            JavaRunConfiguration.makeDefault(file: file, projectRoot: root, isGradleProject: true, model: model)?.target,
            .gradleRun(projectPath: ":app")
        )
        XCTAssertEqual(
            JavaRunConfiguration.makeDefault(file: file, projectRoot: root, isGradleProject: true, model: nil)?.target,
            .gradleRun(projectPath: ":")
        )
        XCTAssertEqual(
            JavaRunConfiguration.makeDefault(file: file, projectRoot: nil, isGradleProject: false, model: nil)?.target,
            .singleFile(path: file.path)
        )
        XCTAssertNil(JavaRunConfiguration.makeDefault(file: URL(fileURLWithPath: "/tmp/notes.txt"), projectRoot: nil, isGradleProject: false, model: nil))
    }

    func testInheritingSettingsOnlyFromTheSameTarget() {
        let previous = JavaRunConfiguration(
            target: .singleFile(path: "/tmp/A.java"), programArguments: "x", vmArguments: "-ea", environment: ["K": "v"]
        )
        let same = JavaRunConfiguration(target: .singleFile(path: "/tmp/A.java")).inheritingSettings(from: previous)
        XCTAssertEqual(same, previous)
        let other = JavaRunConfiguration(target: .singleFile(path: "/tmp/B.java")).inheritingSettings(from: previous)
        XCTAssertEqual(other.target, .singleFile(path: "/tmp/B.java"))
        XCTAssertEqual(other.programArguments, "")
        XCTAssertTrue(other.environment.isEmpty)
    }

    func testDisplayNamesAndVMArgumentSupport() {
        XCTAssertEqual(JavaRunConfiguration(target: .gradleRun(projectPath: ":")).displayName, "Gradle run")
        XCTAssertEqual(JavaRunConfiguration(target: .gradleRun(projectPath: ":app")).displayName, "Gradle run (:app)")
        XCTAssertEqual(JavaRunConfiguration(target: .singleFile(path: "/tmp/A.java")).displayName, "A.java")
        XCTAssertFalse(JavaRunConfiguration(target: .gradleRun(projectPath: ":")).supportsVMArguments)
        XCTAssertTrue(JavaRunConfiguration(target: .singleFile(path: "/tmp/A.java")).supportsVMArguments)
    }

    func testEnvironmentTextRoundTripsAndToleratesNoise() {
        let text = "# comment\n\nB=two=parts\n A = spaced \nNOEQUALS\n=novalue\n"
        XCTAssertEqual(JavaRunConfiguration.parseEnvironment(text), ["B": "two=parts", "A": " spaced"])
        let environment = ["Z": "1", "A": "x y"]
        XCTAssertEqual(JavaRunConfiguration.environmentText(environment), "A=x y\nZ=1")
        XCTAssertEqual(JavaRunConfiguration.parseEnvironment(JavaRunConfiguration.environmentText(environment)), environment)
    }

    // MARK: - Persistence

    func testCodableRoundTrip() throws {
        let configurations = [
            JavaRunConfiguration(target: .gradleRun(projectPath: ":app"), programArguments: "a b", environment: ["K": "v"]),
            JavaRunConfiguration(target: .singleFile(path: "/tmp/A.java"), vmArguments: "-ea")
        ]
        let data = try JSONEncoder().encode(configurations)
        XCTAssertEqual(try JSONDecoder().decode([JavaRunConfiguration].self, from: data), configurations)
    }

    func testStoreKeepsTheLastConfigurationPerProjectAcrossInstances() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString)/run-configurations.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JavaRunConfigurationStore(storeURL: file)
        XCTAssertNil(store.last(forProject: root))

        let one = JavaRunConfiguration(target: .gradleRun(projectPath: ":app"), programArguments: "go")
        let two = JavaRunConfiguration(target: .singleFile(path: "/tmp/A.java"))
        store.setLast(one, forProject: root)
        store.setLast(two, forProject: nil)
        store.setLast(JavaRunConfiguration(target: .gradleRun(projectPath: ":")), forProject: URL(fileURLWithPath: "/other"))

        let reopened = JavaRunConfigurationStore(storeURL: file)
        XCTAssertEqual(reopened.last(forProject: root), one)
        XCTAssertEqual(reopened.last(forProject: nil), two)
        store.setLast(two, forProject: root)
        XCTAssertEqual(JavaRunConfigurationStore(storeURL: file).last(forProject: root), two)
    }

    func testCorruptStoreFileStartsEmpty() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)
        XCTAssertNil(JavaRunConfigurationStore(storeURL: file).last(forProject: root))
    }
}
