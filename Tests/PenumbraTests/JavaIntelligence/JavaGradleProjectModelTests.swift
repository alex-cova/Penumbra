import XCTest
@testable import JavaIntelligence

final class JavaGradleProjectModelTests: XCTestCase {
    // MARK: - Fixture decoding

    func testDecodesSingleModuleFixture() throws {
        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("single-module"))
        XCTAssertEqual(model.formatVersion, 3)
        XCTAssertEqual(model.gradleVersion, "9.2.1")
        XCTAssertTrue(model.unresolved.isEmpty)
        XCTAssertEqual(model.subprojects.count, 1)

        let root = try XCTUnwrap(model.subprojects.first)
        XCTAssertEqual(root.path, ":")
        XCTAssertEqual(root.languageLevel, 21)
        XCTAssertEqual(root.tasks.map(\.path), [":build", ":test", ":run"])
        XCTAssertEqual(model.taskGroups.map(\.name), ["build", "verification", "application"])
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
        XCTAssertEqual(app.tasks.map(\.path), [":app:build", ":app:test", ":app:run"])

        let libCore = try XCTUnwrap(model.subprojects.first { $0.path == ":lib:core" })
        XCTAssertEqual(libCore.languageLevel, 21)

        let appMain = try XCTUnwrap(app.sourceSets.first { $0.name == "main" })
        XCTAssertEqual(appMain.projectDependencies, [.init(projectPath: ":lib:core", sourceSetName: "main")])
        XCTAssertEqual(app.testClasspathJars.count, 2)
        XCTAssertEqual(app.compileClasspathJars.count, 1)
    }

    func testSourceSetContainingFilePicksTheLongestDirectoryPrefix() {
        let root = URL(fileURLWithPath: "/proj")
        let mainDir = URL(fileURLWithPath: "/proj/src/main/java")
        let testDir = URL(fileURLWithPath: "/proj/src/test/java")
        let model = JavaGradleProjectModel(
            formatVersion: 2,
            gradleVersion: "9.0",
            subprojects: [
                .init(path: ":", directory: root, sourceDirs: [mainDir], testSourceDirs: [testDir])
            ]
        )
        let testFile = URL(fileURLWithPath: "/proj/src/test/java/com/example/AppTest.java")
        let match = model.sourceSet(containing: testFile)
        XCTAssertEqual(match?.sourceSet.name, "test")
        XCTAssertNil(model.sourceSet(containing: URL(fileURLWithPath: "/proj/README.md")))
    }

    func testVisibleShardPathsHideTestOnlyJarsFromMain() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainDir = root.appendingPathComponent("src/main/java", isDirectory: true)
        let testDir = root.appendingPathComponent("src/test/java", isDirectory: true)
        try FileManager.default.createDirectory(at: mainDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        let guava = URL(fileURLWithPath: "/caches/guava.jar")
        let junit = URL(fileURLWithPath: "/caches/junit.jar")
        let model = JavaGradleProjectModel(
            formatVersion: 2,
            gradleVersion: "9.0",
            subprojects: [
                .init(
                    path: ":",
                    directory: root,
                    sourceSets: [
                        .init(name: "main", sourceDirs: [mainDir], compileClasspathJars: [guava]),
                        .init(
                            name: "test",
                            sourceDirs: [testDir],
                            compileClasspathJars: [guava, junit],
                            projectDependencies: [.init(projectPath: ":", sourceSetName: "main")]
                        )
                    ]
                )
            ]
        )
        let paths = JavaIndexPaths(root: root.appendingPathComponent("index-cache"))
        let mainScope = try XCTUnwrap(model.visibleShardPaths(forFile: mainDir.appendingPathComponent("App.java"), paths: paths))
        let testScope = try XCTUnwrap(model.visibleShardPaths(forFile: testDir.appendingPathComponent("AppTest.java"), paths: paths))
        XCTAssertTrue(mainScope.contains(paths.jarShard(guava).path))
        XCTAssertFalse(mainScope.contains(paths.jarShard(junit).path))
        XCTAssertTrue(testScope.contains(paths.jarShard(junit).path))
        XCTAssertTrue(testScope.contains(paths.projectSourcesShard(for: mainDir.standardizedFileURL).path))
        XCTAssertNil(model.visibleShardPaths(forFile: root.appendingPathComponent("README.md"), paths: paths))
    }

    func testClasspathJarsDedupesSharedDependencyAcrossSubprojects() throws {
        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: GradleFixtures.modelData("multi-module"))
        let guavaJars = model.classpathJars.filter { $0.path.contains("guava") }
        XCTAssertEqual(guavaJars.count, 1, "guava is a dependency of both :app and :lib:core -- must be indexed once")
        // gson (lib:core only) + guava (shared) + junit-jupiter (app test only) = 3 unique jars.
        XCTAssertEqual(model.classpathJars.count, 3)
    }

    func testSubprojectTaskGroupsAreScopedAndOrdered() {
        let subproject = JavaGradleProjectModel.Subproject(
            path: ":app",
            directory: URL(fileURLWithPath: "/tmp/app"),
            tasks: [
                .init(path: ":app:test", name: "test", group: "verification"),
                .init(path: ":app:run", name: "run", group: "application"),
                .init(path: ":app:jar", name: "jar", group: "build"),
                .init(path: ":app:assemble", name: "assemble", group: "build")
            ]
        )
        let groups = subproject.taskGroups
        XCTAssertEqual(groups.map(\.name), ["build", "verification", "application"])
        XCTAssertEqual(groups.first?.tasks.map(\.name), ["assemble", "jar"])
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

    // MARK: - Generated sources / annotation processors (format 5)

    private func sourceSetJSON(extra: String) -> Data {
        Data("""
        {"formatVersion": 5, "gradleVersion": "8.5", "unresolved": [], "subprojects": [
          {"path": ":", "directory": "file:///p/", "sourceSets": [
            {"name": "main", "sourceDirs": ["file:///p/src/main/java/"] \(extra)}
          ]}
        ]}
        """.utf8)
    }

    func testDecodesFormat4JSONWithoutGeneratedFields() throws {
        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: sourceSetJSON(extra: ""))
        let set = try XCTUnwrap(model.subprojects.first?.sourceSets.first)
        XCTAssertTrue(set.generatedSourceDirs.isEmpty)
        XCTAssertTrue(set.annotationProcessorJars.isEmpty)
    }

    func testDecodesFormat5GeneratedFields() throws {
        let extra = ", \"generatedSourceDirs\": [\"file:///p/build/gen/\"], \"annotationProcessorJars\": [\"file:///ap/lombok.jar\"]"
        let model = try JSONDecoder().decode(JavaGradleProjectModel.self, from: sourceSetJSON(extra: extra))
        let set = try XCTUnwrap(model.subprojects.first?.sourceSets.first)
        XCTAssertEqual(set.generatedSourceDirs.map(\.path), ["/p/build/gen"])
        XCTAssertEqual(set.annotationProcessorJars.map(\.lastPathComponent), ["lombok.jar"])
    }

    func testGeneratedDirsAreReadOnlyTargetsAndVisible() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainDir = root.appendingPathComponent("src/main/java")
        let genDir = root.appendingPathComponent("build/generated/ap")
        let missingGen = root.appendingPathComponent("build/generated/none")
        try FileManager.default.createDirectory(at: mainDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: genDir, withIntermediateDirectories: true)
        let set = JavaGradleProjectModel.SourceSet(
            name: "main", sourceDirs: [mainDir], generatedSourceDirs: [genDir, missingGen]
        )
        let model = JavaGradleProjectModel(
            formatVersion: 5, gradleVersion: "8.5",
            subprojects: [.init(path: ":", directory: root, sourceSets: [set])]
        )
        let paths = JavaIndexPaths(root: root.appendingPathComponent("index-cache"))

        let targets = model.sourceIndexTargets(paths: paths)
        XCTAssertEqual(targets.count, 2)
        let roots = targets.compactMap { $0.root as? SourceRoot }
        XCTAssertEqual(roots.filter(\.isGenerated).map(\.directory), [genDir.standardizedFileURL])
        XCTAssertEqual(roots.filter { !$0.isGenerated }.count, 1)

        let visible = try XCTUnwrap(model.visibleShardPaths(
            forFile: mainDir.appendingPathComponent("A.java"), paths: paths
        ))
        XCTAssertTrue(visible.contains(paths.projectSourcesShard(for: genDir.standardizedFileURL).path))
        XCTAssertFalse(visible.contains(paths.projectSourcesShard(for: missingGen.standardizedFileURL).path))
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

    func launch(_ command: GradleCommand, timeout: Duration, output: GradleOutputHandler?) async throws -> GradleCommandResult {
        if let outputArg = command.arguments.first(where: { $0.hasPrefix("-PumbraModelOutput=") }) {
            let path = String(outputArg.dropFirst("-PumbraModelOutput=".count))
            try? jsonToWrite.write(to: URL(fileURLWithPath: path))
        }
        return GradleCommandResult(exitCode: exitCode, stdout: "", stderr: stderr)
    }
}

private struct NoOpLauncher: GradleProcessLaunching {
    let exitCode: Int32
    func launch(_ command: GradleCommand, timeout: Duration, output: GradleOutputHandler?) async throws -> GradleCommandResult {
        GradleCommandResult(exitCode: exitCode, stdout: "", stderr: "")
    }
}
