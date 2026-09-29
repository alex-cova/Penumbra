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

    func testJavaHomeMakesASingleFileLaunchUseThatJDKsJava() {
        let command = JavaLaunchCommand.make(
            configuration: JavaRunConfiguration(target: .singleFile(path: "/tmp/A.java")),
            projectRoot: nil,
            gradleWrapperExists: false,
            javaHome: URL(fileURLWithPath: "/jdks/temurin 21")
        )
        XCTAssertEqual(command?.shellCommand, "'/jdks/temurin 21/bin/java' '/tmp/A.java'")
    }

    func testJavaHomeMakesAClasspathLaunchUseThatJDKsJava() {
        let command = JavaLaunchCommand.make(
            configuration: JavaRunConfiguration(target: .classpathMain(className: "app.Main", sourceFile: "/p/Main.java")),
            projectRoot: URL(fileURLWithPath: "/p"),
            gradleWrapperExists: true,
            runtimeClasspath: [URL(fileURLWithPath: "/p/build/classes")],
            javaHome: URL(fileURLWithPath: "/jdks/17")
        )
        XCTAssertEqual(command?.shellCommand, "'/jdks/17/bin/java' -cp '/p/build/classes' app.Main")
    }

    func testJavaHomeSetsJavaHomeAndPathAheadOfAGradleLaunchsOwnEnvironment() {
        let command = JavaLaunchCommand.make(
            configuration: JavaRunConfiguration(target: .gradleRun(projectPath: ":"), environment: ["JAVA_HOME": "/mine"]),
            projectRoot: URL(fileURLWithPath: "/p"),
            gradleWrapperExists: true,
            javaHome: URL(fileURLWithPath: "/jdks/17")
        )
        XCTAssertEqual(
            command?.shellCommand,
            "cd '/p' && JAVA_HOME='/jdks/17' PATH='/jdks/17/bin':\"$PATH\" JAVA_HOME='/mine' ./gradlew run"
        )
    }

    func testJavaHomeAppliesToGradleBuild() {
        let command = JavaLaunchCommand.build(
            projectRoot: URL(fileURLWithPath: "/p"), gradleWrapperExists: false, javaHome: URL(fileURLWithPath: "/jdks/17")
        )
        XCTAssertEqual(command.shellCommand, "cd '/p' && JAVA_HOME='/jdks/17' PATH='/jdks/17/bin':\"$PATH\" gradle build")
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
