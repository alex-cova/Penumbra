import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

/// How a Gradle project behaves in a window: detection, the trust prompt, the sync state, the console,
/// task runs, cancelling and the build-file banner. A fake `gradlew` in the project stands in for
/// Gradle, so nothing here needs a Gradle installation, and every store lives in a temporary folder.
///
/// The tests talk to the project through `GradleHarness` only. They were written against
/// `IDEJavaSupport` before the Gradle code moved into `IDEGradleProjectSystem` (plan, phase 5), and
/// the same assertions run against the new type: only the harness changed.
@MainActor
final class IDEGradleProjectSystemTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var harness: GradleHarness!
    private var savedAutoSync = true

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("gradle-system-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src/main/java"), withIntermediateDirectories: true)
        try "class App {}".write(to: project.appendingPathComponent("src/main/java/App.java"), atomically: true, encoding: .utf8)
        harness = GradleHarness(base: base)
        savedAutoSync = IDEPreferences.shared.javaGradleAutoSync
        IDEPreferences.shared.javaGradleAutoSync = true
    }

    override func tearDown() async throws {
        harness.teardown()
        harness = nil
        IDEPreferences.shared.javaGradleAutoSync = savedAutoSync
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Fixtures

    /// A Gradle project whose `gradlew` writes the model it finds beside it, appends every call to
    /// `invocations.log`, and behaves as the flag files beside it say: `fail-sync`, `fail-task`
    /// (exit 3) and `slow` (sleeps).
    @discardableResult
    private func makeGradleProject(subprojects: Int = 1) throws -> URL {
        try "rootProject.name = 'demo'".write(to: project.appendingPathComponent("settings.gradle"), atomically: true, encoding: .utf8)
        try "plugins { id 'java' }".write(to: project.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)
        var modules: [JavaGradleProjectModel.Subproject] = [
            .init(
                path: ":", directory: project,
                sourceSets: [.init(name: "main", sourceDirs: [project.appendingPathComponent("src/main/java")])],
                tasks: [.init(path: ":build", name: "build", group: "build"), .init(path: ":run", name: "run", group: "application")]
            )
        ]
        for index in 1..<max(subprojects, 1) {
            modules.append(.init(path: ":m\(index)", directory: project.appendingPathComponent("m\(index)")))
        }
        let model = JavaGradleProjectModel(formatVersion: 5, gradleVersion: "9.0", subprojects: modules)
        try JSONEncoder().encode(model).write(to: project.appendingPathComponent("model.json"))
        let script = """
        #!/bin/sh
        here="$(dirname "$0")"
        echo "$@" >> "$here/invocations.log"
        out=""
        for a in "$@"; do case "$a" in -PumbraModelOutput=*) out="${a#-PumbraModelOutput=}";; esac; done
        [ -f "$here/slow" ] && exec sleep 30
        if [ -n "$out" ]; then
          if [ -f "$here/fail-sync" ]; then echo "boom" >&2; exit 1; fi
          cp "$here/model.json" "$out"
          echo "> Task :umbraProjectModel"
          exit 0
        fi
        echo "> Task $*"
        [ -f "$here/fail-task" ] && exit 3
        exit 0
        """
        let wrapper = project.appendingPathComponent("gradlew")
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return project
    }

    private func flag(_ name: String) throws {
        try "".write(to: project.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private var invocations: [String] {
        (try? String(contentsOf: project.appendingPathComponent("invocations.log"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
    }

    private func eventually(
        _ message: @autoclosure () -> String = "", seconds: Double = 20,
        file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), message(), file: file, line: line)
    }

    // MARK: - Detection

    func testAFolderWithoutBuildFilesIsNotAGradleProject() async throws {
        harness.setRoot(project)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(harness.state, .notGradle)
        XCTAssertFalse(harness.isGradleProject)
        XCTAssertFalse(harness.isBusy)
        XCTAssertNil(harness.modelModuleCount)
        XCTAssertTrue(invocations.isEmpty)

        let outcome = await harness.runTasks(["build"])
        XCTAssertEqual(outcome, .notStarted("This project is not a Gradle project."))
    }

    func testNoProjectIsNotAGradleProject() {
        harness.setRoot(nil)
        XCTAssertEqual(harness.state, .notGradle)
        XCTAssertFalse(harness.isGradleProject)
    }

    func testABuildFileMakesAGradleProjectBeforeAnySync() throws {
        try makeGradleProject()
        harness.requestTrust = nil
        harness.setRoot(project)
        XCTAssertTrue(harness.isGradleProject)
        XCTAssertEqual(harness.state, .awaitingTrust)
    }

    // MARK: - Trust

    func testWithoutAPromptAnUndecidedProjectWaitsForTrust() async throws {
        try makeGradleProject()
        harness.requestTrust = nil
        harness.setRoot(project)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(harness.state, .awaitingTrust)
        XCTAssertTrue(invocations.isEmpty, "Build scripts run arbitrary code: nothing starts before the user agrees")
    }

    func testGrantingTrustSyncsTheProject() async throws {
        try makeGradleProject(subprojects: 2)
        harness.requestTrust = { _ in true }
        harness.setRoot(project)

        await eventually("state: \(harness.state)") { harness.state == .synced(subprojects: 2, jars: 0) }
        XCTAssertEqual(harness.modelModuleCount, 2)
        XCTAssertTrue(harness.isTrusted(project))
        XCTAssertEqual(harness.asked, [project.path])
        XCTAssertEqual(harness.outcomes, [.synced(subprojects: 2, jars: 0)])
        XCTAssertEqual(harness.failures, 0)
        XCTAssertFalse(harness.isBusy)

        let text = harness.consoleText
        XCTAssertTrue(text.contains("Project: \(project.path)"), text)
        XCTAssertTrue(text.contains("> Task :umbraProjectModel"), text)
        XCTAssertTrue(text.contains("Sync finished"), text)
        XCTAssertTrue(invocations.first?.contains("--init-script") ?? false)
        XCTAssertTrue(invocations.first?.contains(":umbraProjectModel") ?? false)
    }

    func testDecliningTrustLeavesTheProjectUntrustedAndNothingRuns() async throws {
        try makeGradleProject()
        harness.requestTrust = { _ in false }
        harness.setRoot(project)

        await eventually("state: \(harness.state)") { harness.state == .untrusted }
        XCTAssertFalse(harness.isTrusted(project))
        XCTAssertTrue(invocations.isEmpty)

        // Opening it again does not nag, but Reload asks even though the answer was no.
        harness.setRoot(project)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.asked.count, 1, "A declined project is not asked again on open")
        harness.requestTrust = { _ in true }
        harness.reload()
        await eventually("state: \(harness.state)") { harness.state == .synced(subprojects: 1, jars: 0) }
        XCTAssertTrue(harness.isTrusted(project))
    }

    func testAutoSyncOffWaitsForReload() async throws {
        try makeGradleProject()
        IDEPreferences.shared.javaGradleAutoSync = false
        harness.requestTrust = { _ in true }
        harness.setRoot(project)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(harness.state, .awaitingTrust)
        XCTAssertTrue(invocations.isEmpty)
        harness.reload()
        await eventually("state: \(harness.state)") { harness.state == .synced(subprojects: 1, jars: 0) }
    }

    // MARK: - Sync

    func testAFailedSyncIsReportedOnceWithItsSummary() async throws {
        try makeGradleProject()
        try flag("fail-sync")
        harness.requestTrust = { _ in true }
        harness.setRoot(project)

        await eventually("state: \(harness.state)") { harness.state == .failed(summary: "Gradle exited 1") }
        XCTAssertNil(harness.modelModuleCount)
        XCTAssertEqual(harness.failures, 1)
        XCTAssertEqual(harness.outcomes, [.failed(summary: "Gradle exited 1")])
        XCTAssertTrue(harness.consoleText.contains("Gradle exited 1"))
        XCTAssertFalse(harness.isBusy)
    }

    func testCancellingASyncEndsItAsCancelled() async throws {
        try makeGradleProject()
        try flag("slow")
        harness.requestTrust = { _ in true }
        harness.setRoot(project)

        await eventually("state: \(harness.state)") { harness.state == .syncing }
        XCTAssertTrue(harness.isBusy)
        harness.cancelSync()

        XCTAssertEqual(harness.state, .failed(summary: "Gradle sync was cancelled"))
        XCTAssertEqual(harness.outcomes, [.cancelled])
        XCTAssertFalse(harness.isBusy)
        XCTAssertTrue(harness.consoleText.contains("Sync cancelled"))
        XCTAssertEqual(harness.failures, 0, "A cancel is not a failure to show the console for")

        // Cancelling when nothing syncs does nothing.
        harness.cancelSync()
        XCTAssertEqual(harness.outcomes, [.cancelled])
    }

    func testReloadSyncsAgainAndKeepsTheModel() async throws {
        try makeGradleProject()
        harness.requestTrust = { _ in true }
        harness.setRoot(project)
        await eventually { harness.state == .synced(subprojects: 1, jars: 0) }

        harness.reload()
        await eventually("outcomes: \(harness.outcomes)") { harness.outcomes.count == 2 }
        XCTAssertEqual(harness.state, .synced(subprojects: 1, jars: 0))
        XCTAssertEqual(invocations.filter { $0.contains(":umbraProjectModel") }.count, 2)
    }

    func testAnotherWindowOpeningTheSameProjectStartsFromTheCachedModel() async throws {
        try makeGradleProject()
        harness.requestTrust = { _ in true }
        harness.setRoot(project)
        await eventually { harness.state == .synced(subprojects: 1, jars: 0) }
        let firstCount = harness.outcomes.count

        let second = GradleHarness(base: base, reusingStoresOf: harness)
        defer { second.teardown() }
        second.setRoot(project)
        // The cached model is applied straight away; the refresh that follows is silent.
        await eventually("state: \(second.state)") { second.state == .synced(subprojects: 1, jars: 0) }
        await eventually(second.consoleText) { second.consoleText.contains("Background refresh") }
        XCTAssertTrue(second.outcomes.isEmpty, "A silent refresh posts no notification")
        XCTAssertEqual(harness.outcomes.count, firstCount)
        XCTAssertTrue(second.consoleText.contains("Refreshing Gradle project model in the background"))
    }

    // MARK: - Changing the root

    func testChangingTheRootClearsTheStateAndConsole() async throws {
        try makeGradleProject()
        harness.requestTrust = { _ in true }
        harness.setRoot(project)
        await eventually { harness.state == .synced(subprojects: 1, jars: 0) }
        XCTAssertFalse(harness.consoleText.isEmpty)

        harness.setRoot(nil)

        XCTAssertEqual(harness.state, .notGradle)
        XCTAssertFalse(harness.isGradleProject)
        XCTAssertNil(harness.modelModuleCount)
        XCTAssertEqual(harness.consoleText, "")
        XCTAssertFalse(harness.buildFilesChanged)
    }

    func testSourceRootsComeFromTheSyncedModel() async throws {
        try makeGradleProject()
        harness.requestTrust = { _ in true }
        XCTAssertTrue(harness.sourceRootPaths.isEmpty)
        harness.setRoot(project)
        await eventually { harness.state == .synced(subprojects: 1, jars: 0) }
        XCTAssertEqual(harness.sourceRootPaths, [project.appendingPathComponent("src/main/java").standardizedFileURL.path])
    }

    // MARK: - Tasks

    func testRunningTasksStreamsIntoTheConsoleAndReportsTheResult() async throws {
        try makeGradleProject()
        harness.requestTrust = { _ in true }
        harness.setRoot(project)
        await eventually { harness.state == .synced(subprojects: 1, jars: 0) }

        let outcome = await harness.runTasks(["build", ":app:test"])

        XCTAssertEqual(outcome, .finished(exitCode: 0))
        XCTAssertFalse(harness.isBusy)
        XCTAssertEqual(harness.finishedTasks.count, 1)
        XCTAssertEqual(harness.finishedTasks.first?.tasks, ["build", ":app:test"])
        XCTAssertEqual(harness.finishedTasks.first?.root, project)
        XCTAssertEqual(harness.finishedTasks.first?.exitCode, 0)
        let text = harness.consoleText
        XCTAssertTrue(text.contains("Tasks: build :app:test"), text)
        XCTAssertTrue(text.contains("Gradle exited 0"), text)
        XCTAssertTrue(invocations.last?.contains("build :app:test") ?? false)
        XCTAssertTrue(invocations.last?.contains("--no-configuration-cache") ?? false, "Plain runs turn the configuration cache off")
    }

    func testANonZeroExitIsAFinishedRunWithItsExitCode() async throws {
        try makeGradleProject()
        try flag("fail-task")
        harness.requestTrust = { _ in true }
        harness.setRoot(project)
        await eventually { harness.state == .synced(subprojects: 1, jars: 0) }

        let outcome = await harness.runTasks(["build"])

        XCTAssertEqual(outcome, .finished(exitCode: 3))
        XCTAssertEqual(harness.finishedTasks.first?.exitCode, 3)
    }

    func testATaskRunAsksForTrustFirstAndRefusesWithoutIt() async throws {
        try makeGradleProject()
        harness.requestTrust = nil
        harness.setRoot(project)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(harness.state, .awaitingTrust)

        harness.requestTrust = { _ in false }
        let refused = await harness.runTasks(["build"])
        XCTAssertEqual(refused, .notStarted("The project is not trusted, so its Gradle build scripts were not run."))
        XCTAssertTrue(harness.consoleText.contains("Not run: the project is not trusted"))
        XCTAssertTrue(invocations.isEmpty)

        harness.requestTrust = { _ in true }
        let ran = await harness.runTasks(["build"])
        XCTAssertEqual(ran, .finished(exitCode: 0))
        XCTAssertTrue(harness.isTrusted(project))
    }

    func testOnlyOneTaskRunAtATimeAndCancellingStopsIt() async throws {
        try makeGradleProject()
        harness.requestTrust = { _ in true }
        harness.setRoot(project)
        await eventually { harness.state == .synced(subprojects: 1, jars: 0) }
        try flag("slow")

        let first = Task { @MainActor in await harness.runTasks(["build"]) }
        await eventually { harness.isRunningTasks }
        XCTAssertEqual(harness.runningTaskPaths, ["build"])
        XCTAssertTrue(harness.isBusy)

        let second = await harness.runTasks(["test"])
        XCTAssertEqual(second, .notStarted("Gradle is already busy with a sync or another task in this window. Try again when it finishes."))

        harness.cancelTasks()
        XCTAssertFalse(harness.isRunningTasks)
        XCTAssertTrue(harness.runningTaskPaths.isEmpty)
        let result = await first.value
        if case .cancelled = result {} else { XCTFail("expected cancelled, got \(result)") }
        XCTAssertTrue(harness.consoleText.contains("Task run cancelled"))
    }

    func testAnEmptyTaskListIsRefused() async throws {
        try makeGradleProject()
        harness.setRoot(project)
        let outcome = await harness.runTasks([])
        XCTAssertEqual(outcome, .notStarted("No Gradle task was given."))
    }

    // MARK: - Build files

    func testEditingABuildFileRaisesTheReloadBannerUntilDismissed() async throws {
        try makeGradleProject()
        harness.requestTrust = { _ in true }
        harness.setRoot(project)
        await eventually { harness.state == .synced(subprojects: 1, jars: 0) }
        XCTAssertFalse(harness.buildFilesChanged)
        // The watcher starts a moment after the sync; let it settle before touching the file.
        try await Task.sleep(for: .milliseconds(1200))

        let build = project.appendingPathComponent("build.gradle")
        try "plugins { id 'java' }\n// edited".write(to: build, atomically: true, encoding: .utf8)
        await eventually("the watcher never reported the edit", seconds: 15) { harness.buildFilesChanged }

        harness.dismissBuildFileChanges()
        XCTAssertFalse(harness.buildFilesChanged)
    }

    func testTheSyncedModelListsItsTasksWithTheirModule() async throws {
        try makeGradleProject()
        harness.requestTrust = { _ in true }
        XCTAssertTrue(harness.taskPaths.isEmpty, "Nothing is known before a sync")
        harness.setRoot(project)
        await eventually { harness.state == .synced(subprojects: 1, jars: 0) }
        XCTAssertEqual(harness.taskPaths, [":build", ":run"])
        XCTAssertEqual(harness.taskGroups, ["build", "application"])
        XCTAssertEqual(harness.taskModules, [":", ":"])
    }

    // MARK: - Dependency graph

    func testTheModuleGraphIsBuiltFromTheModelWithoutRunningGradle() async throws {
        try makeGradleProject(subprojects: 2)
        harness.requestTrust = { _ in true }
        XCTAssertNil(harness.moduleGraphComponentCount)
        harness.setRoot(project)
        await eventually { harness.state == .synced(subprojects: 2, jars: 0) }
        let runsBefore = invocations.count
        XCTAssertEqual(harness.moduleGraphComponentCount, 2)
        XCTAssertEqual(invocations.count, runsBefore)
    }
}
