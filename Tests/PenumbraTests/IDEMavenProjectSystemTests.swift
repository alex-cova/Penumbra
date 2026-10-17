import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

/// Maven as a project system: detection, a native POM read, the trust gate, downloads, re-reads and
/// goal reports. Nothing here runs a real `mvn`.
@MainActor
final class IDEMavenProjectSystemTests: XCTestCase {
    private var directory: URL!
    private var maven: IDEMavenProjectSystem!
    private var java: IDEJavaSupport?
    private var launcher: MavenScriptLauncher!
    private var trust: GradleTrustStore!
    private var prompts: PromptCount!

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-maven-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        prompts = PromptCount()
    }

    override func tearDown() async throws {
        maven?.stop()
        java?.teardown()
        java = nil
        maven = nil
        try? FileManager.default.removeItem(at: directory)
        IDEWorkspace.isSessionPersistenceEnabled = true
    }

    private func waitUntil(seconds: Double = 8, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func consoleText() -> String {
        maven.console.lines.map(\.text).joined(separator: "\n")
    }

    /// `home` is the fake user home. `indexing` wires `IDEJavaSupport` the way a window does.
    private func makeSystem(download: Bool = false, indexing: Bool = false) throws -> URL {
        let home = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        trust = GradleTrustStore(storeURL: directory.appendingPathComponent("maven-trust.json"))
        launcher = MavenScriptLauncher(repository: home.appendingPathComponent(".m2/repository", isDirectory: true))
        let jdk = IDEJDKSelection(store: JDKSelectionStore(storeURL: directory.appendingPathComponent("jdk.json")))
        let status = IDEProjectStatus()
        let runner = MavenCommandRunner(trustStore: trust, launcher: launcher)
        maven = IDEMavenProjectSystem(
            jdk: jdk,
            status: status,
            trustStore: trust,
            runner: runner,
            pomStore: MavenPOMStore(),
            userHome: home,
            environment: [:],
            profileStoreURL: directory.appendingPathComponent("maven-profiles.json")
        )
        maven.autoReadOverride = true
        maven.downloadDependenciesOverride = download
        maven.usesPreferenceSettings = false
        maven.trustPrompt = { [prompts] _ in
            prompts?.value += 1
            return false
        }
        if indexing {
            let gradleTrust = GradleTrustStore(storeURL: directory.appendingPathComponent("gradle-trust.json"))
            let gradle = IDEGradleProjectSystem(
                jdk: jdk, status: status, trustStore: gradleTrust,
                modelCacheRoot: directory.appendingPathComponent("gradle-cache", isDirectory: true)
            )
            java = IDEJavaSupport(
                jdk: jdk, gradle: gradle, maven: maven, status: status, shardHub: JavaSharedShardHub()
            )
        }
        return home
    }

    private func writeProject(named name: String = "app", dependency: Bool = false, marker: String? = nil) throws -> URL {
        let root = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try pomText(dependency: dependency).write(to: root.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)
        if let marker {
            try Data().write(to: root.appendingPathComponent(marker))
        }
        let wrapper = root.appendingPathComponent("mvnw")
        try "#!/bin/sh\nexit 0\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return root
    }

    private func pomText(dependency: Bool) -> String {
        let body = dependency ? """
          <dependencies>
            <dependency>
              <groupId>com.example</groupId>
              <artifactId>widget</artifactId>
              <version>1.0.0</version>
            </dependency>
          </dependencies>
        """ : ""
        return """
        <project>
          <modelVersion>4.0.0</modelVersion>
          <groupId>com.example</groupId>
          <artifactId>app</artifactId>
          <version>1</version>
        \(body)
        </project>
        """
    }

    /// Waits until the read has settled on a terminal state.
    private func open(_ root: URL) async -> IDEProjectSyncState {
        maven.projectDidChange(root: root)
        _ = await waitUntil {
            switch maven.syncState {
            case .syncing: return false
            case .notDetected, .awaitingTrust, .untrusted, .synced, .failed: return true
            }
        }
        return maven.syncState
    }

    func testAPomIsMavenAndAGradleMarkerWins() async throws {
        let root = try writeProject()
        XCTAssertTrue(IDEMavenProjectSystem.isMavenProject(root))
        for marker in ["settings.gradle", "settings.gradle.kts", "build.gradle", "build.gradle.kts", "gradlew"] {
            let both = try writeProject(named: "both-\(marker)", marker: marker)
            XCTAssertFalse(IDEMavenProjectSystem.isMavenProject(both), marker)
        }
        _ = try makeSystem()
        let both = directory.appendingPathComponent("both-build.gradle", isDirectory: true)
        maven.projectDidChange(root: both)
        XCTAssertEqual(maven.syncState, .notDetected)
        XCTAssertFalse(maven.isActive)
        XCTAssertNil(maven.model)
        let launches = await launcher.commands
        XCTAssertTrue(launches.isEmpty)
    }

    func testReadingAPomDoesNotAskForTrustOrRunMaven() async throws {
        _ = try makeSystem(download: true)
        let root = try writeProject(dependency: true)
        let state = await open(root)
        guard case .synced(let modules, _) = state else {
            XCTFail("expected a synced model, got \(state)")
            return
        }
        XCTAssertEqual(modules, 1)
        XCTAssertEqual(maven.model?.modules.first?.artifactId, "app")
        XCTAssertFalse(maven.model?.missing.isEmpty ?? true)
        XCTAssertEqual(prompts.value, 0)
        XCTAssertFalse(consoleText().localizedCaseInsensitiveContains("trust"))
        let launches = await launcher.commands
        XCTAssertTrue(launches.isEmpty, "an untrusted read must not start Maven")
        XCTAssertEqual(maven.readCount, 1)
    }

    func testGoalsAndDownloadsDoNotRunUntilTheFolderIsTrusted() async throws {
        _ = try makeSystem(download: true)
        let root = try writeProject(dependency: true)
        _ = await open(root)
        XCTAssertEqual(prompts.value, 0)
        var outcomes: [IDEMavenRunOutcome] = []
        maven.downloadDependencies(sources: false) { outcomes.append($0) }
        let downloaded = await waitUntil { outcomes.count == 1 && !maven.isBusy }
        XCTAssertTrue(downloaded)
        guard case .notStarted = outcomes[0] else {
            XCTFail("download started: \(outcomes)")
            return
        }
        maven.runGoals(["package"], module: "com.example:app") { outcomes.append($0) }
        let ran = await waitUntil { outcomes.count == 2 && !maven.isBusy }
        XCTAssertTrue(ran)
        guard case .notStarted = outcomes[1] else {
            XCTFail("goal started: \(outcomes)")
            return
        }
        XCTAssertEqual(prompts.value, 2)
        let launches = await launcher.commands
        XCTAssertTrue(launches.isEmpty)
    }

    func testATrustedReadDownloadsAMissingJarAndFindsIt() async throws {
        _ = try makeSystem(download: true)
        let root = try writeProject(dependency: true)
        trust.setTrusted(true, for: root)
        let state = await open(root)
        guard case .synced(_, let dependencies) = state else {
            XCTFail("expected a synced model, got \(state). \(consoleText())")
            return
        }
        XCTAssertGreaterThanOrEqual(dependencies, 1)
        XCTAssertEqual(maven.model?.missing.count, 0)
        let jars = maven.model?.javaProjectModel.classpathJars.map(\.lastPathComponent) ?? []
        XCTAssertTrue(jars.contains("widget-1.0.0.jar"), "\(jars)")
        XCTAssertGreaterThanOrEqual(maven.readCount, 2)
        XCTAssertEqual(prompts.value, 0)
        let launches = await launcher.commands
        XCTAssertTrue(launches.contains { $0.arguments.contains("dependency:resolve") })
    }

    func testAByteChangeRereadsAndAParseErrorKeepsTheModel() async throws {
        _ = try makeSystem()
        let root = try writeProject()
        let state = await open(root)
        guard case .synced = state else {
            XCTFail("expected a synced model, got \(state). \(consoleText())")
            return
        }
        XCTAssertEqual(maven.readCount, 1)
        let pom = root.appendingPathComponent("pom.xml")
        let original = try String(contentsOf: pom, encoding: .utf8)
        try original.write(to: pom, atomically: true, encoding: .utf8)
        maven.filesDidChange([pom.path])
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(maven.readCount, 1, "a same-bytes save must not re-read")

        try "<project>\n<artifactId>\n".write(to: pom, atomically: true, encoding: .utf8)
        maven.filesDidChange([pom.path])
        let sawError = await waitUntil { self.consoleText().contains("pom.xml:") }
        XCTAssertTrue(sawError, consoleText())
        XCTAssertEqual(maven.readCount, 1)
        XCTAssertEqual(maven.model?.modules.first?.artifactId, "app")
        XCTAssertFalse(maven.syncState.isFailed)
        guard case .synced = maven.syncState else {
            XCTFail("a later parse error changed the state to \(maven.syncState)")
            return
        }

        maven.reload()
        let settled = await waitUntil { !self.maven.isBusy && self.consoleText().contains("pom.xml:") }
        XCTAssertTrue(settled, "state \(maven.syncState): \(consoleText())")
        XCTAssertEqual(maven.model?.modules.first?.artifactId, "app")
        XCTAssertFalse(maven.syncState.isFailed)
        guard case .synced = maven.syncState else {
            XCTFail("reload left \(maven.syncState)")
            return
        }
    }

    func testTheFirstBrokenPomFailsAndAGoalReportNamesTheGoals() async throws {
        _ = try makeSystem()
        let broken = directory.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "<project>\n<artifactId>\n".write(to: broken.appendingPathComponent("pom.xml"), atomically: true, encoding: .utf8)
        let failed = await open(broken)
        guard case .failed = failed else {
            XCTFail("expected a failed read, got \(failed)")
            return
        }
        XCTAssertNil(maven.model)
        XCTAssertTrue(consoleText().contains("pom.xml:"))

        let root = try writeProject()
        trust.setTrusted(true, for: root)
        let synced = await open(root)
        guard case .synced = synced else {
            XCTFail("expected a synced model, got \(synced). \(consoleText())")
            return
        }
        var reports: [IDEProjectTaskReport] = []
        maven.environment.tasksFinished = { reports.append($0) }
        var outcomes: [IDEMavenRunOutcome] = []
        maven.runGoals(["package"], module: "com.example:app") { outcomes.append($0) }
        let packaged = await waitUntil { reports.count == 1 && outcomes.count == 1 && !self.maven.isBusy }
        XCTAssertTrue(packaged, "state \(maven.syncState) busy \(maven.isBusy) \(consoleText())")
        XCTAssertEqual(reports.first?.tasks, ["package"])
        guard case .finished(let result) = outcomes.first else {
            XCTFail("package did not finish: \(outcomes)")
            return
        }
        XCTAssertEqual(result.exitCode, 0)
        let commands = await launcher.commands
        let command = try XCTUnwrap(commands.last)
        XCTAssertTrue(command.arguments.contains("package"))
        XCTAssertTrue(command.arguments.contains("-pl"))
        XCTAssertTrue(command.arguments.contains("com.example:app"))
        XCTAssertTrue(command.arguments.contains("-am"))
        XCTAssertFalse(reports[0].tasks.contains("-pl"))

        maven.build()
        let built = await waitUntil { reports.count == 2 && !self.maven.isBusy }
        XCTAssertTrue(built, consoleText())
        XCTAssertEqual(reports.last?.tasks, ["test-compile"])
    }

    func testAutoReadOffWaitsWithoutMentioningTrust() async throws {
        _ = try makeSystem()
        maven.autoReadOverride = false
        let root = try writeProject()
        maven.projectDidChange(root: root)
        XCTAssertEqual(maven.syncState, .awaitingTrust)
        XCTAssertTrue(maven.isActive)
        XCTAssertNil(maven.model)
        XCTAssertTrue(consoleText().contains("Reload to read it."))
        XCTAssertFalse(consoleText().localizedCaseInsensitiveContains("trust"))
        XCTAssertEqual(prompts.value, 0)
    }

    func testJavaReadsTheMavenProjection() async throws {
        _ = try makeSystem(indexing: true)
        let root = try writeProject()
        let state = await open(root)
        guard case .synced = state else {
            XCTFail("expected a synced model, got \(state). \(consoleText())")
            return
        }
        XCTAssertEqual(java?.projectModel?.gradleVersion, "maven")
        XCTAssertFalse(java?.gradle.isActive ?? true)
        XCTAssertTrue(java?.maven.isActive ?? false)
        XCTAssertTrue(java?.isJavaBuildActive ?? false)
    }

    func testMavenChromeDoesNotRetainTheWorkspace() async throws {
        weak var weakWorkspace: IDEWorkspace?
        do {
            let workspace = IDEWorkspace()
            weakWorkspace = workspace
            workspace.bootstrap()
            _ = workspace.maven.toolWindows(for: workspace)
            _ = workspace.maven.bottomTabs(for: workspace)
            _ = workspace.maven.toolbarItems(for: workspace)
            _ = workspace.maven.makeSidebar()
            workspace.teardown()
        }
        for _ in 0..<50 where weakWorkspace != nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(weakWorkspace, "Maven chrome holds the closed window's workspace")
    }
}

@MainActor
private final class PromptCount {
    var value = 0
}

/// Records every Maven launch. A `dependency:resolve` writes `com.example:widget:1.0.0` into the
/// fake local repository so the following read can find the jar.
private actor MavenScriptLauncher: GradleProcessLaunching {
    let repository: URL
    private(set) var commands: [GradleCommand] = []

    init(repository: URL) {
        self.repository = repository
    }

    func launch(
        _ command: GradleCommand, timeout: Duration, output: GradleOutputHandler?
    ) async throws -> GradleCommandResult {
        commands.append(command)
        if command.arguments.contains("dependency:resolve") {
            let folder = MavenLocalRepository.artifactDirectory(
                groupId: "com.example", artifactId: "widget", version: "1.0.0", repository: repository
            )
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = MavenLocalRepository.fileName(
                artifactId: "widget", version: "1.0.0", classifier: "", extension: "jar"
            )
            try Data([0x50, 0x4b]).write(to: folder.appendingPathComponent(name))
        }
        return GradleCommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}
