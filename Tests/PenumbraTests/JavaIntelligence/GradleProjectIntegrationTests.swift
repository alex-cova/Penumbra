import XCTest
@testable import JavaIntelligence

/// Opt-in: exercises the real ``GradleProjectModelScript`` against a real Gradle invocation
/// (`GradleProjectModelExtractor` -> `GradleCommandRunner` -> a spawned `gradle`/`gradlew`
/// process), generating a small throwaway multi-module project at test time. Skipped on a machine
/// with no `gradle` on `PATH` or no discoverable JDK, the same posture as `TestJDK.discovered`-
/// gated tests elsewhere in this suite.
final class GradleProjectIntegrationTests: XCTestCase {
    func testMultiModuleProjectModelExtractionAndEndToEndIndexing() async throws {
        guard let jdk = TestJDK.discovered else {
            throw XCTSkip("No JDK found on this machine")
        }
        guard let gradlePath = Self.resolvedGradleOnPath(), !gradlePath.isEmpty else {
            throw XCTSkip("No gradle found on PATH")
        }

        let projectDirectory = try Self.makeMultiModuleProject()
        defer { try? FileManager.default.removeItem(at: projectDirectory) }

        let store = ProjectTrustStore(storeURL: projectDirectory.appendingPathComponent(".umbra-trust.json"))
        store.setTrusted(true, for: projectDirectory)
        let runner = GradleCommandRunner(trustStore: store)
        let extractor = GradleProjectModelExtractor(runner: runner)

        // Gradle's Groovy reads class files of the JVM it runs on, so a Gradle release that is a
        // few months older than the newest JDK fails at "Unsupported class file major version".
        // That says nothing about the extractor: try the installed JDKs newest first.
        var candidates = JDKLocator().discoverAll().map(\.home)
        if candidates.isEmpty { candidates = [jdk.home] }
        var extracted: (JavaGradleProjectModel, GradleCommandResult)?
        for home in candidates {
            do {
                extracted = try await extractor.extract(projectDirectory: projectDirectory, javaHome: home, timeout: .seconds(300))
                break
            } catch GradleProjectModelExtractionError.syncFailed(let failure)
                where failure.stderr.contains("Unsupported class file major version") {
                continue
            }
        }
        guard let (model, result) = extracted else {
            throw XCTSkip("The installed gradle cannot run on any installed JDK (class file version unsupported)")
        }
        XCTAssertEqual(result.exitCode, 0, "gradle sync should succeed: \(result.stderr)")
        XCTAssertEqual(Set(model.subprojects.map(\.path)), [":", ":app", ":lib"])

        let app = try XCTUnwrap(model.subprojects.first { $0.path == ":app" })
        let appMain = try XCTUnwrap(app.sourceSets.first { $0.name == "main" })
        let appTest = try XCTUnwrap(app.sourceSets.first { $0.name == "test" })
        let testTask = try XCTUnwrap(app.testTasks.first { $0.path == ":app:test" }, "format 6 must record :app:test")
        XCTAssertEqual(testTask.sourceSetName, "test")
        XCTAssertTrue(testTask.resultsDir?.path.hasSuffix("app/build/test-results/test") == true, "got \(String(describing: testTask.resultsDir))")
        XCTAssertTrue(
            appMain.sourceDirs.contains { $0.path.hasSuffix("app/src/main/java") },
            "expected :app's src/main/java, got \(appMain.sourceDirs)"
        )
        XCTAssertTrue(
            appMain.compileClasspathJars.contains { $0.path == JavaFixtures.jarURL.path },
            "expected the fixture jar in :app main, got \(appMain.compileClasspathJars)"
        )
        XCTAssertEqual(
            appMain.addModules, ["jdk.incubator.vector", "java.sql"],
            "expected both --add-modules spellings captured, got \(appMain.addModules)"
        )
        XCTAssertFalse(
            appMain.compileClasspathJars.contains { $0.path.hasSuffix("test-only.jar") },
            "testImplementation must not be on the main compile classpath: \(appMain.compileClasspathJars)"
        )
        XCTAssertTrue(
            appTest.compileClasspathJars.contains { $0.path.hasSuffix("test-only.jar") },
            "expected test-only.jar on the test compile classpath, got \(appTest.compileClasspathJars)"
        )
        XCTAssertTrue(
            appMain.projectDependencies.contains { $0.projectPath == ":lib" && $0.sourceSetName == "main" },
            "expected :app main to depend on :lib main, got \(appMain.projectDependencies)"
        )
        XCTAssertFalse(
            appMain.compileClasspathJars.contains { $0.path.contains("/lib/build/") },
            "the inter-project :lib dependency is indexed from its own sources -- it must not also leak in as a jar"
        )
        XCTAssertFalse(
            appTest.compileClasspathJars.contains { $0.path.contains("/lib/build/") },
            "the test classpath must not index :lib's jar either"
        )
        let lib = try XCTUnwrap(model.subprojects.first { $0.path == ":lib" })
        let libMain = try XCTUnwrap(lib.sourceSets.first { $0.name == "main" })
        XCTAssertTrue(
            libMain.addModules.isEmpty,
            "a source set without compilerArgs must decode to no extra modules, got \(libMain.addModules)"
        )
        XCTAssertEqual(
            app.runMainClass, "com.example.App",
            "the application plugin's main class must be captured, got \(String(describing: app.runMainClass))"
        )
        XCTAssertNil(
            lib.runMainClass,
            "a project with no run task must decode to no main class, got \(String(describing: lib.runMainClass))"
        )

        // End-to-end: index the model-driven sources + jars and confirm both a project class and a
        // jar-resolved dependency class are queryable through JavaIndex.
        let paths = JavaIndexPaths(root: projectDirectory.appendingPathComponent("index-cache"))
        let scheduler = JavaIndexScheduler(paths: paths)
        let targets = model.sourceIndexTargets(paths: paths) + model.jarIndexTargets(paths: paths)
        for await _ in await scheduler.index(targets) {}

        var sources: [JavaIndex.Source] = []
        for target in targets {
            guard let reader = try? JavaIndexShardReader(url: target.shardURL) else { continue }
            let precedence = (target.root is JarRoot) ? 2 : 1
            sources.append(.init(precedence: precedence, reader: reader))
        }
        let index = JavaIndex()
        await index.setSources(sources)

        let fixtureStub = await index.classStub(qualifiedName: "com.penumbra.fixture.Fixture")
        XCTAssertNotNil(fixtureStub, "jar-resolved dependency should be queryable through JavaIndex")
        let appStub = await index.classStub(qualifiedName: "com.example.App")
        XCTAssertNotNil(appStub, "project source should be queryable through JavaIndex")
        let libStub = await index.classStub(qualifiedName: "com.example.Lib")
        XCTAssertNotNil(libStub, ":lib's own source should be queryable through JavaIndex")
    }

