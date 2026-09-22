import XCTest
@testable import JavaIntelligence

final class JavaGradleProjectModelTests: XCTestCase {
    // MARK: - Fixture decoding

    func testDecodesSingleModuleFixture() throws {
        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("single-module"))
        XCTAssertEqual(model.formatVersion, 1)
        XCTAssertEqual(model.gradleVersion, "9.2.1")
        XCTAssertTrue(model.unresolved.isEmpty)
        XCTAssertEqual(model.subprojects.count, 1)

        let root = try XCTUnwrap(model.subprojects.first)
        XCTAssertEqual(root.path, ":")
        XCTAssertEqual(root.languageLevel, 21)
        XCTAssertEqual(root.sourceDirs, [URL(string: "file:///Users/dev/single-module/src/main/java/")])
        XCTAssertEqual(root.testSourceDirs, [URL(string: "file:///Users/dev/single-module/src/test/java/")])
        XCTAssertEqual(root.compileClasspathJars.count, 1)
        XCTAssertEqual(root.testClasspathJars.count, 2)
    }

    func testDecodesMultiModuleFixtureWithSubprojectsAndUnresolved() throws {
        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("multi-module"))
        XCTAssertEqual(model.subprojects.map(\.path), [":", ":app", ":lib:core"])
        XCTAssertEqual(model.unresolved, ["Could not resolve com.example:missing-dep:1.0."])

        let root = try XCTUnwrap(model.subprojects.first { $0.path == ":" })
        XCTAssertNil(root.languageLevel, "aggregator root has no java plugin applied")
        XCTAssertTrue(root.sourceDirs.isEmpty)

        let app = try XCTUnwrap(model.subprojects.first { $0.path == ":app" })
        XCTAssertEqual(app.languageLevel, 17)

        let libCore = try XCTUnwrap(model.subprojects.first { $0.path == ":lib:core" })
        XCTAssertEqual(libCore.languageLevel, 21)
    }

    func testClasspathJarsDedupesSharedDependencyAcrossSubprojects() throws {
        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("multi-module"))
        let guavaJars = model.classpathJars.filter { $0.path.contains("guava") }
        XCTAssertEqual(guavaJars.count, 1, "guava is a dependency of both :app and :lib:core -- must be indexed once")
        // gson (lib:core only) + guava (shared) + junit-jupiter (app test only) = 3 unique jars.
        XCTAssertEqual(model.classpathJars.count, 3)
    }

    func testMaxLanguageLevelPicksHighestAcrossSubprojects() throws {
        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("multi-module"))
        XCTAssertEqual(model.maxLanguageLevel, 21)
    }

    func testMaxLanguageLevelIsNilWhenNoSubprojectHasOne() {
        let model = JavaGradleProjectModel(
            formatVersion: 1, gradleVersion: "9.0",
            subprojects: [.init(path: ":", directory: URL(fileURLWithPath: "/tmp"))]
        )
        XCTAssertNil(model.maxLanguageLevel)
    }

    // MARK: - existingSourceDirectories: real filesystem, missing + nested dirs

    func testExistingSourceDirectoriesDropsMissingAndNestedDirectories() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let mainDir = root.appendingPathComponent("src/main/java", isDirectory: true)
        let nestedGenDir = mainDir.appendingPathComponent("generated", isDirectory: true)
        let testDir = root.appendingPathComponent("src/test/java", isDirectory: true)
        let missingDir = root.appendingPathComponent("src/missing/java", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedGenDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        // missingDir intentionally not created.

        let model = JavaGradleProjectModel(
            formatVersion: 1,
            gradleVersion: "9.0",
            subprojects: [
                .init(
                    path: ":",
                    directory: root,
                    sourceDirs: [mainDir, nestedGenDir, missingDir],
                    testSourceDirs: [testDir]
                )
            ]
        )

        let existing = Set(model.existingSourceDirectories.map(\.path))
        XCTAssertTrue(existing.contains(mainDir.standardizedFileURL.path))
        XCTAssertTrue(existing.contains(testDir.standardizedFileURL.path))
        XCTAssertFalse(existing.contains(nestedGenDir.standardizedFileURL.path), "nested under mainDir -- should be dropped")
        XCTAssertFalse(existing.contains(missingDir.standardizedFileURL.path), "doesn't exist on disk")
        XCTAssertEqual(existing.count, 2)
    }

    // MARK: - Index targets

    func testSourceAndJarIndexTargetsUseJavaIndexPathsShardURLs() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainDir = root.appendingPathComponent("src/main/java", isDirectory: true)
        try FileManager.default.createDirectory(at: mainDir, withIntermediateDirectories: true)

        let model = JavaGradleProjectModel(
            formatVersion: 1,
            gradleVersion: "9.0",
            subprojects: [
                .init(
                    path: ":",
                    directory: root,
                    sourceDirs: [mainDir],
                    compileClasspathJars: [JavaFixtures.jarURL]
                )
            ]
        )
        let paths = JavaIndexPaths(root: root.appendingPathComponent("index-cache"))

        let sourceTargets = model.sourceIndexTargets(paths: paths)
        XCTAssertEqual(sourceTargets.count, 1)
        XCTAssertEqual(sourceTargets[0].shardURL, paths.projectSourcesShard(for: mainDir.standardizedFileURL))
        XCTAssertTrue(sourceTargets[0].root is SourceRoot)

        let jarTargets = model.jarIndexTargets(paths: paths)
        XCTAssertEqual(jarTargets.count, 1)
        XCTAssertEqual(jarTargets[0].shardURL, paths.jarShard(JavaFixtures.jarURL))
        XCTAssertTrue(jarTargets[0].root is JarRoot)
    }

    // MARK: - End-to-end wiring (no Gradle needed): a model-driven JarRoot is queryable via JavaIndex

    func testModelDrivenJarRootIsQueryableThroughJavaIndex() async throws {
        let workDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let model = JavaGradleProjectModel(
            formatVersion: 1,
            gradleVersion: "9.0",
            subprojects: [
                .init(path: ":", directory: workDir, compileClasspathJars: [JavaFixtures.jarURL])
            ]
        )
        let paths = JavaIndexPaths(root: workDir.appendingPathComponent("index-cache"))
        let scheduler = JavaIndexScheduler(paths: paths)
        for await _ in await scheduler.index(model.jarIndexTargets(paths: paths)) {}

        let jarShardURL = paths.jarShard(JavaFixtures.jarURL)
        let reader = try JavaIndexShardReader(url: jarShardURL)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 2, reader: reader)])

        let stub = await index.classStub(qualifiedName: "com.penumbra.fixture.Fixture")
        XCTAssertNotNil(stub, "a model-driven JarRoot should index and resolve through JavaIndex")
    }

    // MARK: - isGradleProject

    func testIsGradleProjectDetectsSettingsFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("settings.gradle"))
        XCTAssertTrue(GradleProjectModelExtractor.isGradleProject(dir))
    }

    func testIsGradleProjectFalseForPlainFolder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(GradleProjectModelExtractor.isGradleProject(dir))
    }

    // MARK: - Extractor, with a fake launcher (no real Gradle)

    func testExtractorDecodesModelWrittenByLauncher() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GradleTrustStore(storeURL: dir.appendingPathComponent("trust.json"))
        store.setTrusted(true, for: dir)
        let launcher = FixtureWritingLauncher(jsonToWrite: GradleFixtures.modelData("single-module"), exitCode: 0)
        let runner = GradleCommandRunner(
            trustStore: store, launcher: launcher,
            resolver: GradleExecutableResolver(processRunner: FakeProcessRunner(output: "/fake/gradle"))
        )
        let extractor = GradleProjectModelExtractor(runner: runner)

        let (model, result) = try await extractor.extract(projectDirectory: dir, javaHome: nil)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(model.subprojects.first?.path, ":")
    }

    func testExtractorThrowsSyncFailedOnNonZeroExit() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GradleTrustStore(storeURL: dir.appendingPathComponent("trust.json"))
        store.setTrusted(true, for: dir)
        let launcher = FixtureWritingLauncher(jsonToWrite: Data(), exitCode: 1, stderr: "build script error")
        let runner = GradleCommandRunner(
            trustStore: store, launcher: launcher,
            resolver: GradleExecutableResolver(processRunner: FakeProcessRunner(output: "/fake/gradle"))
        )
        let extractor = GradleProjectModelExtractor(runner: runner)

        do {
            _ = try await extractor.extract(projectDirectory: dir, javaHome: nil)
            XCTFail("expected syncFailed")
        } catch GradleProjectModelExtractionError.syncFailed(let result) {
            XCTAssertEqual(result.stderr, "build script error")
        }
    }

    func testExtractorThrowsMissingOutputWhenNoFileWritten() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GradleTrustStore(storeURL: dir.appendingPathComponent("trust.json"))
        store.setTrusted(true, for: dir)
        let launcher = NoOpLauncher(exitCode: 0)
        let runner = GradleCommandRunner(
            trustStore: store, launcher: launcher,
            resolver: GradleExecutableResolver(processRunner: FakeProcessRunner(output: "/fake/gradle"))
        )
        let extractor = GradleProjectModelExtractor(runner: runner)

        do {
            _ = try await extractor.extract(projectDirectory: dir, javaHome: nil)
            XCTFail("expected missingOutput")
        } catch GradleProjectModelExtractionError.missingOutput {
            // expected
        }
    }

    func testExtractorThrowsDecodingFailedOnGarbageOutput() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GradleTrustStore(storeURL: dir.appendingPathComponent("trust.json"))
        store.setTrusted(true, for: dir)
        let launcher = FixtureWritingLauncher(jsonToWrite: Data("not json".utf8), exitCode: 0)
        let runner = GradleCommandRunner(
            trustStore: store, launcher: launcher,
            resolver: GradleExecutableResolver(processRunner: FakeProcessRunner(output: "/fake/gradle"))
        )
        let extractor = GradleProjectModelExtractor(runner: runner)

        do {
            _ = try await extractor.extract(projectDirectory: dir, javaHome: nil)
            XCTFail("expected decodingFailed")
        } catch GradleProjectModelExtractionError.decodingFailed {
            // expected
        }
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

