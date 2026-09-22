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

        let store = GradleTrustStore(storeURL: projectDirectory.appendingPathComponent(".umbra-trust.json"))
        store.setTrusted(true, for: projectDirectory)
        let runner = GradleCommandRunner(trustStore: store)
        let extractor = GradleProjectModelExtractor(runner: runner)

        let (model, result) = try await extractor.extract(
            projectDirectory: projectDirectory,
            javaHome: jdk.home,
            timeout: .seconds(300)
        )
        XCTAssertEqual(result.exitCode, 0, "gradle sync should succeed: \(result.stderr)")
        XCTAssertEqual(Set(model.subprojects.map(\.path)), [":", ":app", ":lib"])

        let app = try XCTUnwrap(model.subprojects.first { $0.path == ":app" })
        XCTAssertTrue(
            app.sourceDirs.contains { $0.path.hasSuffix("app/src/main/java") },
            "expected :app's src/main/java, got \(app.sourceDirs)"
        )
        XCTAssertTrue(
            app.compileClasspathJars.contains { $0.path == JavaFixtures.jarURL.path },
            "expected the fixture jar in :app's compile classpath, got \(app.compileClasspathJars)"
        )
        XCTAssertFalse(
            app.compileClasspathJars.contains { $0.path.contains("/lib/build/") },
            "the inter-project :lib dependency is indexed from its own sourceDirs -- it must not also leak in as a jar"
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
        try """
        plugins {
            id 'java'
        }
        java {
            sourceCompatibility = JavaVersion.VERSION_17
            targetCompatibility = JavaVersion.VERSION_17
        }
        dependencies {
            implementation project(':lib')
            implementation files('\(fixtureJarPath)')
        }
        """.write(to: root.appendingPathComponent("app/build.gradle"), atomically: true, encoding: .utf8)

        try "package com.example;\npublic class App {}\n"
            .write(to: root.appendingPathComponent("app/src/main/java/com/example/App.java"), atomically: true, encoding: .utf8)

        return root
    }
}