    // MARK: - Helpers

    private static func resolvedGradleOnPath() -> String? {
        guard let output = try? SystemProcessRunner().run(executable: "/bin/zsh", arguments: ["-lc", "command -v gradle"]) else {
            return nil
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Root (aggregator, no java plugin) + `:lib` (a `java-library` with one class) + `:app`
    /// (depends on `:lib` and on the existing `JavaFixtures.jarURL` fixture, so no network
    /// dependency is ever needed).
    private static func makeMultiModuleProject() throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("umbra-gradle-it-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root.appendingPathComponent("app/src/main/java/com/example"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("lib/src/main/java/com/example"), withIntermediateDirectories: true)

        try "rootProject.name = 'umbra-it'\ninclude 'app', 'lib'\n"
            .write(to: root.appendingPathComponent("settings.gradle"), atomically: true, encoding: .utf8)

        try """
        plugins {
            id 'java-library'
        }
        java {
            sourceCompatibility = JavaVersion.VERSION_17
            targetCompatibility = JavaVersion.VERSION_17
        }
        """.write(to: root.appendingPathComponent("lib/build.gradle"), atomically: true, encoding: .utf8)

        try "package com.example;\npublic class Lib {}\n"
            .write(to: root.appendingPathComponent("lib/src/main/java/com/example/Lib.java"), atomically: true, encoding: .utf8)

        let fixtureJarPath = JavaFixtures.jarURL.path
        let testOnlyJar = root.appendingPathComponent("test-only.jar")
        try fileManager.copyItem(at: JavaFixtures.jarURL, to: testOnlyJar)
        try """
        plugins {
            id 'java'
            id 'application'
        }
        java {
            sourceCompatibility = JavaVersion.VERSION_17
            targetCompatibility = JavaVersion.VERSION_17
        }
        dependencies {
            implementation project(':lib')
            implementation files('\(fixtureJarPath)')
            testImplementation files('\(testOnlyJar.path)')
        }
        application {
            mainClass = 'com.example.App'
        }
        tasks.withType(JavaCompile).configureEach {
            options.compilerArgs.addAll(['--add-modules', 'jdk.incubator.vector', '--add-modules=java.sql'])
        }
        """.write(to: root.appendingPathComponent("app/build.gradle"), atomically: true, encoding: .utf8)

        try "package com.example;\npublic class App {}\n"
            .write(to: root.appendingPathComponent("app/src/main/java/com/example/App.java"), atomically: true, encoding: .utf8)

        return root
    }
}
