import JavaIntelligence
import Penumbra
import SubprocessKit
import XCTest
@testable import Umbra

/// Run with Coverage and Profile through a real `IDEWorkspace`, a real JDK and the real JaCoCo and
/// `jfr` tools. Skipped without a JDK, and (coverage) without the jars `fetch.sh` downloads.
@MainActor
final class IDEInstrumentedRunWorkspaceTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("instr-workspace-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        IDEJavaRunProvider.artifactsRootOverride = base.appendingPathComponent("artifacts")
        workspace = IDEWorkspace()
        workspace.runConfigurationStore = JavaRunConfigurationCatalog(
            store: JavaRunConfigurationStore(storeURL: base.appendingPathComponent("store.json"))
        )
        workspace.project.setRoot(project)
        workspace.bootstrap()
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEJavaRunProvider.artifactsRootOverride = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    private func requireJDK() throws -> JDKInstallation {
        guard let jdk = JDKLocator().discoverAll().filter({ $0.featureVersion >= 11 && $0.javac != nil && $0.jfr != nil })
            .sorted(by: { $0.featureVersion < $1.featureVersion }).first else {
            throw XCTSkip("no full JDK (11+) on this machine")
        }
        return jdk
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, seconds: Double = 60) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func run(_ executable: URL, _ arguments: [String]) async throws -> SubprocessResult {
        var request = SubprocessRequest(executable: executable.path, arguments: arguments)
        request.timeout = .seconds(120)
        return try await SubprocessRunner.run(request)
    }

    private func compile(_ source: String, name: String, package: String, jdk: JDKInstallation) async throws -> (classes: URL, source: URL) {
        let directory = project.appendingPathComponent("src/\(package)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).java")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let classes = project.appendingPathComponent("classes", isDirectory: true)
        try FileManager.default.createDirectory(at: classes, withIntermediateDirectories: true)
        let result = try await run(try XCTUnwrap(jdk.javac), ["--release", String(min(jdk.featureVersion, 17)), "-g", "-d", classes.path, file.path])
        XCTAssertTrue(result.exit.succeeded, result.stderr.text)
        return (classes, file)
    }

    private let calc = """
    package app;
    public class Calc {
        public static int classify(int n) {
            if (n < 0) {
                return -1;
            }
            return 1;
        }
        public static int unused() {
            return 42;
        }
        public static void main(String[] args) {
            System.out.println("class=" + classify(5));
        }
    }
    """

    private func coveragePlan(jdk: JDKInstallation, classes: URL, sources: URL) throws -> IDEJavaRunProvider.CoveragePlan {
        let toolchain = try IDEJavaRunProvider.coverageToolchain()
        let run = try IDEJavaRunProvider.artifacts.allocate(
            kind: .coverage, projectHash: JavaRunArtifacts.projectHash(for: project)
        )
        let execution = run.directory.appendingPathComponent("exec", isDirectory: true)
        try FileManager.default.createDirectory(at: execution, withIntermediateDirectories: true)
        return IDEJavaRunProvider.CoveragePlan(
            toolchain: toolchain, run: run, executionDirectory: execution,
            scope: JavaCoverageScope(
                includes: JavaCoverageCommand.includes(packages: ["app"]),
                classDirectories: [classes], sourceDirectories: [sources]
            ),
            label: "Calc", java: jdk.home.appendingPathComponent("bin/java"), projectRoot: project, tasks: []
        )
    }

    // MARK: - Coverage

    func testAProgramRunWithCoverageEndsInABandedFile() async throws {
        let jdk = try requireJDK()
        let (classes, file) = try await compile(calc, name: "Calc", package: "app", jdk: jdk)
        let plan = try coveragePlan(jdk: jdk, classes: classes, sources: project.appendingPathComponent("src"))
        let provider = workspace.javaRun
        guard case .success(let arguments) = provider.vmArguments(for: .coverage(plan)) else { return XCTFail("no agent argument") }
        XCTAssertTrue(arguments[0].hasPrefix("-javaagent:"))

        let launch = IDEProcessLaunch(
            executable: jdk.home.appendingPathComponent("bin/java"),
            arguments: arguments + ["-cp", classes.path, "app.Calc"],
            workingDirectory: project, environment: ProcessInfo.processInfo.environment
        )
        let configuration = JavaRunConfiguration(name: "Calc", target: .classpathMain(className: "app.Calc", sourceFile: file.path))
        let session = workspace.runs.start(IDERunRequest(
            id: configuration.id, title: "Calc", providerID: "java", payload: configuration, allowsMultipleInstances: false,
            prepare: { session in
                provider.finishWhenSessionEnds(session, plan: .coverage(plan))
                session.start(launch)
            }
        ))
        let reported = await waitUntil { self.workspace.coverage.snapshot != nil || self.workspace.coverage.failureMessage != nil }
        XCTAssertTrue(reported, session.log.plainText)
        XCTAssertNil(workspace.coverage.failureMessage)
        XCTAssertEqual(session.state, .exited(0))

        let bands = workspace.coverage.bands(forFile: file)
        XCTAssertFalse(bands.isEmpty, "the report was resolved to the source file")
        let covered = try XCTUnwrap(workspace.coverage.snapshot?.report.sourceFile(at: file))
        XCTAssertEqual(covered.status(atLine: 4), .partial)
        XCTAssertEqual(covered.status(atLine: 10), .missed)
        XCTAssertTrue(workspace.showsCoverageTab)

        // The run's files are where Settings and the pruner expect them.
        let runs = IDEJavaRunProvider.artifacts.runs(kind: .coverage, projectHash: JavaRunArtifacts.projectHash(for: project))
        XCTAssertEqual(runs.map(\.id), [plan.run.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.run.directory.appendingPathComponent("report.xml").path))
    }

    func testAGradleTaskThatWroteExecutionDataIsReadFromItsMarkerLines() async throws {
        let jdk = try requireJDK()
        let (classes, file) = try await compile(calc, name: "Calc", package: "app", jdk: jdk)
        var plan = try coveragePlan(jdk: jdk, classes: classes, sources: project.appendingPathComponent("src"))
        plan.tasks = [":app:test"]
        let execution = plan.executionDirectory.appendingPathComponent("app-test.exec")
        let agent = try XCTUnwrap(JavaCoverageCommand.agentArgument(
            agentJar: plan.toolchain.agentJar, execFile: execution, includes: plan.scope.includes
        ))
        let ran = try await run(jdk.home.appendingPathComponent("bin/java"), [agent, "-cp", classes.path, "app.Calc"])
        XCTAssertTrue(ran.exit.succeeded, ran.stderr.text)

        let provider = workspace.javaRun
        provider.pendingInstrumentation = (.coverage(plan), [":app:test"])
        provider.projectTasksDidFinish(IDEProjectTaskReport(
            tasks: [":app:test"], root: project, exitCode: 0,
            stdout: "> Task :app:test\n\(JavaCoverageGradleScript.markerPrefix)\(execution.path)\nBUILD SUCCESSFUL\n", stderr: ""
        ))
        XCTAssertNil(provider.pendingInstrumentation, "the plan is consumed by the task that ended")
        let done = await waitUntil { self.workspace.coverage.snapshot != nil || self.workspace.coverage.failureMessage != nil }
        XCTAssertTrue(done)
        XCTAssertNotNil(workspace.coverage.snapshot?.report.sourceFile(at: file))
    }

    func testABuildThatEndsMeanwhileIsNotTheInstrumentedRun() async throws {
        let jdk = try requireJDK()
        let (classes, _) = try await compile(calc, name: "Calc", package: "app", jdk: jdk)
        let plan = try coveragePlan(jdk: jdk, classes: classes, sources: project.appendingPathComponent("src"))
        let provider = workspace.javaRun
        provider.pendingInstrumentation = (.coverage(plan), [":app:test"])
        provider.projectTasksDidFinish(IDEProjectTaskReport(tasks: [":app:classes"], root: project, exitCode: 0, stdout: "", stderr: ""))
        XCTAssertNotNil(provider.pendingInstrumentation)
        XCTAssertNil(workspace.coverage.snapshot)
    }

    func testAKilledRunSaysItWroteNoCoverageData() async throws {
        let jdk = try requireJDK()
        let (classes, _) = try await compile(calc, name: "Calc", package: "app", jdk: jdk)
        let plan = try coveragePlan(jdk: jdk, classes: classes, sources: project.appendingPathComponent("src"))
        workspace.javaRun.finishCoverage(plan, executionFiles: [plan.executionDirectory.appendingPathComponent("never.exec")], note: { _ in })
        let failed = await waitUntil { self.workspace.coverage.failureMessage != nil }
        XCTAssertTrue(failed)
        XCTAssertTrue(workspace.coverage.failureMessage?.contains("no coverage data") == true)
        XCTAssertTrue(workspace.showsCoverageTab)
    }

    func testASingleFileRefusesCoverageBeforeStartingAnything() async throws {
        let file = project.appendingPathComponent("Hello.java")
        try "public class Hello { public static void main(String[] a) { System.out.println(1); } }".write(to: file, atomically: true, encoding: .utf8)
        var configuration = JavaRunConfiguration(name: "Hello", target: .singleFile(path: file.path))
        configuration.instrumentation = .coverage
        XCTAssertNil(workspace.startRunSession(configuration))
        XCTAssertEqual(workspace.runConfigurationDraft?.id, configuration.id, "the dialog opens on the problem")
        XCTAssertTrue(workspace.runs.sessions.isEmpty)
    }

    // MARK: - Profile

    func testProfilingASingleFileOpensItsRecordingInTheProfiler() async throws {
        let jdk = try requireJDK()
        let file = project.appendingPathComponent("Spin.java")
        try """
        public class Spin {
            static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
            public static void main(String[] args) {
                long end = System.nanoTime() + 1_200_000_000L;
                while (System.nanoTime() < end) { fib(22); }
            }
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        var configuration = JavaRunConfiguration(name: "Spin", target: .singleFile(path: file.path))
        configuration.jdkHome = jdk.home.path
        configuration.instrumentation = .profile

        let session = try XCTUnwrap(workspace.startRunSession(configuration))
        // The profiler tab opens when the program starts, with live charts; the same tab then reads
        // the recording.
        let watching = await waitUntil { self.workspace.profileSessions.values.contains { $0.live != nil } }
        XCTAssertTrue(watching, session.log.plainText)
        let ended = await waitUntil { !session.isActive }
        XCTAssertTrue(ended, session.log.plainText)
        XCTAssertEqual(session.state, .exited(0), session.log.plainText)

        let opened = await waitUntil {
            self.workspace.workbench.allDocuments().contains { $0.contentKind == .profile && $0.url != nil }
        }
        XCTAssertTrue(opened, session.log.plainText)
        XCTAssertEqual(workspace.workbench.allDocuments().filter { $0.contentKind == .profile }.count, 1, "one tab, not two")
        let document = try XCTUnwrap(workspace.workbench.allDocuments().first { $0.contentKind == .profile })
        XCTAssertEqual(document.displayName, "Profile: Spin")
        XCTAssertTrue(document.url?.path.contains("/Profiles/") == true)
        let profiler = try XCTUnwrap(workspace.profileSessions[document.id])
        let showing = workspace.host(for: workspace.workbench.activePaneID).profileViewer
        XCTAssertTrue(showing.session === profiler, "the viewer is over the editor")
        let ready = await waitUntil { profiler.phase == .ready }
        XCTAssertTrue(ready, "\(profiler.phase)")
        XCTAssertGreaterThan(profiler.profile?.cpuSamples ?? 0, 10)
        let top = try XCTUnwrap(profiler.hotMethods.first)
        XCTAssertEqual(profiler.symbols?.qualifiedName(ofMethod: top.method), "Spin.fib")

        // The run left a record beside its recording, with the stack depth the recorder was asked for,
        // and the recording has times for the timeline.
        let recent = try XCTUnwrap(workspace.recentProfiles().first)
        XCTAssertEqual(recent.title, "Spin")
        XCTAssertEqual(recent.info?.label, "Spin")
        XCTAssertNotNil(recent.info?.finishedAt)
        XCTAssertEqual(recent.info?.recordingCount, 1)
        XCTAssertTrue(recent.info?.settings.contains("depth 128") == true, recent.info?.settings ?? "")
        XCTAssertNotNil(profiler.timeline, "the recording's events have times")
        XCTAssertGreaterThan(profiler.profile?.threads(of: .cpu).count ?? 0, 0)

        // A frame opens the project's source.
        profiler.openFrame?("Spin", 2, nil)
        let revealed = await waitUntil {
            self.workspace.workbench.activePane.selectedDocument?.url?.standardizedFileURL == file.standardizedFileURL
        }
        _ = revealed
    }

    func testProfileNeedsJavaElevenAndSaysSo() async throws {
        let jdk = try requireJDK()
        let file = project.appendingPathComponent("Old.java")
        try "public class Old { public static void main(String[] a) { } }".write(to: file, atomically: true, encoding: .utf8)
        var configuration = JavaRunConfiguration(name: "Old", target: .singleFile(path: file.path))
        configuration.jdkHome = jdk.home.path
        configuration.instrumentation = .profile
        let context = JavaRunConfigurationValidator.Context(
            jdkFeatureVersion: 8, fileExists: { _ in true }, directoryExists: { _ in true }
        )
        XCTAssertTrue(JavaRunConfigurationValidator.problems(for: configuration, context: context).contains { $0.field == .jdk })
    }

    // MARK: - Where the jars are found

    func testTheJarsAreFoundInEachLayoutAnAppCanHave() throws {
        let fileManager = FileManager.default
        func layout(_ name: String, jarsAt relative: String) throws -> [URL] {
            let resources = base.appendingPathComponent(name, isDirectory: true)
            let jars = resources.appendingPathComponent(relative, isDirectory: true)
            try fileManager.createDirectory(at: jars, withIntermediateDirectories: true)
            for jar in ["jacocoagent.jar", "jacococli.jar"] {
                try Data([0x50, 0x4B]).write(to: jars.appendingPathComponent(jar))
            }
            return IDEJavaRunProvider.coverageToolchainDirectories(
                resources: resources, executableDirectory: nil,
                sourceDirectory: base.appendingPathComponent("nowhere")
            )
        }
        // Swift Build: the package's name leads the bundle, resources are flat.
        var toolchain = try JavaCoverageToolchain.locate(in: layout("swiftbuild", jarsAt: "Penumbra_Umbra.bundle/Contents/Resources"))
        XCTAssertEqual(toolchain.agentJar.lastPathComponent, "jacocoagent.jar")
        // The Xcode project: copied flat into Resources.
        toolchain = try JavaCoverageToolchain.locate(in: layout("xcode", jarsAt: "."))
        XCTAssertTrue(toolchain.cliJar.path.contains("/xcode/"))
        // The native build system keeps the relative path.
        toolchain = try JavaCoverageToolchain.locate(in: layout("native", jarsAt: "Penumbra_Umbra.bundle/Tools/JaCoCo/build"))
        XCTAssertTrue(toolchain.agentJar.path.contains("Penumbra_Umbra.bundle/Tools/JaCoCo/build"))
        // Nothing bundled says so.
        XCTAssertThrowsError(try JavaCoverageToolchain.locate(in: IDEJavaRunProvider.coverageToolchainDirectories(
            resources: base.appendingPathComponent("empty"), executableDirectory: nil, sourceDirectory: base.appendingPathComponent("nowhere")
        )))
    }

    /// Opt-in: `UMBRA_PACKAGED_APP=/path/to/Umbra.app` (what `Scripts/build-app.sh` makes) checks
    /// that the app's own lookup finds the jars in a real packaged layout.
    func testThePackagedAppHasTheJarsWhereTheLookupLooks() throws {
        guard let path = ProcessInfo.processInfo.environment["UMBRA_PACKAGED_APP"] else {
            throw XCTSkip("set UMBRA_PACKAGED_APP to a built Umbra.app")
        }
        let app = URL(fileURLWithPath: path)
        let directories = IDEJavaRunProvider.coverageToolchainDirectories(
            resources: app.appendingPathComponent("Contents/Resources"),
            executableDirectory: app.appendingPathComponent("Contents/MacOS"),
            sourceDirectory: base.appendingPathComponent("nowhere")
        )
        let toolchain = try JavaCoverageToolchain.locate(in: directories)
        XCTAssertTrue(toolchain.agentJar.path.hasPrefix(app.path))
        // The CLI in the bundle really is JaCoCo's: it answers `--help`.
        let jdk = try requireJDK()
        let result = try SubprocessRunner.runBlocking(SubprocessRequest(
            executable: jdk.home.appendingPathComponent("bin/java").path, arguments: ["-jar", toolchain.cliJar.path, "--help"]
        ))
        XCTAssertTrue(result.stdout.text.contains("report"), result.stdout.text + result.stderr.text)
    }
}
