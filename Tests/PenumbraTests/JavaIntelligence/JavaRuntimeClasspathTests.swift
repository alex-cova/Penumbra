import XCTest
@testable import JavaIntelligence

final class JavaRuntimeClasspathTests: XCTestCase {
    private func model() throws -> JavaGradleProjectModel {
        try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("runtime-classpath"))
    }

    private func paths(_ urls: [URL]?) -> [String]? {
        urls?.map { $0.path }
    }

    func testDecodesRuntimeFieldsAndKeepsCompileOnlyJarsOutOfTheRuntimeList() throws {
        let app = try XCTUnwrap(try model().subprojects.first { $0.path == ":app" })
        let main = try XCTUnwrap(app.sourceSets.first { $0.name == "main" })
        XCTAssertEqual(main.compileClasspathJars.map(\.lastPathComponent), ["compileonly.jar"])
        XCTAssertEqual(main.runtimeClasspathJars.map(\.lastPathComponent), ["extra.jar", "guava.jar"])
        XCTAssertEqual(main.runtimeProjectDependencies, [.init(projectPath: ":lib", sourceSetName: "main")])
        XCTAssertEqual(main.outputDirs.count, 2)
    }

    func testMainRuntimeClasspathIsOwnOutputThenProjectOutputsThenJars() throws {
        let classpath = try model().runtimeClasspath(forFile: URL(fileURLWithPath: "/Users/dev/demo/app/src/main/java/app/Main.java"))
        XCTAssertEqual(paths(classpath), [
            "/Users/dev/demo/app/build/classes/java/main",
            "/Users/dev/demo/app/build/resources/main",
            "/Users/dev/demo/lib/build/classes/java/main",
            "/Users/dev/demo/lib/build/resources/main",
            "/Users/dev/demo/app/libs/extra.jar",
            "/Users/dev/.gradle/caches/guava.jar"
        ])
    }

    func testTestSourceSetAlsoGetsItsProjectsMainOutput() throws {
        let classpath = try model().runtimeClasspath(forFile: URL(fileURLWithPath: "/Users/dev/demo/app/src/test/java/app/MainTest.java"))
        XCTAssertEqual(paths(classpath), [
            "/Users/dev/demo/app/build/classes/java/test",
            "/Users/dev/demo/app/build/resources/test",
            "/Users/dev/demo/app/build/classes/java/main",
            "/Users/dev/demo/app/build/resources/main",
            "/Users/dev/demo/lib/build/classes/java/main",
            "/Users/dev/demo/lib/build/resources/main",
            "/Users/dev/demo/app/libs/extra.jar",
            "/Users/dev/.gradle/caches/junit.jar"
        ])
    }

    func testAFileOutsideEverySourceSetHasNoRuntimeClasspath() throws {
        XCTAssertNil(try model().runtimeClasspath(forFile: URL(fileURLWithPath: "/Users/dev/demo/build.gradle")))
    }

    func testAnOlderModelWithoutRuntimeFieldsStillDecodesAndGivesOnlyOutputs() throws {
        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("single-module"))
        let file = URL(string: "file:///Users/dev/single-module/src/main/java/Main.java")!
        XCTAssertEqual(model.runtimeClasspath(forFile: file), [])
    }

    func testTheScriptResolvesBothClasspathsAndRecordsOutputs() {
        let script = GradleProjectModelScript.source
        XCTAssertTrue(script.contains("runtimeClasspathConfigurationName"))
        XCTAssertTrue(script.contains("runtimeClasspathJars"))
        XCTAssertTrue(script.contains("runtimeProjectDependencies"))
        XCTAssertTrue(script.contains("ss.output.classesDirs"))
        XCTAssertEqual(GradleProjectModelScript.formatVersion, 5)
    }
}
