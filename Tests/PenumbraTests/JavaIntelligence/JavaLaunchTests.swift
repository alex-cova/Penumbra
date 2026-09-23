import XCTest
@testable import JavaIntelligence

final class JavaLaunchTests: XCTestCase {
    func testRecognizesPublicStaticVoidMainInEitherModifierOrder() {
        XCTAssertTrue(JavaMainMethod.containsMain(in: "public static void main(String[] args) {}"))
        XCTAssertTrue(JavaMainMethod.containsMain(in: "static public void main(String... args) {}"))
        XCTAssertTrue(JavaMainMethod.containsMain(in: "public static final void main(String args[]) {}"))
    }

    func testIgnoresMainWithoutStaticAndMainInsideCommentsOrStrings() {
        XCTAssertFalse(JavaMainMethod.containsMain(in: "public void main(String[] args) {}"))
        XCTAssertFalse(JavaMainMethod.containsMain(in: "// public static void main(String[] args)"))
        XCTAssertFalse(JavaMainMethod.containsMain(in: "/* public static void main(String[] args) */"))
        XCTAssertFalse(JavaMainMethod.containsMain(in: "String s = \"public static void main(String[] args)\";"))
    }

    func testPlainFileLaunchesWithJava() {
        let file = URL(fileURLWithPath: "/tmp/Hello World.java")
        let command = JavaLaunchCommand.make(
            file: file,
            projectRoot: nil,
            isGradleProject: false,
            model: nil,
            gradleWrapperExists: false
        )
        XCTAssertEqual(command?.shellCommand, "java '/tmp/Hello World.java'")
    }

    func testGradleProjectPrefersWrapperAndSubprojectRunTask() {
        let root = URL(fileURLWithPath: "/proj")
        let file = URL(fileURLWithPath: "/proj/app/src/main/java/com/example/App.java")
        let model = JavaGradleProjectModel(
            formatVersion: 2,
            gradleVersion: "9.0",
            subprojects: [
                .init(
                    path: ":app",
                    directory: root.appendingPathComponent("app"),
                    sourceDirs: [URL(fileURLWithPath: "/proj/app/src/main/java")]
                )
            ]
        )
        let command = JavaLaunchCommand.make(
            file: file,
            projectRoot: root,
            isGradleProject: true,
            model: model,
            gradleWrapperExists: true
        )
        XCTAssertEqual(command?.shellCommand, "cd '/proj' && ./gradlew :app:run")
    }

    func testGradleBuildUsesTheWrapperAtTheProjectRoot() {
        let command = JavaLaunchCommand.build(
            projectRoot: URL(fileURLWithPath: "/proj"),
            gradleWrapperExists: true
        )
        XCTAssertEqual(command.shellCommand, "cd '/proj' && ./gradlew build")
    }

    func testGradleBuildFallsBackToGradleOnPath() {
        let command = JavaLaunchCommand.build(
            projectRoot: URL(fileURLWithPath: "/My Project"),
            gradleWrapperExists: false
        )
        XCTAssertEqual(command.shellCommand, "cd '/My Project' && gradle build")
    }

    func testGradleProjectWithoutAMatchingSourceSetRunsAtTheRoot() {
        let root = URL(fileURLWithPath: "/proj")
        let command = JavaLaunchCommand.make(
            file: URL(fileURLWithPath: "/proj/Scratch.java"),
            projectRoot: root,
            isGradleProject: true,
            model: nil,
            gradleWrapperExists: false
        )
        XCTAssertEqual(command?.shellCommand, "cd '/proj' && gradle run")
    }
}
