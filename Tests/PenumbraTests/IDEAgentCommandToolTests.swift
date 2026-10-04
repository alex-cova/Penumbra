import AgentKit
import Foundation
import JavaIntelligence
import XCTest
@testable import Umbra

// MARK: - Fixtures captured from real Gradle 9.6.1 runs (paths replaced with /proj)

private enum GradleFixture {
    static let compileError = """
    > Task :compileJava FAILED
    /proj/src/main/java/demo/Calc.java:5: error: ';' expected
            return a - b
                        ^
    1 error
    FAILURE: Build failed with an exception.

    * What went wrong:
    Execution failed for task ':compileJava' (registered by plugin class 'org.gradle.api.plugins.JavaBasePlugin').
    > Compilation failed; see the compiler output below.
      /proj/src/main/java/demo/Calc.java:5: error: ';' expected
              return a - b
                          ^
      1 error

    * Try:
    > Check your code and dependencies to fix the compilation error(s)
    > Run with --scan to get full insights from a Build Scan (powered by Develocity).

    BUILD FAILED in 269ms
    """

    static let testFailure = """
    > Task :test FAILED

    CalcTest > addsTwoNumbers FAILED
        java.lang.AssertionError at CalcTest.java:8

    1 test completed, 1 failed

    FAILURE: Build failed with an exception.

    * What went wrong:
    Execution failed for task ':test'.
    > There were failing tests. See the report at: file:///proj/build/reports/tests/test/index.html

    * Try:
    > Run with --scan to get full insights from a Build Scan (powered by Develocity).

    BUILD FAILED in 534ms
    """

    static let configurationFailure = """
    FAILURE: Build failed with an exception.

    * Where:
    Build file '/proj/build.gradle' line: 3

    * What went wrong:
    A problem occurred evaluating root project 'calc'.
    > Could not find method bogus() for arguments [] on root project 'calc'.

    * Try:
    > Run with --stacktrace option to get the stack trace.

    BUILD FAILED in 1s
    """

