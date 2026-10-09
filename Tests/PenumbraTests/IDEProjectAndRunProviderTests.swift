import Foundation
import JavaIntelligence
import SwiftUI
import XCTest
@testable import Umbra

/// The generic layers phase 5 added under the Gradle and Java code: project systems, run providers,
/// run sessions that know no Java type, and the Java provider's answers about a file.
@MainActor
final class IDEProjectAndRunProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    // MARK: - Project systems

    @MainActor
    private final class FakeProjectSystem: IDEProjectSystem {
        let id: String
        let displayName: String
        var environment = IDEProjectEnvironment()
        var detects: (URL) -> Bool
        var isActive = false
        var syncState = IDEProjectSyncState.notDetected
        var isBusy = false
        var runningTasks: [String] = []
        var console = IDEProjectConsoleLog()
        var tasks: [IDEProjectTask] = []
        var sourceRootPaths: Set<String> = []
        var hasConfigurationChanges = false
        let log: Log

        final class Log {
            var events: [String] = []
        }

        init(id: String, log: Log, detects: @escaping (URL) -> Bool = { _ in false }) {
            self.id = id
            displayName = id.capitalized
            self.log = log
            self.detects = detects
        }

        func projectDidChange(root: URL?) {
            isActive = root.map(detects) ?? false
            log.events.append("\(id) root=\(root?.lastPathComponent ?? "nil")")
        }

        func reload() { log.events.append("\(id) reload") }
        func dismissConfigurationChanges() {}
        func cancelSync() {}
        func cancelTasks() { log.events.append("\(id) cancelTasks") }
        func runTasks(_ tasks: [String]) { log.events.append("\(id) run \(tasks.joined(separator: " "))") }
        func build() { log.events.append("\(id) build") }
        func stop() { log.events.append("\(id) stop") }
        func toolWindows(for workspace: IDEWorkspace) -> [IDEToolWindow] { [] }
        func bottomTabs(for workspace: IDEWorkspace) -> [IDEBottomTabContribution] { [] }
        func makeSidebar() -> AnyView { AnyView(EmptyView()) }
    }

    func testTheFirstSystemThatRecognizedTheFolderIsTheActiveOne() {
        let log = FakeProjectSystem.Log()
        let cargo = FakeProjectSystem(id: "cargo", log: log) { $0.lastPathComponent == "crate" }
        let gradle = FakeProjectSystem(id: "gradle", log: log) { _ in true }
        let systems = IDEProjectSystems([cargo, gradle])

        XCTAssertNil(systems.active, "Nothing is open yet")
        systems.projectDidChange(root: URL(fileURLWithPath: "/work/app"))
        XCTAssertEqual(systems.active?.id, "gradle")
        systems.projectDidChange(root: URL(fileURLWithPath: "/work/crate"))
        XCTAssertEqual(systems.active?.id, "cargo", "Systems claim a folder in the order they were given")
        systems.projectDidChange(root: nil)
        XCTAssertNil(systems.active)
        XCTAssertEqual(systems.system(id: "gradle")?.displayName, "Gradle")
        XCTAssertEqual(log.events, ["cargo root=app", "gradle root=app", "cargo root=crate", "gradle root=crate", "cargo root=nil", "gradle root=nil"])
    }

    func testStartingGivesEverySystemTheSameEnvironmentAndStoppingGoesInReverse() {
        let log = FakeProjectSystem.Log()
        let first = FakeProjectSystem(id: "a", log: log)
        let second = FakeProjectSystem(id: "b", log: log)
        let systems = IDEProjectSystems([first, second])

        var environment = IDEProjectEnvironment()
        environment.requestTrust = { _ in true }
        systems.start(environment: environment)
        XCTAssertNotNil(first.environment.requestTrust)
        XCTAssertNotNil(second.environment.requestTrust)

        second.isBusy = true
        XCTAssertTrue(systems.isBusy)
        systems.stop()
        XCTAssertEqual(log.events, ["b stop", "a stop"])
    }

    func testSyncStatesKnowTheirWaysToBeBusyOrFailed() {
        XCTAssertTrue(IDEProjectSyncState.syncing.isSyncing)
        XCTAssertFalse(IDEProjectSyncState.synced(modules: 1, dependencies: 2).isSyncing)
        XCTAssertTrue(IDEProjectSyncState.failed(summary: "x").isFailed)
        XCTAssertFalse(IDEProjectSyncState.untrusted.isFailed)
        XCTAssertEqual(IDEProjectSyncState.notDetected, .notDetected)
    }

    func testTheStatusLineIsClearedOnlyByTheWriterThatSetIt() {
        let status = IDEProjectStatus()
        status.set("Indexing JDK 24…")
        status.clear("Resolving Gradle project…")
        XCTAssertEqual(status.message, "Indexing JDK 24…", "A finishing task must not blank another's message")
        status.clear("Indexing JDK 24…")
        XCTAssertNil(status.message)
    }

    func testATaskReportJoinsItsOutput() {
        let report = IDEProjectTaskReport(tasks: ["build"], root: URL(fileURLWithPath: "/p"), exitCode: 1, stdout: "out", stderr: "err")
        XCTAssertEqual(report.output, "out\nerr")
    }

    // MARK: - Run providers

    @MainActor
    private final class FakeRunProvider: IDERunProvider {
        let id: String
        let languageIdentifiers: Set<String>
        var hasActiveWork = false
        var events: [String] = []
        var contextAnswer = true

        init(id: String, languages: Set<String>) {
            self.id = id
            languageIdentifiers = languages
        }

        func canRun(_ document: IDERunDocument) -> Bool { document.text.contains("main") }
        func canDebug(fileURL: URL?) -> Bool { false }
        func runHelp(fileURL: URL?) -> String { "Run \(id)" }
        func debugHelp(fileURL: URL?, canRun: Bool) -> String { "No debugger" }
        func run(_ document: IDERunDocument, mode: IDERunMode) { events.append("run \(mode)") }
        func runInContext(_ document: IDERunDocument, mode: IDERunMode) async -> Bool {
            events.append("context \(mode) at \(document.caretUTF16Offset)")
            return contextAnswer
        }
        func rerun(_ session: IDERunSession) { events.append("rerun \(session.title)") }
        func stop() { events.append("stop") }
        func projectTasksDidFinish(_ report: IDEProjectTaskReport) { events.append("tasks \(report.tasks.joined(separator: ","))") }
    }

    func testRunProvidersAreFoundByLanguageIdAndType() {
        let rust = FakeRunProvider(id: "rust", languages: ["rust"])
        let script = FakeRunProvider(id: "script", languages: ["python", "ruby"])
        let providers = IDERunProviders([rust, script])

        XCTAssertTrue(providers.provider(forLanguage: "rust") === rust)
        XCTAssertTrue(providers.provider(forLanguage: "ruby") === script)
        XCTAssertNil(providers.provider(forLanguage: "java"))
        XCTAssertNil(providers.provider(forLanguage: nil))
        XCTAssertTrue(providers.provider(id: "script") === script)
        XCTAssertTrue(providers.provider(FakeRunProvider.self) === rust)
    }

    func testStopAndTaskReportsReachEveryProvider() {
        let first = FakeRunProvider(id: "a", languages: ["a"])
        let second = FakeRunProvider(id: "b", languages: ["b"])
        let providers = IDERunProviders([first, second])

        XCTAssertFalse(providers.hasActiveWork)
        second.hasActiveWork = true
        XCTAssertTrue(providers.hasActiveWork)
        providers.stopAll()
        providers.projectTasksDidFinish(IDEProjectTaskReport(tasks: ["t"], root: URL(fileURLWithPath: "/"), exitCode: 0, stdout: "", stderr: ""))
        XCTAssertEqual(first.events, ["stop", "tasks t"])
        XCTAssertEqual(second.events, ["stop", "tasks t"])
    }

    func testTheDocumentCopiesItsTextOnlyWhenAProviderReadsIt() {
        var lazyCopies = 0
        func read() -> String { lazyCopies += 1; return "body" }
        let lazy = IDERunDocument(url: nil, languageIdentifier: "x", text: read())
        XCTAssertEqual(lazyCopies, 0)
        XCTAssertEqual(lazy.text, "body")
        XCTAssertEqual(lazy.text, "body")
        XCTAssertEqual(lazyCopies, 2, "Each read goes back to the buffer, so a provider keeps what it needs")
    }

    // MARK: - Run sessions

    private func request(
        id: UUID = UUID(), title: String = "Main", multiple: Bool = false, prepare: @escaping @MainActor (IDERunSession) async -> Void = { _ in }
    ) -> IDERunRequest {
        IDERunRequest(id: id, title: title, providerID: "fake", payload: nil, allowsMultipleInstances: multiple, prepare: prepare)
    }

    private func eventually(
        _ message: @autoclosure () -> String = "", seconds: Double = 5,
        file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), message(), file: file, line: line)
    }

    func testAnotherStartOfTheSameRunTakesOverItsTabAfterTheOldOneEnds() async {
        let runs = IDERunSessions()
        let id = UUID()
        var prepared: [String] = []
        let first = runs.start(request(id: id) { session in prepared.append("first"); _ = session })
        await eventually { prepared == ["first"] }
        XCTAssertEqual(first.providerID, "fake")
        XCTAssertEqual(first.title, "Main")

        // The first session is still preparing, so it is stopped, and the second waits for that.
        let second = runs.start(request(id: id) { _ in prepared.append("second") })
        XCTAssertEqual(runs.sessions.map(\.id), [second.id], "The rerun keeps the tab: one session, not two")
        XCTAssertFalse(first.isActive, "The old run was stopped")
        await eventually { prepared == ["first", "second"] }
    }

    func testARunThatAllowsSeveralInstancesRunsBesideTheFirst() async {
        let runs = IDERunSessions()
        let id = UUID()
        let first = runs.start(request(id: id, multiple: true))
        let second = runs.start(request(id: id, multiple: true))
        XCTAssertEqual(runs.sessions.map(\.id), [first.id, second.id])
        XCTAssertTrue(first.isActive && second.isActive)
        XCTAssertEqual(runs.title(for: second), "Main (2)")
    }

    func testAFinishedRunIsReplacedEvenWhenSeveralInstancesAreAllowed() async {
        let runs = IDERunSessions()
        let id = UUID()
        let first = runs.start(request(id: id, multiple: true) { $0.fail("could not start") })
        await eventually { !first.isActive }
        let second = runs.start(request(id: id, multiple: true))
        XCTAssertEqual(runs.sessions.map(\.id), [second.id])
    }

    func testAnExplicitReplacementWinsOverTheLatestRun() {
        let runs = IDERunSessions()
        let a = runs.start(request(id: UUID(), title: "A"))
        let b = runs.start(request(id: UUID(), title: "B"))
        let c = runs.start(request(id: UUID(), title: "C"), replacing: a)
        XCTAssertEqual(runs.sessions.map(\.id), [c.id, b.id])
        XCTAssertEqual(runs.selected?.id, c.id)
    }

    func testASessionKeepsWhatItsProviderToldItAndCanTakeNewSettings() {
        let session = IDERunSession(configurationID: UUID(), title: "Old", providerID: "fake", payload: "settings v1")
        XCTAssertEqual(session.payload as? String, "settings v1")
        session.update(title: "New", payload: "settings v2")
        XCTAssertEqual(session.title, "New")
        XCTAssertEqual(session.payload as? String, "settings v2")
    }

    func testAJavaLaunchBecomesAGenericOneFieldForField() {
        let java = JavaProcessLaunch(
            executable: URL(fileURLWithPath: "/jdk/bin/java"), arguments: ["-cp", "a", "Main"],
            workingDirectory: URL(fileURLWithPath: "/work"), environment: ["A": "1"],
            redirectInput: URL(fileURLWithPath: "/in.txt"), temporaryFiles: [URL(fileURLWithPath: "/tmp/args")],
            displayCommand: "java -cp a Main"
        )
        let launch = IDEProcessLaunch(java)
        XCTAssertEqual(launch.executable.path, "/jdk/bin/java")
        XCTAssertEqual(launch.arguments, ["-cp", "a", "Main"])
        XCTAssertEqual(launch.workingDirectory.path, "/work")
        XCTAssertEqual(launch.environment, ["A": "1"])
        XCTAssertEqual(launch.redirectInput?.path, "/in.txt")
        XCTAssertEqual(launch.temporaryFiles.map(\.path), ["/tmp/args"])
        XCTAssertEqual(launch.displayCommand, "java -cp a Main")
    }

    func testAProgramThatCannotBeStartedNamesTheExecutable() async {
        let session = IDERunSession(configurationID: UUID(), title: "Missing", providerID: "fake")
        session.start(IDEProcessLaunch(
            executable: URL(fileURLWithPath: "/no/such/bin/tool"), arguments: [],
            workingDirectory: URL(fileURLWithPath: "/"), environment: [:]
        ))
        XCTAssertFalse(session.isActive)
        XCTAssertTrue(session.statusText.hasPrefix("Could not start tool:"), session.statusText)
    }

    // MARK: - The Java provider

    func testTheJavaModuleContributesTheJavaRunProvider() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        XCTAssertTrue(workspace.runProviders.provider(forLanguage: "java") === workspace.javaRun)
        XCTAssertEqual(workspace.javaRun.id, "java")
        XCTAssertNil(workspace.runProviders.provider(forLanguage: "markdown"))
        XCTAssertNil(workspace.runProviders.provider(forLanguage: nil))
    }

    func testAJavaFileRunsWhenItHasAMainAndSomewhereToRunIt() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        let java = workspace.javaRun
        let source = "class App { public static void main(String[] args) {} }"
        func document(_ text: String, file: String? = "App.java", language: String? = "java") -> IDERunDocument {
            IDERunDocument(url: file.map { URL(fileURLWithPath: "/proj/\($0)") }, languageIdentifier: language, text: text)
        }
        XCTAssertTrue(java.canRun(document(source)))
        XCTAssertFalse(java.canRun(document("class App {}")), "No main, nothing to run")
        XCTAssertFalse(java.canRun(document(source, language: "markdown")))
        XCTAssertFalse(java.canRun(document(source, file: nil)), "An untitled buffer is not a file `java` can launch")
        XCTAssertFalse(java.canDebug(fileURL: nil), "Debugging needs a Gradle project")
        XCTAssertEqual(java.runHelp(fileURL: nil), "Run Java file")
        XCTAssertEqual(java.debugHelp(fileURL: nil, canRun: true), "Debugging needs a Gradle project")
    }

    func testTheRunnablePlacesOfAJavaFileAreItsMains() async {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        let source = """
        package demo;
        public class Tool {
            public static void main(String[] args) {}
        }
        class Other {
            public static void main(String[] args) {}
        }
        """
        let document = IDERunDocument(url: URL(fileURLWithPath: "/proj/Tool.java"), languageIdentifier: "java", text: source)
        let places = await workspace.javaRun.runnableLocations(in: document)
        XCTAssertEqual(places.map(\.kind), [.entryPoint, .entryPoint])
        XCTAssertEqual(places.map(\.line), [3, 6])
        XCTAssertEqual(places.map(\.title), ["Tool.main()", "Other.main()"])

        let none = await workspace.javaRun.runnableLocations(in: IDERunDocument(url: nil, languageIdentifier: "java", text: source))
        XCTAssertTrue(none.isEmpty, "Without a file there is nothing to launch")
        let notJava = await workspace.javaRun.runnableLocations(
            in: IDERunDocument(url: URL(fileURLWithPath: "/x.md"), languageIdentifier: "markdown", text: source)
        )
        XCTAssertTrue(notJava.isEmpty)
    }

    func testAFileWithoutARunProviderRepeatsNothingAndDoesNotCrash() async {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        XCTAssertNil(workspace.activeRunProvider)
        workspace.runActiveJava()
        workspace.debugActiveJava()
        workspace.stopRunning()
        XCTAssertFalse(workspace.isRunActive)
    }

    // MARK: - Language lifecycle reaches Java

    func testTheWindowsFolderReachesJavaThroughTheLanguageRegistry() {
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertNil(workspace.javaSupport.jdk.projectRoot)
        workspace.languages.projectDidChange(root: folder)
        XCTAssertEqual(workspace.javaSupport.jdk.projectRoot, folder, "Synchronous: Java has retargeted by the time the call returns")
        workspace.languages.projectDidChange(root: nil)
        XCTAssertNil(workspace.javaSupport.jdk.projectRoot)
    }

    // MARK: - Nothing keeps the window alive

    func testProjectSystemsAndRunProvidersDoNotRetainTheWorkspace() async throws {
        weak var weakWorkspace: IDEWorkspace?
        do {
            let workspace = IDEWorkspace()
            weakWorkspace = workspace
            workspace.bootstrap()
            // Make the providers, wire the window to them, and use them the way a session does.
            _ = workspace.javaRun
            _ = workspace.projectSystems.active
            workspace.languages.projectDidChange(root: nil)
            workspace.projectSystems.projectDidChange(root: nil)
            workspace.stopRunning()
            workspace.teardown()
        }
        for _ in 0..<50 where weakWorkspace != nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(weakWorkspace, "a run provider, project system or language service holds the closed window's workspace")
    }
}
