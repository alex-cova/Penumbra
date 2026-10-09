import XCTest
@testable import JavaIntelligence

final class JavaLaunchTests: XCTestCase {
    func testRecognizesPublicStaticVoidMainInEitherModifierOrder() {
        XCTAssertTrue(JavaMainMethod.containsMain(in: "public static void main(String[] args) {}"))
        XCTAssertTrue(JavaMainMethod.containsMain(in: "static public void main(String... args) {}"))
        XCTAssertTrue(JavaMainMethod.containsMain(in: "public static final void main(String args[]) {}"))
    }

    func testRecognizesTheInstanceFormsOfJava21() {
        XCTAssertTrue(JavaMainMethod.containsMain(in: "public void main(String[] args) {}"))
        XCTAssertTrue(JavaMainMethod.containsMain(in: "void main() {}"))
        XCTAssertTrue(JavaMainMethod.containsMain(in: "static void main() {}"))
        XCTAssertTrue(JavaMainMethod.containsMain(in: "protected void main(java.lang.String... args) {}"))
        XCTAssertFalse(JavaMainMethod.containsMain(in: "private void main() {}"))
        XCTAssertFalse(JavaMainMethod.containsMain(in: "private static void main(String[] args) {}"))
        XCTAssertFalse(JavaMainMethod.containsMain(in: "int main() { return 0; }"))
        XCTAssertFalse(JavaMainMethod.containsMain(in: "void main(int count) {}"))
        XCTAssertFalse(JavaMainMethod.containsMain(in: "void main(String[][] args) {}"))
        XCTAssertFalse(JavaMainMethod.containsMain(in: "void domain() {}"))
        XCTAssertFalse(JavaMainMethod.containsMain(in: "x.void main() {}"))
    }

    func testIgnoresMainInsideCommentsOrStrings() {
        XCTAssertFalse(JavaMainMethod.containsMain(in: "// public static void main(String[] args)"))
        XCTAssertFalse(JavaMainMethod.containsMain(in: "/* public static void main(String[] args) */"))
        XCTAssertFalse(JavaMainMethod.containsMain(in: "String s = \"public static void main(String[] args)\";"))
    }

    func testLocatesMainMethodsWithTheirLinesAndClasses() {
        let source = """
        package a.b;

        public class App {
            public static void main(String[] args) {}

            static class Inner {
                static public void main(String... args) {}
            }
        }

        class Other {
            public static final void main(java.lang.String args[]) {}
        }
        """
        XCTAssertEqual(JavaMainMethod.locations(in: source), [
            JavaMainMethodLocation(line: 4, simpleClassName: "App", binaryClassName: "a.b.App"),
            JavaMainMethodLocation(line: 7, simpleClassName: "Inner", binaryClassName: "a.b.App$Inner"),
            JavaMainMethodLocation(line: 12, simpleClassName: "Other", binaryClassName: "a.b.Other")
        ])
    }

    func testLocationsIgnoreMethodsThatCannotBeLaunched() {
        let source = """
        class App {
            private void main(String[] args) {}
            private static void main() {}
            public static int main(String[] args) { return 0; }
            public static void main(int count) {}
            public static void main(String[][] args) {}
            public static void main(String[] args, int extra) {}
            // public static void main(String[] args) {}
            String s = "public static void main(String[] args) {}";
        }
        """
        XCTAssertEqual(JavaMainMethod.locations(in: source), [])
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

    // MARK: - Java 21+ launch protocol

    func testInstanceAndNoArgumentMainsAreLocatedWithTheirShape() {
        let source = """
        class A {
            void main() {}
        }

        class B {
            public void main(String[] args) {}
        }

        class C {
            static void main() {}
        }
        """
        let found = JavaMainMethod.locations(in: source)
        XCTAssertEqual(found.map(\.simpleClassName), ["A", "B", "C"])
        XCTAssertEqual(found.map(\.isStatic), [false, false, true])
        XCTAssertEqual(found.map(\.takesArguments), [false, true, false])
        XCTAssertTrue(found.allSatisfy(\.usesNewLaunchProtocol))
        XCTAssertFalse(JavaMainMethodLocation(line: 1, simpleClassName: "A", binaryClassName: "A").usesNewLaunchProtocol)
    }

    func testAClassKeepsOnlyTheMainTheJVMWouldChoose() {
        let source = """
        class App {
            void main() {}
            void main(String[] args) {}
            static void main() {}
            static void main(String[] args) {}
        }

        class Instances {
            void main() {}
            void main(String[] args) {}
        }

        class NoArgs {
            void main() {}
            static void main() {}
        }
        """
        let found = JavaMainMethod.locations(in: source)
        XCTAssertEqual(found.map(\.simpleClassName), ["App", "Instances", "NoArgs"])
        XCTAssertEqual(found.map(\.line), [5, 10, 15])
        XCTAssertFalse(found[0].usesNewLaunchProtocol, "the classic main wins")
        XCTAssertTrue(found[1].usesNewLaunchProtocol)
        XCTAssertEqual(found[2].isStatic, true, "static beats instance")
    }

    func testInstanceMainsNeedAClassThatCanBeCreated() {
        let source = """
        interface Api {
            default void main() {}
            static void main(String[] args) {}
        }

        abstract class Base {
            void main() {}
        }

        abstract class Tool {
            static void main(String[] args) {}
        }

        enum Mode { ON; void main() {} }
        record Point(int x) { void main() {} }
        """
        let found = JavaMainMethod.locations(in: source)
        XCTAssertEqual(found.map(\.simpleClassName), ["Api", "Tool", "Mode", "Point"])
        XCTAssertEqual(found.first?.line, 3, "only the interface's static main can start it")
    }

    func testACompactSourceFileIsItsOwnClass() {
        let source = """
        import java.util.List;

        String greeting = "hello";

        void main() {
            System.out.println(greeting);
        }
        """
        let found = JavaMainMethod.locations(in: source, fileName: "Hello.java")
        XCTAssertEqual(found, [
            JavaMainMethodLocation(
                line: 5, simpleClassName: "Hello", binaryClassName: "Hello",
                isStatic: false, takesArguments: false, isImplicitClass: true
            )
        ])
        XCTAssertTrue(found[0].usesNewLaunchProtocol)
        XCTAssertEqual(JavaMainMethod.locations(in: source).first?.simpleClassName, "Main", "no file name, no better guess")
    }

    func testAMainInsideAMethodBodyOrAnonymousClassIsNotALaunchTarget() {
        let source = """
        class App {
            void run() {
                Object o = new Object() {
                    void main() {}
                };
            }
        }
        """
        XCTAssertEqual(JavaMainMethod.locations(in: source), [])
    }
}