    static let failingXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <testsuite name="demo.CalcTest" tests="2" skipped="0" failures="1" errors="0" timestamp="2026-10-04T04:48:48.735Z" hostname="h" time="0.004">
      <properties/>
      <testcase name="addsTwoNumbers" classname="demo.CalcTest" time="0.002">
        <failure message="java.lang.AssertionError: expected:&lt;5&gt; but was:&lt;-1&gt;" type="java.lang.AssertionError">java.lang.AssertionError: expected:&lt;5&gt; but was:&lt;-1&gt;
    \tat org.junit.Assert.fail(Assert.java:89)
    \tat org.junit.Assert.assertEquals(Assert.java:647)
    \tat demo.CalcTest.addsTwoNumbers(CalcTest.java:8)
    \tat java.base/jdk.internal.reflect.DirectMethodHandleAccessor.invoke(DirectMethodHandleAccessor.java:104)
    \tat org.gradle.api.internal.tasks.testing.junit.JUnitTestExecutor.runRequest(JUnitTestExecutor.java:175)
    </failure>
      </testcase>
      <testcase name="subtracts" classname="demo.CalcTest" time="0.001"/>
      <system-out><![CDATA[]]></system-out>
      <system-err><![CDATA[]]></system-err>
    </testsuite>
    """
}

final class IDEGradleSummaryTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/proj")

    private func input(_ commandLine: String = "gradle test", exit: Int32? = 1, stdout: String = "", stderr: String = "") -> IDEGradleSummary.Input {
        IDEGradleSummary.Input(commandLine: commandLine, projectRoot: root, exitCode: exit, stdout: stdout, stderr: stderr, duration: 3.25)
    }

    func testACompileErrorIsListedOnceWithAProjectRelativeLocation() {
        let summary = IDEGradleSummary.make(input("gradle classes", stdout: GradleFixture.compileError))
        XCTAssertTrue(summary.hasPrefix("`gradle classes` failed (exit code 1) in 3.2 s."), summary)
        XCTAssertTrue(summary.contains("Compiler errors (1):"))
        XCTAssertTrue(summary.contains("  src/main/java/demo/Calc.java:5: ';' expected"), summary)
        XCTAssertEqual(summary.components(separatedBy: "';' expected").count - 1, 1, "Gradle prints the error twice; the model sees it once")
        XCTAssertFalse(summary.contains("Last lines of output"), "no log tail when the cause was found")
    }

    func testFailedTestsShowNameMessageAndTheProjectsFrames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gradle-xml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try GradleFixture.failingXML.write(to: directory.appendingPathComponent("TEST-demo.CalcTest.xml"), atomically: true, encoding: .utf8)
        var run = input(stdout: GradleFixture.testFailure)
        run.tests = JUnitXMLReportParser.parseReports(in: [directory], projectRoot: root)

        let summary = IDEGradleSummary.make(run)
        XCTAssertTrue(summary.contains("Tests: 2 run, 1 failed, 0 skipped."), summary)
        XCTAssertTrue(summary.contains("  FAILED demo.CalcTest > addsTwoNumbers"))
        XCTAssertTrue(summary.contains("    java.lang.AssertionError: expected:<5> but was:<-1>"))
        XCTAssertTrue(summary.contains("    at demo.CalcTest.addsTwoNumbers(CalcTest.java:8)"))
        XCTAssertFalse(summary.contains("org.junit.Assert"), "framework frames are noise")
        XCTAssertFalse(summary.contains("jdk.internal"))
        XCTAssertFalse(summary.contains("org.gradle"), "Gradle's own frames are noise too")
        XCTAssertFalse(summary.contains("Gradle reports:"), "the test failure is the story, not Gradle's wrapper sentence")
    }

    func testAConfigurationFailureReportsWhatWentWrong() {
        let summary = IDEGradleSummary.make(input(stderr: GradleFixture.configurationFailure))
        XCTAssertTrue(summary.contains("Gradle reports: A problem occurred evaluating root project 'calc'. > Could not find method bogus()"), summary)
    }

    func testWhenNothingStructuredIsFoundTheEndOfTheLogIsShown() {
        let log = (1...100).map { "log line \($0)" }.joined(separator: "\n")
        let summary = IDEGradleSummary.make(input(stdout: log))
        XCTAssertTrue(summary.contains("Last lines of output:"))
        XCTAssertTrue(summary.contains("log line 100"))
        XCTAssertFalse(summary.contains("log line 50\n"), "only the tail, not the log")
    }

    func testSuccessTimeoutAndCancellationHaveTheirOwnVerdicts() {
        XCTAssertTrue(IDEGradleSummary.make(input("gradle build", exit: 0, stdout: "BUILD SUCCESSFUL")).hasPrefix("`gradle build` succeeded in 3.2 s."))
        var timeout = input(exit: nil); timeout.timedOut = true
        XCTAssertTrue(IDEGradleSummary.make(timeout).contains("timed out after 3.2 s and was stopped"))
        var cancelled = input(exit: nil); cancelled.cancelled = true
        XCTAssertTrue(IDEGradleSummary.make(cancelled).contains("was cancelled"))
    }

    func testLongErrorAndFailureListsAreCapped() {
        let errors = (1...30).map { "/proj/A.java:\($0): error: boom \($0)\n  x\n  ^" }.joined(separator: "\n") + "\n30 errors"
        let summary = IDEGradleSummary.make(input(stdout: errors))
        XCTAssertTrue(summary.contains("Compiler errors (30):"))
        XCTAssertTrue(summary.contains("[15 more not shown]"))
    }

    func testOnlyReportDirectoriesWrittenDuringTheRunAreRead() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("gradle-reports-\(UUID().uuidString)")
        let stale = project.appendingPathComponent("old/build/test-results/test")
        let fresh = project.appendingPathComponent("new/build/test-results/test")
        for directory in [stale, fresh] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: project) }
        let oldFile = stale.appendingPathComponent("TEST-a.xml")
        try "<testsuite/>".write(to: oldFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: oldFile.path)
        try "<testsuite/>".write(to: fresh.appendingPathComponent("TEST-b.xml"), atomically: true, encoding: .utf8)

        let found = IDEGradleSummary.freshTestReportDirectories(under: project, since: Date().addingTimeInterval(-60))
        XCTAssertEqual(found.map { $0.resolvingSymlinksInPath().path }, [fresh.resolvingSymlinksInPath().path])
    }
}

final class IDEAgentBufferTriageTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/proj")

    func testOnlyABufferStillHoldingTheAgentsTextIsTheAgents() {
        let agentText = "class A { int x = 2; }"
        let result = IDEAgentBufferTriage.classify(
            unsaved: [
                "/proj/src/A.java": agentText,
                "/proj/src/B.java": "the user's own edits",
                "/proj/src/C.java": "agent wrote this, then the user typed more",
                "/elsewhere/D.java": "outside the project",
            ],
            root: root,
            written: [
                "src/A.java": CheckpointLog.hash(of: agentText),
                "src/C.java": CheckpointLog.hash(of: "agent wrote this"),
            ])
        XCTAssertEqual(result.agentOwned, ["src/A.java"])
        XCTAssertEqual(result.userOwned, ["src/B.java", "src/C.java"])
    }

    func testNothingUnsavedMeansNothingToDo() {
        XCTAssertEqual(IDEAgentBufferTriage.classify(unsaved: [:], root: root, written: ["a": 1]), .init())
    }
}

final class IDEAgentLiveOutputTests: XCTestCase {
    func testKeepsTheTailOnWholeLinesAndSaysSo() {
        let lines = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let kept = IDEAgentLiveOutput.append("", lines, limit: 200)
        XCTAssertTrue(kept.hasPrefix("[… earlier output not shown …]\nline "))
        XCTAssertTrue(kept.hasSuffix("line 100"))
        XCTAssertLessThan(kept.count, 260)
        XCTAssertEqual(IDEAgentLiveOutput.append("a\n", "b\n", limit: 200), "a\nb\n")
    }
}

@MainActor
final class IDEAgentSettingsEnvironmentTests: XCTestCase {
    func testExtraEnvironmentLinesAreParsed() {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.commandEnvironmentText = "# comment\nFOO=bar\n  PATH = /opt/x/bin \nBAD LINE\n=novalue\nURL=https://a.b/?c=d\n"
        XCTAssertEqual(settings.commandEnvironment, ["FOO": "bar", "PATH": "/opt/x/bin", "URL": "https://a.b/?c=d"])
    }
}

// MARK: - Tools through a fake host

@MainActor
final class CommandHost: IDEAgentHost {
    var agentProjectRoot: URL?
    var unsaved: [String: String] = [:]
    var saved: [String] = []
    var problems: [IDEAgentProblem] = []
    var fresh = IDEAgentFreshProblems()
    var freshRequests: [[String]] = []
    var gradleOutcome: IDEGradleRunOutcome = .notStarted("not configured")
    var gradleRequests: [(tasks: [String], options: [String])] = []
    var javaHome: URL?
    var isGradle = false
    /// When set, `agentRunGradle` runs this real executable (offline) instead of returning `gradleOutcome`.
    var gradleExecutable: String?

    init(root: URL) { agentProjectRoot = root }

    func agentUnsavedBuffers() -> [String: String] { unsaved }
    func agentEditorContext() -> String { "[Editor state]" }
    func agentProblems() -> [IDEAgentProblem] { problems }
    func agentReplaceText(relativePath: String, expecting: String, edits: [AgentTextEdit]) async throws {
        let url = agentProjectRoot!.appendingPathComponent(relativePath)
        try AgentTextEdit.apply(edits, to: expecting).write(to: url, atomically: true, encoding: .utf8)
    }
    func agentCreateFile(relativePath: String, contents: String) async throws {
        let url = agentProjectRoot!.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    func agentTrashFile(relativePath: String) async throws {
        try FileManager.default.removeItem(at: agentProjectRoot!.appendingPathComponent(relativePath))
    }
    func agentShowDiff(relativePath: String, original: String?) {}
    func agentCommandEnvironment() async -> [String: String] { AgentCommandEnvironment.make(javaHome: javaHome) }
    func agentSaveBuffers(relativePaths: [String]) async {
        saved += relativePaths
        for path in relativePaths { unsaved.removeValue(forKey: agentProjectRoot!.appendingPathComponent(path).path) }
    }
    var agentIsGradleProject: Bool { isGradle }
    func agentRunGradle(tasks: [String], options: [String], timeout: TimeInterval) async -> IDEGradleRunOutcome {
        gradleRequests.append((tasks, options))
        guard let gradleExecutable, let root = agentProjectRoot else { return gradleOutcome }
        let command = ([gradleExecutable] + tasks + options + ["--console=plain", "--offline", "--no-configuration-cache"])
            .map { "'\($0)'" }.joined(separator: " ")
        var environment = AgentCommandEnvironment.make(javaHome: javaHome)
        environment["PATH"] = (URL(fileURLWithPath: gradleExecutable).deletingLastPathComponent().path) + ":" + (environment["PATH"] ?? "")
        let result = try? await AgentCommandRunner.run(
            AgentCommandSpec(command: command, workingDirectory: root, environment: environment, timeout: timeout), onOutput: { _ in })
        guard let result else { return .failed("could not start gradle") }
        return .finished(GradleCommandResult(exitCode: result.exitCode ?? 1, stdout: result.output, stderr: ""))
    }
    func agentCancelGradle() {}
    func agentFreshProblems(relativePaths: [String]) async -> IDEAgentFreshProblems {
        freshRequests.append(relativePaths)
        return fresh
    }
}

@MainActor
final class IDEAgentCommandToolTests: XCTestCase {
    private var project: URL!
    private var host: CommandHost!

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-tools-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        host = CommandHost(root: project)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: project)
    }

    private func support() -> IDEAgentCommandSupport {
        IDEAgentCommandSupport(root: project, box: IDEAgentHostBox(host))
    }

    private func context(scope: CheckpointScope? = nil) -> ToolContext {
        ToolContext(workspace: DiskAgentWorkspace(root: project), ledger: ReadLedger(), callID: "c", checkpoint: scope)
    }

    func testTheApprovalCardNamesTheCommandWhereWhyAndWarnings() async throws {
        let tool = IDERunCommandTool(support: support())
        let arguments = try ToolArguments(json: #"{"command":"sudo make install","reason":"to install the tool"}"#)
        let request = await tool.approvalRequest(for: arguments, context: context())
        XCTAssertEqual(request?.command, "sudo make install")
        XCTAssertEqual(request?.workingDirectory, project.path)
        XCTAssertEqual(request?.reason, "to install the tool")
        XCTAssertEqual(request?.editableArgument, "command")
        XCTAssertEqual(request?.warnings, ["Runs with administrator rights (sudo)."])
        XCTAssertEqual(tool.risk, .command)
    }

    func testTheUsersOwnUnsavedFilesAreNamedAndNeverSaved() async throws {
        let log = CheckpointLog()
        let run = await log.beginRun(label: "x")
        let agentText = "agent text"
        await log.willChange(run: run, path: "A.java", original: "old")
        await log.didChange(run: run, path: "A.java", written: agentText)
        host.unsaved = [
            project.appendingPathComponent("A.java").path: agentText,
            project.appendingPathComponent("Mine.java").path: "my own unsaved work",
        ]
        let scope = CheckpointScope(log: log, run: run)
        let tool = IDERunCommandTool(support: support())

        let request = await tool.approvalRequest(for: try ToolArguments(json: #"{"command":"ls","reason":"r"}"#), context: context(scope: scope))
        XCTAssertEqual(request?.notes.count, 2)
        XCTAssertTrue(request?.notes.first?.contains("Saves the files the agent changed first: A.java") == true)
        XCTAssertTrue(request?.notes.last?.contains("unsaved changes in Mine.java") == true)

        _ = try await tool.run(try ToolArguments(json: #"{"command":"echo hi","reason":"r"}"#), context: context(scope: scope))
        XCTAssertEqual(host.saved, ["A.java"], "the agent's buffer is saved before the command, the user's is not")
    }

    func testARunReportsOutputExitCodeAndStreamsProgress() async throws {
        let tool = IDERunCommandTool(support: support())
        let chunks = LockedStrings()
        let ctx = ToolContext(
            workspace: DiskAgentWorkspace(root: project), ledger: ReadLedger(), callID: "c", progress: { chunks.append($0) })
        let output = try await tool.run(try ToolArguments(json: #"{"command":"echo hello; echo oops 1>&2; exit 3","reason":"r"}"#), context: ctx)
        XCTAssertTrue(output.hasPrefix("$ echo hello; echo oops 1>&2; exit 3\n"))
        XCTAssertTrue(output.contains("hello") && output.contains("oops"))
        XCTAssertTrue(output.contains("[exit code 3 after "))
        XCTAssertTrue(chunks.joined.contains("hello"))
    }

    func testTimeoutsAndEmptyOutputAndLongOutputAreFormatted() {
        let timeout = IDERunCommandTool.format(
            command: "sleep 9", result: AgentCommandResult(exitCode: nil, signal: 15, output: "", omittedBytes: 0, timedOut: true, cancelled: false, duration: 5),
            timeout: 5)
        XCTAssertTrue(timeout.contains("(no output)") && timeout.contains("[timed out after 5 s and was killed, with everything it started]"))
        let long = String(repeating: "x\n", count: 50_000)
        let truncated = IDERunCommandTool.format(
            command: "big", result: AgentCommandResult(exitCode: 0, signal: nil, output: long, omittedBytes: 0, timedOut: false, cancelled: false, duration: 1),
            timeout: 120)
        XCTAssertLessThan(truncated.count, 25_000)
        XCTAssertTrue(truncated.contains("characters omitted from the middle"))
    }

    func testEmptyCommandsAreRejectedAndALaunchFailureIsAnError() async throws {
        let tool = IDERunCommandTool(support: support())
        let empty = await tool.execute(argumentsJSON: #"{"command":"  ","reason":"r"}"#, context: context())
        XCTAssertEqual(empty, .error("The command is empty."))
        try FileManager.default.removeItem(at: project)
        let missing = await tool.execute(argumentsJSON: #"{"command":"ls","reason":"r"}"#, context: context())
        XCTAssertTrue(missing.isError)
    }

    func testRunTestsBuildsTheGradleTaskAndFilters() async throws {
        host.gradleOutcome = .finished(GradleCommandResult(exitCode: 0, stdout: "BUILD SUCCESSFUL", stderr: ""))
        let tool = IDERunTestsTool(support: support())
        let arguments = try ToolArguments(json: #"{"tests":["demo.CalcTest","FooTest.bar"],"module":":app","reason":"r"}"#)

        let request = await tool.approvalRequest(for: arguments, context: context())
        XCTAssertEqual(request?.command, "gradle :app:test --tests demo.CalcTest --tests FooTest.bar")
        XCTAssertNil(request?.editableArgument)

        let output = try await tool.run(arguments, context: context())
        XCTAssertEqual(host.gradleRequests.first?.tasks, [":app:test"])
        XCTAssertEqual(host.gradleRequests.first?.options, ["--tests", "demo.CalcTest", "--tests", "FooTest.bar"])
        XCTAssertTrue(output.contains("succeeded"))

        let plain = try ToolArguments(json: #"{"tests":null,"module":null,"reason":"r"}"#)
        _ = try await tool.run(plain, context: context())
        XCTAssertEqual(host.gradleRequests.last?.tasks, ["test"])
    }

    func testGradleRefusalsBecomeOutputsTheModelCanActOn() async throws {
        host.gradleOutcome = .notStarted("The project is not trusted, so its Gradle build scripts were not run.")
        let tool = IDEGradleTool(support: support())
        let output = await tool.execute(argumentsJSON: #"{"tasks":["classes"],"options":null,"reason":"r"}"#, context: context())
        XCTAssertEqual(output, .error("The project is not trusted, so its Gradle build scripts were not run."))
        let none = await tool.execute(argumentsJSON: #"{"tasks":[],"reason":"r"}"#, context: context())
        XCTAssertTrue(none.isError)
    }

    func testGradleSummarizesACompileFailureForTheModel() async throws {
        host.gradleOutcome = .finished(GradleCommandResult(exitCode: 1, stdout: GradleFixture.compileError, stderr: ""))
        let output = try await IDEGradleTool(support: support()).run(
            try ToolArguments(json: #"{"tasks":["classes"],"reason":"r"}"#), context: context())
        XCTAssertTrue(output.contains("`gradle classes` failed (exit code 1)"))
        XCTAssertTrue(output.contains("Compiler errors (1):"))
    }

    func testDiagnosticsAddsFreshCompilerResultsForTheFilesTheRunChanged() async throws {
        let log = CheckpointLog()
        let run = await log.beginRun(label: "x")
        await log.willChange(run: run, path: "src/A.java", original: "old")
        await log.didChange(run: run, path: "src/A.java", written: "new")
        host.problems = [
            IDEAgentProblem(path: "src/A.java", line: 1, severity: "error", source: "javac", message: "STALE: from the text before the edit"),
            IDEAgentProblem(path: "src/B.java", line: 4, severity: "warning", source: "java-inspection", message: "unused"),
        ]
        host.fresh = IDEAgentFreshProblems(problems: [
            IDEAgentProblem(path: "src/A.java", line: 7, severity: "error", source: "javac", message: "cannot find symbol")
        ])
        let box = IDEAgentHostBox(host)
        let tool = IDEDiagnosticsTool(
            problems: { await box.read(default: []) { $0.agentProblems() } },
            fresh: { await box.freshProblems(relativePaths: $0) })

        let output = await tool.execute(argumentsJSON: "{}", context: context(scope: CheckpointScope(log: log, run: run)))
        XCTAssertEqual(host.freshRequests, [["src/A.java"]])
        XCTAssertTrue(output.text.contains("src/A.java:7: error [javac]: cannot find symbol"))
        XCTAssertFalse(output.text.contains("STALE"), "the compiler's answer for the current text replaces its older rows")
        XCTAssertTrue(output.text.contains("src/B.java:4: warning"), "other files keep what the editor knows")
        XCTAssertLessThan(output.text.range(of: "error")!.lowerBound, output.text.range(of: "warning")!.lowerBound, "errors first")
    }

    func testDiagnosticsSaysWhenTheCompilerCouldNotRunInsteadOfClaimingAllClear() async throws {
        host.fresh = IDEAgentFreshProblems(unavailable: "no JDK is configured for this project")
        let box = IDEAgentHostBox(host)
        let tool = IDEDiagnosticsTool(problems: { [] }, fresh: { await box.freshProblems(relativePaths: $0) })
        let output = await tool.execute(argumentsJSON: #"{"path":"src/A.java"}"#, context: context())
        XCTAssertTrue(output.text.contains("No problems reported for src/A.java"))
        XCTAssertTrue(output.text.contains("the compiler could not be run for fresh results (no JDK is configured"))
    }

    func testToolSummariesNameWhatTheCommandsDo() {
        XCTAssertEqual(IDEAgentToolSummary.title(name: "run_command", arguments: #"{"command":"git status"}"#), "run_command  git status")
        XCTAssertEqual(IDEAgentToolSummary.title(name: "gradle", arguments: #"{"tasks":["clean","build"]}"#), "gradle  clean build")
        XCTAssertEqual(IDEAgentToolSummary.title(name: "run_tests", arguments: #"{"module":":app","tests":["FooTest"]}"#), "run_tests  :app FooTest")
    }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ text: String) { lock.withLock { items.append(text) } }
    var joined: String { lock.withLock { items.joined() } }
}