private struct FakeProcessRunner: ProcessRunning {
    let output: String
    func run(executable: String, arguments: [String], currentDirectory: URL?, environment: [String: String]?) throws -> String {
        output
    }
}

/// A fake ``GradleProcessLaunching`` that writes fixed JSON bytes to whatever path was passed via
/// `-PumbraModelOutput=`, simulating a successful (or failed) `umbraProjectModel` run without
/// spawning a real Gradle process.
private struct FixtureWritingLauncher: GradleProcessLaunching {
    let jsonToWrite: Data
    let exitCode: Int32
    var stderr: String = ""

    init(jsonToWrite: Data, exitCode: Int32, stderr: String = "") {
        self.jsonToWrite = jsonToWrite
        self.exitCode = exitCode
        self.stderr = stderr
    }

    func launch(_ command: GradleCommand, timeout: Duration) async throws -> GradleCommandResult {
        if let outputArg = command.arguments.first(where: { $0.hasPrefix("-PumbraModelOutput=") }) {
            let path = String(outputArg.dropFirst("-PumbraModelOutput=".count))
            try? jsonToWrite.write(to: URL(fileURLWithPath: path))
        }
        return GradleCommandResult(exitCode: exitCode, stdout: "", stderr: stderr)
    }
}

private struct NoOpLauncher: GradleProcessLaunching {
    let exitCode: Int32
    func launch(_ command: GradleCommand, timeout: Duration) async throws -> GradleCommandResult {
        GradleCommandResult(exitCode: exitCode, stdout: "", stderr: "")
    }
}
