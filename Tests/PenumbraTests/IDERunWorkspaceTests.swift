import JavaIntelligence
import XCTest
@testable import Umbra

/// Run through a real `IDEWorkspace` and a real JDK: the validation, the JDK choice, the launch and
/// the console. Skipped on a machine with no JDK.
@MainActor
final class IDERunWorkspaceTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("run-workspace-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.runConfigurationStore = JavaRunConfigurationCatalog(
            store: JavaRunConfigurationStore(storeURL: base.appendingPathComponent("store.json"))
        )
        workspace.project.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    private func requireJDK() async throws -> JDKInstallation {
        let found = JDKLocator().discoverAll().filter { $0.featureVersion >= 11 }
        guard let jdk = found.first else { throw XCTSkip("no JDK (11+) on this machine") }
        return jdk
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, seconds: Double = 30) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func writeJava(_ name: String, _ source: String) throws -> URL {
        let url = project.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testASingleFileRunsInTheRunTabWithInputWorkingDirectoryAndEnvironment() async throws {
        let jdk = try await requireJDK()
        let file = try writeJava("Hello.java", """
        import java.util.Scanner;
        public class Hello {
            public static void main(String[] args) {
                System.out.print("Name: ");
                String name = new Scanner(System.in).nextLine();
                System.out.println("Hello, " + name + "! args=" + String.join("|", args));
                System.out.println("cwd=" + System.getProperty("user.dir"));
                System.out.println("mode=" + System.getenv("RUN_MODE"));
                System.err.println("warning");
                System.exit(7);
            }
        }
        """)
        let work = base.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var configuration = JavaRunConfiguration(
            name: "Hello", target: .singleFile(path: file.path),
            programArguments: "one \"two words\"", environment: ["RUN_MODE": "test"]
        )
        configuration.workingDirectory = work.path
        configuration.jdkHome = jdk.home.path

        let session = try XCTUnwrap(workspace.startRunSession(configuration))
        XCTAssertTrue(workspace.showsRunTab)
        XCTAssertTrue(workspace.isRunSelected)
        let prompted = await waitUntil { session.isRunning && session.log.plainText.contains("Name: ") }
        XCTAssertTrue(prompted, session.log.plainText)
        XCTAssertTrue(workspace.isRunActive)

        session.sendInput("Ada")
        let ended = await waitUntil { !session.isActive }
        XCTAssertTrue(ended, session.log.plainText)
        let output = session.log.plainText
        XCTAssertEqual(session.state, .exited(7), output)
        XCTAssertTrue(output.contains("Hello, Ada! args=one|two words"), output)
        // The JVM reports the real path (/private/var/…) of a temporary directory.
        XCTAssertTrue(output.range(of: #"cwd=\S*/work\n"#, options: .regularExpression) != nil, output)
        XCTAssertTrue(output.contains("mode=test"), output)
        XCTAssertTrue(session.log.segments.contains { $0.stream == .stderr && $0.text.contains("warning") })
        XCTAssertFalse(workspace.isRunActive)
        XCTAssertEqual(workspace.runConfigurations.map(\.id), [configuration.id], "the run is remembered")
    }

    func testRerunningTakesTheSameTabAndStopsTheOldRun() async throws {
        let jdk = try await requireJDK()
        let file = try writeJava("Wait.java", """
        public class Wait {
            public static void main(String[] args) throws Exception {
                System.out.println("up " + ProcessHandle.current().pid());
                Thread.sleep(60_000);
            }
        }
        """)
        var configuration = JavaRunConfiguration(name: "Wait", target: .singleFile(path: file.path))
        configuration.jdkHome = jdk.home.path
        let first = try XCTUnwrap(workspace.startRunSession(configuration))
        let up = await waitUntil { first.log.plainText.contains("up ") }
        XCTAssertTrue(up, first.log.plainText)

        workspace.rerun(first)
        XCTAssertEqual(workspace.runs.sessions.count, 1, "a rerun keeps its tab")
        let second = try XCTUnwrap(workspace.runs.selected)
        XCTAssertNotEqual(second.id, first.id)
        let firstEnded = await waitUntil { !first.isActive }
        XCTAssertTrue(firstEnded, "the first run is stopped before the second starts")
        let secondUp = await waitUntil { second.log.plainText.contains("up ") }
        XCTAssertTrue(secondUp, second.log.plainText)

        workspace.stopRunning()
        let stopped = await waitUntil { !second.isActive }
        XCTAssertTrue(stopped)
        guard case .stopped = second.state else { return XCTFail("expected stopped, got \(second.state)") }
    }

    func testAMissingFileOpensTheEditorInsteadOfRunning() async throws {
        var configuration = JavaRunConfiguration(name: "Gone", target: .singleFile(path: project.appendingPathComponent("Gone.java").path))
        configuration.jdkHome = nil
        XCTAssertNil(workspace.startRunSession(configuration))
        XCTAssertEqual(workspace.runConfigurationDraft?.id, configuration.id)
        XCTAssertFalse(workspace.showsRunTab)
        XCTAssertTrue(workspace.runs.sessions.isEmpty)
    }

    func testABrokenBeforeLaunchStepStopsTheLaunch() async throws {
        let jdk = try await requireJDK()
        let file = try writeJava("Never.java", "public class Never { public static void main(String[] a) { System.out.println(\"ran\"); } }")
        var configuration = JavaRunConfiguration(name: "Never", target: .singleFile(path: file.path))
        configuration.jdkHome = jdk.home.path
        configuration.beforeLaunch = [.runConfiguration(UUID())]
        // The validator refuses it up front: the deleted configuration is a problem of the configuration.
        XCTAssertNil(workspace.startRunSession(configuration))
        XCTAssertTrue(workspace.runs.sessions.isEmpty)
    }

    func testABeforeLaunchConfigurationRunsFirstAndAFailingOneBlocksTheLaunch() async throws {
        let jdk = try await requireJDK()
        let prepare = try writeJava("Prepare.java", "public class Prepare { public static void main(String[] a) { System.out.println(\"prepared\"); System.exit(Integer.parseInt(a.length > 0 ? a[0] : \"0\")); } }")
        let main = try writeJava("Main.java", "public class Main { public static void main(String[] a) { System.out.println(\"main ran\"); } }")

        var prepareConfiguration = JavaRunConfiguration(name: "Prepare", target: .singleFile(path: prepare.path))
        prepareConfiguration.jdkHome = jdk.home.path
        workspace.runConfigurationStore.save(prepareConfiguration, forProject: project)
        workspace.refreshLastRunConfiguration()

        var mainConfiguration = JavaRunConfiguration(name: "Main", target: .singleFile(path: main.path))
        mainConfiguration.jdkHome = jdk.home.path
        mainConfiguration.beforeLaunch = [.runConfiguration(prepareConfiguration.id)]

        let session = try XCTUnwrap(workspace.startRunSession(mainConfiguration))
        let finished = await waitUntil { !session.isActive && !workspace.runs.isAnyActive }
        XCTAssertTrue(finished, session.log.plainText)
        XCTAssertEqual(session.state, .exited(0), session.log.plainText)
        XCTAssertTrue(session.log.plainText.contains("main ran"))
        let prepared = try XCTUnwrap(workspace.runs.sessions.first { $0.title == "Prepare" })
        XCTAssertTrue(prepared.log.plainText.contains("prepared"))

        // Now make the first step fail.
        prepareConfiguration.programArguments = "5"
        workspace.runConfigurationStore.save(prepareConfiguration, forProject: project)
        workspace.refreshLastRunConfiguration()
        let blocked = try XCTUnwrap(workspace.startRunSession(mainConfiguration, replacing: session))
        let blockedEnded = await waitUntil { !blocked.isActive && !workspace.runs.isAnyActive }
        XCTAssertTrue(blockedEnded)
        guard case .failed(let reason) = blocked.state else { return XCTFail("expected failed, got \(blocked.state)") }
        XCTAssertTrue(reason.contains("did not finish successfully"), reason)
        XCTAssertFalse(blocked.log.plainText.contains("main ran"))
    }

    // MARK: - Configurations made by running

    func testRunningTestsLeavesATemporaryConfigurationThatRerunsThem() {
        let testFile = project.appendingPathComponent("src/test/java/FooTest.java")
        let method = JavaTestMethod(
            className: "app.FooTest", methodName: "testAdds", displayName: "testAdds()", sourceFile: testFile,
            line: 7, column: 9, framework: .junit5
        )
        workspace.runTests(scope: .testMethod(method, taskPath: ":app:test"), title: "testAdds()")
        let recorded = try? XCTUnwrap(workspace.lastRunConfiguration)
        XCTAssertEqual(recorded?.target, .gradleTest(taskPath: ":app:test", filters: ["app.FooTest.testAdds"], sourceFile: testFile.path))
        XCTAssertEqual(recorded?.isTemporary, true)
        XCTAssertEqual(recorded?.displayName, "FooTest.testAdds")

        // The same test again is the same entry, and keeps what the user changed about it.
        var edited = try! XCTUnwrap(recorded)
        edited.name = "Adds"
        edited.isTemporary = false
        workspace.runConfigurationStore.save(edited, forProject: project)
        workspace.refreshLastRunConfiguration()
        workspace.runTests(scope: .testMethod(method, taskPath: ":app:test"), title: "testAdds()")
        XCTAssertEqual(workspace.runConfigurations.count, 1)
        XCTAssertEqual(workspace.lastRunConfiguration?.name, "Adds")
        XCTAssertEqual(workspace.lastRunConfiguration?.isTemporary, false)
    }

    func testRunningAllTestsOfAModuleIsRecorded() {
        workspace.runTests(scope: .allInModule(gradleTaskPath: ":test"), title: "all")
        XCTAssertEqual(workspace.lastRunConfiguration?.launchMode, .run)
        XCTAssertEqual(workspace.lastRunConfiguration?.displayName, "All tests (:)")
    }

    func testSavingFromTheDialogKeepsATemporaryConfiguration() {
        let temporary = JavaRunConfiguration(target: .gradleRun(projectPath: ":"))
        XCTAssertTrue(temporary.isTemporary)
        workspace.runConfigurationDraft = temporary
        let editor = try! XCTUnwrap(workspace.runConfigurationsEditor)
        workspace.applyRunConfigurationEdits(editor.changes(), select: temporary.id)
        workspace.dismissRunConfigurationSheet()
        XCTAssertNil(workspace.runConfigurationDraft)
        XCTAssertEqual(workspace.lastRunConfiguration?.id, temporary.id)
        XCTAssertEqual(workspace.lastRunConfiguration?.isTemporary, false)

        let again = JavaRunConfiguration(target: .gradleRun(projectPath: ":app"))
        workspace.runConfigurationStore.setLast(again, forProject: project)
        workspace.refreshLastRunConfiguration()
        workspace.saveTemporaryRunConfiguration(again.id)
        XCTAssertEqual(workspace.runConfigurations.first { $0.id == again.id }?.isTemporary, false)
    }

    // MARK: - Java 21+ instance main

    func testACompactSourceFileWithAnInstanceMainRuns() async throws {
        let jdk = try XCTUnwrap(
            JDKLocator().discoverAll().filter { $0.featureVersion >= 21 }.first,
            "needs a JDK 21 or later"
        )
        let file = try writeJava("Compact.java", """
        String greeting = "compact says hi";

        void main() {
            System.out.println(greeting);
        }
        """)
        var configuration = JavaRunConfiguration(name: "Compact", target: .singleFile(path: file.path))
        configuration.jdkHome = jdk.home.path
        XCTAssertTrue(workspace.usesNewLaunchProtocol(configuration))

        let session = try XCTUnwrap(workspace.startRunSession(configuration))
        let ended = await waitUntil { !session.isActive }
        XCTAssertTrue(ended, session.log.plainText)
        XCTAssertEqual(session.state, .exited(0), session.log.plainText)
        XCTAssertTrue(session.log.plainText.contains("compact says hi"), session.log.plainText)
        // Java 21 to 24 need the preview switch; 25 and later do not.
        XCTAssertEqual(session.commandLine?.contains("--enable-preview"), jdk.featureVersion < 25, session.commandLine ?? "")
    }

    func testAClassicMainDoesNotNeedTheNewProtocol() throws {
        let file = try writeJava("Classic.java", "public class Classic { public static void main(String[] args) {} }")
        XCTAssertFalse(workspace.usesNewLaunchProtocol(JavaRunConfiguration(target: .singleFile(path: file.path))))
        let instance = try writeJava("Inst.java", "public class Inst { void main() {} }")
        XCTAssertTrue(workspace.usesNewLaunchProtocol(
            JavaRunConfiguration(target: .classpathMain(className: "Inst", sourceFile: instance.path))
        ))
        XCTAssertFalse(workspace.usesNewLaunchProtocol(
            JavaRunConfiguration(target: .classpathMain(className: "Other", sourceFile: instance.path))
        ), "a class that is not in the file")
    }
}

