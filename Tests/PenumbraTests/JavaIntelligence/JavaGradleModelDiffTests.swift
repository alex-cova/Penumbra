import XCTest
@testable import JavaIntelligence

final class JavaGradleModelDiffTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private func model(
        level: Int? = 17,
        mainJars: [String] = [],
        runtimeJars: [String] = [],
        generated: [String] = [],
        extraSets: [JavaGradleProjectModel.SourceSet] = [],
        tasks: [JavaGradleProjectModel.GradleTask] = []
    ) -> JavaGradleProjectModel {
        let main = JavaGradleProjectModel.SourceSet(
            name: "main",
            sourceDirs: [url("/p/app/src/main/java")],
            compileClasspathJars: mainJars.map(url),
            runtimeClasspathJars: runtimeJars.map(url),
            generatedSourceDirs: generated.map(url)
        )
        return JavaGradleProjectModel(formatVersion: 5, gradleVersion: "9", subprojects: [
            .init(path: ":app", directory: url("/p/app"), languageLevel: level, sourceSets: [main] + extraSets, tasks: tasks)
        ])
    }

    func testNilOldIsInitialFullApply() {
        let result = JavaGradleModelDiff.diff(from: nil, to: model())
        XCTAssertTrue(result.isInitial)
        XCTAssertTrue(result.requiresFullApply)
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.addedSourceSets, [":app:main"])
    }

    func testIdenticalModelsAreEmpty() {
        let result = JavaGradleModelDiff.diff(from: model(mainJars: ["/j/a.jar"]), to: model(mainJars: ["/j/a.jar"]))
        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(result.requiresFullApply)
        XCTAssertFalse(result.classpathChanged)
        XCTAssertFalse(result.sourceRootsChanged)
    }

    func testAddedAndRemovedSourceSet() {
        let test = JavaGradleProjectModel.SourceSet(name: "test", sourceDirs: [url("/p/app/src/test/java")])
        let added = JavaGradleModelDiff.diff(from: model(), to: model(extraSets: [test]))
        XCTAssertEqual(added.addedSourceSets, [":app:test"])
        XCTAssertTrue(added.removedSourceSets.isEmpty)
        XCTAssertTrue(added.sourceRootsChanged)
        XCTAssertTrue(added.classpathChanged)

        let removed = JavaGradleModelDiff.diff(from: model(extraSets: [test]), to: model())
        XCTAssertEqual(removed.removedSourceSets, [":app:test"])
        XCTAssertTrue(removed.sourceRootsChanged)
    }

    func testJarDelta() throws {
        let result = JavaGradleModelDiff.diff(
            from: model(mainJars: ["/j/a.jar", "/j/b.jar"], runtimeJars: ["/j/r.jar"]),
            to: model(mainJars: ["/j/b.jar", "/j/c.jar"], runtimeJars: ["/j/r.jar", "/j/r2.jar"])
        )
        let change = try XCTUnwrap(result.changedSourceSets.first)
        XCTAssertEqual(change.key, ":app:main")
        XCTAssertEqual(change.addedCompileJars, [url("/j/c.jar")])
        XCTAssertEqual(change.removedCompileJars, [url("/j/a.jar")])
        XCTAssertEqual(change.addedRuntimeJars, [url("/j/r2.jar")])
        XCTAssertTrue(change.removedRuntimeJars.isEmpty)
        XCTAssertTrue(result.classpathChanged)
        XCTAssertFalse(result.sourceRootsChanged)
        XCTAssertFalse(result.requiresFullApply)
    }

    func testGeneratedDirsChangeSourceRootsNotClasspath() throws {
        let result = JavaGradleModelDiff.diff(from: model(), to: model(generated: ["/p/app/build/generated/main"]))
        let change = try XCTUnwrap(result.changedSourceSets.first)
        XCTAssertEqual(change.addedGeneratedDirs, [url("/p/app/build/generated/main")])
        XCTAssertTrue(result.sourceRootsChanged)
        XCTAssertFalse(result.classpathChanged)
    }

    func testLanguageLevelChangeRequiresFullApply() {
        let result = JavaGradleModelDiff.diff(from: model(level: 17), to: model(level: 21))
        XCTAssertTrue(result.languageLevelChanged)
        XCTAssertTrue(result.requiresFullApply)
    }

    func testTaskOnlyChangeIsNeitherEmptyNorClasspath() {
        let task = JavaGradleProjectModel.GradleTask(path: ":app:run", name: "run", group: "application")
        let result = JavaGradleModelDiff.diff(from: model(), to: model(tasks: [task]))
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.otherChanged)
        XCTAssertFalse(result.classpathChanged)
        XCTAssertFalse(result.sourceRootsChanged)
    }

    func testPlanIndexesOnlyAddedTargetsAndDropsRemoved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).standardizedFileURL
        defer { try? FileManager.default.removeItem(at: dir) }
        let srcA = dir.appendingPathComponent("a"), srcB = dir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: srcA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: srcB, withIntermediateDirectories: true)
        let jar1 = dir.appendingPathComponent("one.jar"), jar2 = dir.appendingPathComponent("two.jar")
        let paths = JavaIndexPaths(root: dir.appendingPathComponent("cache"))

        func build(_ dirs: [URL], _ jars: [URL]) -> JavaGradleProjectModel {
            JavaGradleProjectModel(formatVersion: 5, gradleVersion: "9", subprojects: [
                .init(path: ":", directory: dir, languageLevel: 17, sourceSets: [
                    .init(name: "main", sourceDirs: dirs, compileClasspathJars: jars)
                ])
            ])
        }
        let first = JavaGradleModelDiff.plan(for: build([srcA], [jar1]), paths: paths, loadedShardPaths: [], loadedNameRoots: [])
        XCTAssertEqual(first.addedSourceTargets.count, 1)
        XCTAssertEqual(first.addedJarTargets.count, 1)

        let loaded = Set((first.sourceTargets + first.jarTargets).map(\.shardURL.path))
        let second = JavaGradleModelDiff.plan(
            for: build([srcA, srcB], [jar2]),
            paths: paths,
            loadedShardPaths: loaded,
            loadedNameRoots: Set(first.nameRoots.map(\.path))
        )
        XCTAssertEqual(second.addedSourceTargets.map(\.shardURL), [paths.projectSourcesShard(for: srcB)])
        XCTAssertEqual(second.addedJarTargets.map(\.shardURL), [paths.jarShard(jar2)])
        XCTAssertEqual(second.removedShardPaths, [paths.jarShard(jar1).path])
        XCTAssertEqual(second.addedNameRoots.map(\.path), [srcB.path])
        XCTAssertTrue(second.removedNameRoots.isEmpty)
    }
}
