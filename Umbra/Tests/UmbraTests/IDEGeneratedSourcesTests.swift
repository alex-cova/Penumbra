import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

/// F23: annotation-processor output that changes without Umbra running the build (a terminal, another
/// tool, `clean`) has to reach the index. A fake `gradlew` serves a model that declares a generated
/// directory; the files are written and removed behind Umbra's back and the project watcher, the
/// Java support and the index are the real ones.
@MainActor
final class IDEGeneratedSourcesTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var generated: URL!
    private var harness: GradleHarness!
    private var savedAutoSync = true

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("generated-sources-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project", isDirectory: true)
        generated = project.appendingPathComponent("build/generated/sources/annotationProcessor/java/main", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src/main/java"), withIntermediateDirectories: true)
        try "class App {}".write(to: project.appendingPathComponent("src/main/java/App.java"), atomically: true, encoding: .utf8)
        harness = GradleHarness(base: base)
        harness.forwardsFilesToJava = true
        savedAutoSync = IDEPreferences.shared.javaGradleAutoSync
        IDEPreferences.shared.javaGradleAutoSync = true
    }

    override func tearDown() async throws {
        harness.teardown()
        harness = nil
        IDEPreferences.shared.javaGradleAutoSync = savedAutoSync
        try? FileManager.default.removeItem(at: base)
    }

    /// A Gradle project (a fake `gradlew` that serves `model.json`) whose main source set declares
    /// the generated directory, which does not exist yet.
    private func makeProject() throws {
        try "rootProject.name = 'demo'".write(to: project.appendingPathComponent("settings.gradle"), atomically: true, encoding: .utf8)
        try "plugins { id 'java' }".write(to: project.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)
        let set = JavaGradleProjectModel.SourceSet(
            name: "main", sourceDirs: [project.appendingPathComponent("src/main/java")], generatedSourceDirs: [generated]
        )
        let model = JavaGradleProjectModel(
            formatVersion: 5, gradleVersion: "9.0",
            subprojects: [.init(path: ":", directory: project, sourceSets: [set],
                                tasks: [.init(path: ":build", name: "build", group: "build")])]
        )
        try JSONEncoder().encode(model).write(to: project.appendingPathComponent("model.json"))
        let script = """
        #!/bin/sh
        here="$(dirname "$0")"
        out=""
        for a in "$@"; do case "$a" in -PumbraModelOutput=*) out="${a#-PumbraModelOutput=}";; esac; done
        if [ -n "$out" ]; then cp "$here/model.json" "$out"; echo "> Task :umbraProjectModel"; exit 0; fi
        echo "> Task $*"
        exit 0
        """
        let wrapper = project.appendingPathComponent("gradlew")
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = generated.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Polls an async condition; the index is an actor, so the synchronous `eventually` does not fit.
    private func eventually(
        _ message: String, seconds: Double = 25, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail(message, file: file, line: line)
    }

    private func isIndexed(_ name: String) async -> Bool {
        await harness.javaIndex.classStub(qualifiedName: name) != nil
    }

    func testGeneratedSourcesFollowABuildThatUmbraDidNotRun() async throws {
        try makeProject()
        harness.requestTrust = { _ in true }
        harness.setRoot(project)
        await eventually("the project should sync and index its sources") {
            let synced = self.harness.state == .synced(subprojects: 1, jars: 0)
            let indexed = await self.isIndexed("App")
            return synced && indexed
        }
        let isIndexedBefore = await isIndexed("p.Foo_Impl")
        XCTAssertFalse(isIndexedBefore)

        // First build, from a terminal: the directory the model declared appears and fills.
        try write("p/Foo_Impl.java", "package p; public class Foo_Impl {}")
        await eventually("a generated class that appears after the sync should be indexed") { await self.isIndexed("p.Foo_Impl") }

        // The processor reruns and rewrites the file in place: nothing about the root changes but
        // the file below it.
        try write("p/Foo_Impl.java", "package p; public class Foo_Impl {} class Extra {}")
        await eventually("a generated file rewritten in place should be re-read") { await self.isIndexed("p.Extra") }

        // `gradle clean`.
        try FileManager.default.removeItem(at: project.appendingPathComponent("build"))
        await eventually("generated classes should leave the index when the directory is cleaned") {
            let gone = await !self.isIndexed("p.Foo_Impl")
            let alsoGone = await !self.isIndexed("p.Extra")
            return gone && alsoGone
        }
        // The project's own sources were never affected.
        let appStillThere = await isIndexed("App")
        XCTAssertTrue(appStillThere)
    }
}
