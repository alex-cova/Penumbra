import AgentKit
import AgentKitMLX
import Foundation
import JavaIntelligence
import LocalModelStore
import XCTest
@testable import Umbra

/// The controller driving real `run_command` calls: the card, the three answers, Stop. The scripted
/// model never sees anything but what the tools return.
@MainActor
final class IDEAgentApprovalFlowTests: XCTestCase {
    private var project: URL!
    private var hosts: [CommandHost] = []

    override func setUpWithError() throws {
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-flow-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: project)
    }

    private func makeController(_ turns: [MockTurn]) -> (IDEAgentController, MockLLMClient) {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let client = MockLLMClient(turns: turns)
        let host = CommandHost(root: project)
        hosts.append(host)
        let controller = IDEAgentController(settings: settings, clientFactory: { _ in client })
        controller.attach(host: host)
        return (controller, client)
    }

    private func command(_ text: String, id: String = "c1") -> MockTurn {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return .toolCalls((id: id, name: "run_command", arguments: #"{"command":"\#(escaped)","reason":"a test"}"#))
    }

    private func waitFor(_ message: String, timeout: Double = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func toolEntry(_ controller: IDEAgentController) -> IDEAgentEntry? {
        controller.entries.first { if case .toolCall = $0.kind { true } else { false } }
    }

    private var marker: URL { project.appendingPathComponent("ran.txt") }

    func testACommandWaitsOnItsCardAndRunsWhenApproved() async throws {
        let (controller, _) = makeController([command("echo hello > ran.txt; echo streamed"), .text("done")])
        controller.draft = "run it"
        controller.send()
        await waitFor("the question appears") { self.toolEntry(controller)?.approval != nil }

        let request = try XCTUnwrap(toolEntry(controller)?.approval)
        XCTAssertEqual(request.command, "echo hello > ran.txt; echo streamed")
        XCTAssertEqual(request.reason, "a test")
        XCTAssertEqual(controller.status, "Waiting for your approval…")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "nothing runs before the answer")

        controller.decide(callID: "c1", .approve)
        await waitFor("the run finishes") { !controller.isRunning }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let entry = try XCTUnwrap(toolEntry(controller))
        XCTAssertNil(entry.approval)
        XCTAssertEqual(entry.approvalOutcome, "Approved")
        XCTAssertTrue(entry.liveOutput.contains("streamed"), "the card kept the live output")
        XCTAssertTrue(entry.output?.text.contains("[exit code 0") == true)
        XCTAssertEqual(controller.entries.last?.text, "done")
    }

    func testDenyingSendsTheNoteBackAndRunsNothing() async throws {
        let (controller, client) = makeController([command("echo nope > ran.txt"), .text("understood")])
        controller.draft = "run it"
        controller.send()
        await waitFor("the question appears") { self.toolEntry(controller)?.approval != nil }
        controller.decide(callID: "c1", .deny(note: "use a dry run first"))
        await waitFor("the run finishes") { !controller.isRunning }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(hosts.last?.commandLines.isEmpty == true, "a denied command does not open a terminal tab")
        XCTAssertEqual(toolEntry(controller)?.approvalOutcome, "Denied")
        let output = try XCTUnwrap(toolEntry(controller)?.output)
        XCTAssertTrue(output.isError && output.text.contains("use a dry run first"))
        // The model got the denial as the tool's output and could answer in light of it.
        let last = client.requests.last?.items.last
        guard case .toolOutput(_, let text)? = last else { return XCTFail("the denial should be the last item the model saw") }
        XCTAssertTrue(text.contains("The user denied this command."))
    }

    func testEditingRunsTheUsersVersionAndTheModelIsTold() async throws {
        let (controller, client) = makeController([command("echo original > ran.txt"), .text("ok")])
        controller.draft = "run it"
        controller.send()
        await waitFor("the question appears") { self.toolEntry(controller)?.approval != nil }
        controller.decide(callID: "c1", .approveEditing("echo edited > ran.txt"))
        await waitFor("the run finishes") { !controller.isRunning }

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "edited\n")
        XCTAssertEqual(toolEntry(controller)?.approvalOutcome, "Edited and approved")
        guard case .toolOutput(_, let text)? = client.requests.last?.items.last else { return XCTFail("missing output") }
        XCTAssertTrue(text.hasPrefix("[The user edited the command before approving it. This ran: echo edited > ran.txt]"))
    }

    func testStopWhileAskedEndsTheRunWithoutRunningAnything() async throws {
        let (controller, _) = makeController([command("echo never > ran.txt")])
        controller.draft = "run it"
        controller.send()
        await waitFor("the question appears") { self.toolEntry(controller)?.approval != nil }
        controller.stop()
        await waitFor("the run stops") { !controller.isRunning }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(toolEntry(controller)?.approval, "the question is withdrawn")
        XCTAssertEqual(controller.entries.last?.text, "Stopped.")
    }

    func testStopKillsARunningCommandAndItsChildren() async throws {
        let (controller, _) = makeController([command("sleep 300 & echo $! > child.pid; wait")])
        controller.draft = "run it"
        controller.send()
        await waitFor("the question appears") { self.toolEntry(controller)?.approval != nil }
        controller.decide(callID: "c1", .approve)
        let pidFile = project.appendingPathComponent("child.pid")
        await waitFor("the child starts") { FileManager.default.fileExists(atPath: pidFile.path) && ((try? String(contentsOf: pidFile, encoding: .utf8))?.count ?? 0) > 1 }
        let pid = pid_t((try String(contentsOf: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(pid, 1)

        controller.stop()
        await waitFor("the run stops") { !controller.isRunning }
        await waitFor("the grandchild is gone", timeout: 8) { kill(pid, 0) != 0 }
    }

    func testACommandWithWarningsShowsThemOnTheCard() async throws {
        let (controller, _) = makeController([command("git reset --hard HEAD~1"), .text("ok")])
        controller.draft = "undo"
        controller.send()
        await waitFor("the question appears") { self.toolEntry(controller)?.approval != nil }
        XCTAssertEqual(toolEntry(controller)?.approval?.warnings, ["Discards uncommitted changes (git reset --hard)."])
        controller.decide(callID: "c1", .deny(note: nil))
        await waitFor("the run finishes") { !controller.isRunning }
    }
}

/// "Make this test pass", end to end on a real Gradle project: the scripted model reads the test,
/// runs it (approved), fixes the code, runs it again, and the run is reverted.
@MainActor
final class IDEAgentGradleFixtureTests: XCTestCase {
    private var project: URL!
    private var host: CommandHost!

    private static func findGradle() -> String? {
        let home = NSHomeDirectory()
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/gradle" }
        candidates += ["\(home)/.sdkman/candidates/gradle/current/bin/gradle", "/opt/homebrew/bin/gradle", "/usr/local/bin/gradle"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func findJavaHome() -> URL? {
        let candidates = [ProcessInfo.processInfo.environment["JAVA_HOME"], "\(NSHomeDirectory())/.sdkman/candidates/java/current"]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0 + "/bin/java") }
            .map { URL(fileURLWithPath: $0) }
    }

    /// JUnit 4 and Hamcrest must already be in Gradle's cache: the test runs offline.
    private static func hasCachedJUnit() -> Bool {
        let cache = "\(NSHomeDirectory())/.gradle/caches/modules-2/files-2.1"
        return FileManager.default.fileExists(atPath: "\(cache)/junit/junit/4.13.2")
            && FileManager.default.fileExists(atPath: "\(cache)/org.hamcrest/hamcrest-core")
    }

    override func setUpWithError() throws {
        guard let gradle = Self.findGradle(), Self.hasCachedJUnit(), let javaHome = Self.findJavaHome() else {
            throw XCTSkip("needs gradle, a JDK (JAVA_HOME or SDKMAN) and JUnit 4.13.2 in ~/.gradle's cache (runs offline)")
        }
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-gradle-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        let files: [String: String] = [
            "settings.gradle": "rootProject.name = 'calc'\n",
            "build.gradle": "plugins { id 'java' }\nrepositories { mavenCentral() }\ndependencies { testImplementation 'junit:junit:4.13.2' }\n",
            "src/main/java/demo/Calc.java": "package demo;\n\npublic class Calc {\n    public static int add(int a, int b) {\n        return a - b;\n    }\n}\n",
            "src/test/java/demo/CalcTest.java": """
            package demo;

            import static org.junit.Assert.assertEquals;
            import org.junit.Test;

            public class CalcTest {
                @Test public void addsTwoNumbers() {
                    assertEquals(5, Calc.add(2, 3));
                }
            }

            """,
        ]
        for (path, text) in files {
            let url = project.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        host = CommandHost(root: project)
        host.isGradle = true
        host.gradleExecutable = gradle
        // The app passes the window's selected JDK; commands don't inherit the app's environment.
        host.javaHome = javaHome
    }

    override func tearDownWithError() throws {
        if let project { try? FileManager.default.removeItem(at: project) }
    }

    private func waitFor(_ message: String, timeout: Double = 120, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), message)
    }

    func testMakeTheFailingTestPass() async throws {
        let client = MockLLMClient(turns: [
            .toolCalls(
                (id: "r1", name: "read_file", arguments: #"{"path":"src/test/java/demo/CalcTest.java"}"#),
                (id: "r2", name: "read_file", arguments: #"{"path":"src/main/java/demo/Calc.java"}"#)),
            .toolCalls((id: "t1", name: "run_tests", arguments: #"{"tests":["demo.CalcTest"],"reason":"see why it fails"}"#)),
            .toolCalls((id: "e1", name: "edit_file", arguments: #"{"path":"src/main/java/demo/Calc.java","old_string":"return a - b;","new_string":"return a + b;"}"#)),
            .toolCalls((id: "t2", name: "run_tests", arguments: #"{"tests":["demo.CalcTest"],"reason":"confirm the fix"}"#)),
            .text("Fixed: add() subtracted. The test passes now."),
        ])
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let controller = IDEAgentController(settings: settings, clientFactory: { _ in client })
        controller.attach(host: host)

        controller.draft = "make CalcTest pass"
        controller.send()
        // Each run_tests asks first; approve whatever is asked, as the user would.
        var approved = 0
        let deadline = Date().addingTimeInterval(180)
        while controller.isRunning, Date() < deadline {
            if let pending = controller.entries.first(where: { $0.approval != nil }), let request = pending.approval {
                XCTAssertEqual(request.toolName, "run_tests")
                XCTAssertTrue(request.command.hasPrefix("gradle test --tests demo.CalcTest"), request.command)
                controller.decide(callID: request.callID, .approve)
                approved += 1
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(controller.isRunning, "the run should have finished")
        XCTAssertEqual(approved, 2, "both test runs asked first")

        let outputs = controller.entries.compactMap { entry -> (String, String)? in
            guard case .toolCall(let name) = entry.kind, let output = entry.output else { return nil }
            return (name, output.text)
        }
        let runs = outputs.filter { $0.0 == "run_tests" }.map(\.1)
        XCTAssertEqual(runs.count, 2)
        XCTAssertTrue(runs[0].contains("failed (exit code 1)"), runs[0])
        XCTAssertTrue(runs[0].contains("FAILED demo.CalcTest > addsTwoNumbers"), runs[0])
        XCTAssertTrue(runs[0].contains("expected:<5> but was:<-1>"), runs[0])
        XCTAssertTrue(runs[0].contains("at demo.CalcTest.addsTwoNumbers(CalcTest.java:8)"), runs[0])
        XCTAssertFalse(runs[0].contains("org.junit"), "the model gets a summary, not the log")
        XCTAssertTrue(runs[1].contains("succeeded"), runs[1])
        XCTAssertTrue(runs[1].contains("Tests: 1 run, 0 failed"), runs[1])

        XCTAssertEqual(
            try String(contentsOf: project.appendingPathComponent("src/main/java/demo/Calc.java"), encoding: .utf8).contains("return a + b;"), true)
        XCTAssertEqual(controller.entries.last { $0.kind == .assistant }?.text, "Fixed: add() subtracted. The test passes now.")

        // The run's one change reverts, and the bug is back.
        let summary = try XCTUnwrap(controller.entries.last { $0.kind == .changes })
        XCTAssertEqual(summary.fileChanges.map(\.path), ["src/main/java/demo/Calc.java"])
        controller.revert(entryID: summary.id)
        await waitFor("the revert finishes", timeout: 10) { controller.entries.last { $0.kind == .changes }?.isReverted == true }
        XCTAssertTrue(
            try String(contentsOf: project.appendingPathComponent("src/main/java/demo/Calc.java"), encoding: .utf8).contains("return a - b;"))
    }

    /// Opt-in, with a real model: `UMBRA_AGENT_OLLAMA_MODEL=qwen-fixed:latest swift test --filter testMakeTheFailingTestPassWithALocalModel`.
    /// Not deterministic. It checks the outcome, not the route, and writes the transcript to
    /// `UMBRA_AGENT_TRANSCRIPT` (default: the temp folder) so a failure can be read.
    func testMakeTheFailingTestPassWithALocalModel() async throws {
        guard let model = ProcessInfo.processInfo.environment["UMBRA_AGENT_OLLAMA_MODEL"] else {
            throw XCTSkip("set UMBRA_AGENT_OLLAMA_MODEL to run this against a real local model")
        }
        let testFile = project.appendingPathComponent("src/test/java/demo/CalcTest.java")
        let testBefore = try String(contentsOf: testFile, encoding: .utf8)

        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.provider = .ollama
        settings.model = model
        let controller = IDEAgentController(
            settings: settings,
            clientFactory: { _ in OllamaClient(contextLength: 16_384, supportsThinking: false) })
        controller.attach(host: host)

        controller.draft = "The test demo.CalcTest fails. Find out why and fix the production code so it passes. Do not change the test. Use your tools, and run the tests to confirm."
        controller.send()

        var approvals: [String] = []
        let deadline = Date().addingTimeInterval(900)
        while controller.isRunning, Date() < deadline {
            if let request = controller.entries.first(where: { $0.approval != nil })?.approval {
                approvals.append(request.command)
                controller.decide(callID: request.callID, .approve)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if controller.isRunning { controller.stop() }

        // The transcript, for reading when the model does something unexpected.
        var log = "model: \(model)\ntokens: \(controller.usage.inputTokens) in, \(controller.usage.outputTokens) out\napprovals: \(approvals)\n\n"
        for entry in controller.entries {
            switch entry.kind {
            case .user: log += "USER: \(entry.text)\n"
            case .assistant: log += "ASSISTANT: \(entry.text)\n"
            case .toolCall(let name): log += "TOOL \(name) \(entry.text)\n   -> \((entry.output?.text ?? "").prefix(600))\n"
            case .notice, .error: log += "NOTICE: \(entry.text)\n"
            case .changes: log += "CHANGES: \(entry.fileChanges.map(\.path))\n"
            }
        }
        let path = ProcessInfo.processInfo.environment["UMBRA_AGENT_TRANSCRIPT"] ?? NSTemporaryDirectory() + "agent-ollama-transcript.txt"
        try? log.write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertFalse(controller.isRunning, "the run should have ended on its own")
        XCTAssertEqual(try String(contentsOf: testFile, encoding: .utf8), testBefore, "the test itself must not be changed")
        // Judge by running the project's tests ourselves, not by what the model says.
        host.gradleRequests = []
        let outcome = await host.agentRunGradle(tasks: ["test"], options: ["--tests", "demo.CalcTest"], timeout: 120)
        guard case .finished(let result) = outcome else { return XCTFail("gradle did not finish: \(outcome)") }
        XCTAssertEqual(result.exitCode, 0, "CalcTest should pass after the agent's fix. Transcript: \(path)")
    }

    /// Opt-in, with a model running on this Mac's GPU through MLX:
    /// `UMBRA_AGENT_MLX_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit swift test --filter testMakeTheFailingTestPassWithAnOnDeviceModel`.
    /// The model must already be in `~/Library/Caches/AgentKitMLXTests/Models` (the AgentKitMLX smoke
    /// tests put it there). Not deterministic: it checks the outcome and writes the transcript.
    func testMakeTheFailingTestPassWithAnOnDeviceModel() async throws {
        guard let modelID = ProcessInfo.processInfo.environment["UMBRA_AGENT_MLX_MODEL"] else {
            throw XCTSkip("set UMBRA_AGENT_MLX_MODEL to run this against an on-device model")
        }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentKitMLXTests/Models")
        let installed = LocalModelCatalog(paths: LocalModelPaths(root: cache)).installed()
        guard installed.contains(where: { $0.id == modelID }) else { throw XCTSkip("\(modelID) is not in \(cache.path)") }
        let testFile = project.appendingPathComponent("src/test/java/demo/CalcTest.java")
        let testBefore = try String(contentsOf: testFile, encoding: .utf8)

        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore(),
            installedModels: { installed })
        settings.provider = .mlx
        settings.model = modelID
        let controller = IDEAgentController(settings: settings)   // the real client factory: MLXLLMClient
        controller.attach(host: host)

        controller.draft = "The test demo.CalcTest fails. Find out why and fix the production code so it passes. Do not change the test. Use your tools, and run the tests to confirm."
        controller.send()

        var approvals: [String] = []
        let deadline = Date().addingTimeInterval(900)
        while controller.isRunning, Date() < deadline {
            if let request = controller.entries.first(where: { $0.approval != nil })?.approval {
                approvals.append(request.command)
                controller.decide(callID: request.callID, .approve)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if controller.isRunning { controller.stop() }

        var log = "model: \(modelID)\ntokens: \(controller.usage.inputTokens) in (\(controller.usage.cachedInputTokens) from the KV cache), \(controller.usage.outputTokens) out\napprovals: \(approvals)\n\n"
        for entry in controller.entries {
            switch entry.kind {
            case .user: log += "USER: \(entry.text)\n"
            case .assistant: log += "ASSISTANT: \(entry.text)\n"
            case .toolCall(let name): log += "TOOL \(name) \(entry.text)\n   -> \((entry.output?.text ?? "").prefix(500))\n"
            case .notice, .error: log += "NOTICE: \(entry.text)\n"
            case .changes: log += "CHANGES: \(entry.fileChanges.map(\.path))\n"
            }
        }
        let path = ProcessInfo.processInfo.environment["UMBRA_AGENT_TRANSCRIPT"] ?? NSTemporaryDirectory() + "agent-mlx-transcript.txt"
        try? log.write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(try String(contentsOf: testFile, encoding: .utf8), testBefore, "the test itself must not be changed")
        let outcome = await host.agentRunGradle(tasks: ["test"], options: ["--tests", "demo.CalcTest"], timeout: 120)
        guard case .finished(let result) = outcome else { return XCTFail("gradle did not finish: \(outcome)") }
        XCTAssertEqual(result.exitCode, 0, "CalcTest should pass after the agent's fix. Transcript: \(path)")
        XCTAssertGreaterThan(controller.usage.cachedInputTokens, 0, "later turns should be served from the KV cache. Transcript: \(path)")
    }

    /// Opt-in, real model: a change that spans two files, which the prompt asks to be done with
    /// `apply_patch`. Judged by running the tests, which must now include the new one.
    func testAMultiFileChangeWithApplyPatchAndALocalModel() async throws {
        guard let model = ProcessInfo.processInfo.environment["UMBRA_AGENT_OLLAMA_MODEL"] else {
            throw XCTSkip("set UMBRA_AGENT_OLLAMA_MODEL to run this against a real local model")
        }
        // Start from a correct Calc, so the only work is the addition.
        let calc = project.appendingPathComponent("src/main/java/demo/Calc.java")
        try String(contentsOf: calc, encoding: .utf8).replacingOccurrences(of: "a - b", with: "a + b").write(to: calc, atomically: true, encoding: .utf8)

        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.provider = .ollama
        settings.model = model
        let controller = IDEAgentController(
            settings: settings, clientFactory: { _ in OllamaClient(contextLength: 16_384, supportsThinking: false) })
        controller.attach(host: host)

        controller.draft = "Add a static method `sub(int a, int b)` to demo.Calc that returns a - b, and add a JUnit test `subtractsTwoNumbers` to demo.CalcTest asserting sub(5, 3) == 2. Make both changes with ONE apply_patch call (a unified diff touching both files), then run the tests."
        controller.send()

        var approvals: [String] = []
        let deadline = Date().addingTimeInterval(900)
        while controller.isRunning, Date() < deadline {
            if let request = controller.entries.first(where: { $0.approval != nil })?.approval {
                approvals.append(request.command)
                controller.decide(callID: request.callID, .approve)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if controller.isRunning { controller.stop() }

        var log = "model: \(model)\napprovals: \(approvals)\n\n"
        for entry in controller.entries {
            switch entry.kind {
            case .user: log += "USER: \(entry.text)\n"
            case .assistant: log += "ASSISTANT: \(entry.text)\n"
            case .toolCall(let name): log += "TOOL \(name) \(entry.text)\n   -> \((entry.output?.text ?? "").prefix(500))\n"
            case .notice, .error: log += "NOTICE: \(entry.text)\n"
            case .changes: log += "CHANGES: \(entry.fileChanges.map(\.path))\n"
            }
        }
        let path = ProcessInfo.processInfo.environment["UMBRA_AGENT_TRANSCRIPT"] ?? NSTemporaryDirectory() + "agent-ollama-patch-transcript.txt"
        try? log.write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertFalse(controller.isRunning)
        let outcome = await host.agentRunGradle(tasks: ["test"], options: ["--tests", "demo.CalcTest"], timeout: 120)
        guard case .finished(let result) = outcome else { return XCTFail("gradle did not finish: \(outcome)") }
        XCTAssertEqual(result.exitCode, 0, "Transcript: \(path)")
        let test = try String(contentsOf: project.appendingPathComponent("src/test/java/demo/CalcTest.java"), encoding: .utf8)
        XCTAssertTrue(test.contains("subtractsTwoNumbers"), "the new test should exist. Transcript: \(path)")
        XCTAssertTrue(controller.entries.contains { if case .toolCall("apply_patch") = $0.kind { true } else { false } }, "the model was asked to use apply_patch")
    }

    func testACompileErrorComesBackAsALocatedErrorNotALog() async throws {
        let client = MockLLMClient(turns: [
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"src/main/java/demo/Calc.java"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"src/main/java/demo/Calc.java","old_string":"return a - b;","new_string":"return a + b"}"#)),
            .toolCalls((id: "g", name: "gradle", arguments: #"{"tasks":["classes"],"reason":"compile"}"#)),
            .text("It does not compile."),
        ])
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test"); settings.acceptDisclosure()
        let controller = IDEAgentController(settings: settings, clientFactory: { _ in client })
        controller.attach(host: host)
        controller.draft = "break it"
        controller.send()

        let deadline = Date().addingTimeInterval(120)
        while controller.isRunning, Date() < deadline {
            if let request = controller.entries.first(where: { $0.approval != nil })?.approval { controller.decide(callID: request.callID, .approve) }
            try await Task.sleep(for: .milliseconds(20))
        }
        let output = try XCTUnwrap(controller.entries.first { if case .toolCall("gradle") = $0.kind { true } else { false } }?.output?.text)
        XCTAssertTrue(output.contains("Compiler errors (1):"), output)
        XCTAssertTrue(output.contains("src/main/java/demo/Calc.java:5: ';' expected"), output)
    }
}

extension IDEAgentGradleFixtureTests {
    /// Opt-in, real model: it is asked what changed since the last commit and has to use the git tools.
    /// `UMBRA_AGENT_OLLAMA_MODEL=qwen-fixed:latest swift test --filter testAskingWhatChangedUsesTheGitToolsWithALocalModel`.
    func testAskingWhatChangedUsesTheGitToolsWithALocalModel() async throws {
        guard let model = ProcessInfo.processInfo.environment["UMBRA_AGENT_OLLAMA_MODEL"] else {
            throw XCTSkip("set UMBRA_AGENT_OLLAMA_MODEL to run this against a real local model")
        }
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-c", "user.email=t@example.com", "-c", "user.name=T", "-c", "commit.gpgsign=false"] + arguments
            process.currentDirectoryURL = project
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try git("init", "-q", "-b", "main")
        try git("add", "-A")
        try git("commit", "-q", "-m", "base")
        let calc = project.appendingPathComponent("src/main/java/demo/Calc.java")
        try String(contentsOf: calc, encoding: .utf8).replacingOccurrences(of: "a - b", with: "a * b").write(to: calc, atomically: true, encoding: .utf8)

        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.provider = .ollama
        settings.model = model
        let controller = IDEAgentController(
            settings: settings, clientFactory: { _ in OllamaClient(contextLength: 16_384, supportsThinking: false) })
        controller.attach(host: host)
        controller.draft = "Which files have I changed since the last commit, and what exactly changed? Use your git tools, do not guess."
        controller.send()
        let deadline = Date().addingTimeInterval(600)
        while controller.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        if controller.isRunning { controller.stop() }

        let tools = controller.entries.compactMap { entry -> String? in
            if case .toolCall(let name) = entry.kind { return name }
            return nil
        }
        let answer = controller.entries.last { $0.kind == .assistant }?.text ?? ""
        try? "tools: \(tools)\nanswer: \(answer)\n".write(
            toFile: NSTemporaryDirectory() + "agent-git-transcript.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(tools.contains { $0.hasPrefix("git_") }, "the model should have used a git tool: \(tools)")
        XCTAssertTrue(answer.contains("Calc.java"), answer)
        XCTAssertTrue(answer.contains("*"), "the answer should say the subtraction became a multiplication: \(answer)")
    }
}
