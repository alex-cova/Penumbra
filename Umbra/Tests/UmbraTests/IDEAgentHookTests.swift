import AgentKit
import Foundation
import XCTest
@testable import Umbra

final class IDEAgentHookTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(
        event: IDEAgentHookEvent = .preToolUse, matcher: String = "",
        command: String = "true", timeout: TimeInterval = 30, required: Bool = false
    ) -> IDEAgentHookEntry {
        IDEAgentHookEntry(
            event: event, matcher: matcher, command: command,
            timeout: timeout, required: required, origin: .claudeShared)
    }

    private var environment: [String: String] { ["PATH": "/usr/bin:/bin"] }

    // MARK: - Parsing

    func testParsesClaudeCodeShape() throws {
        let json = """
        {"hooks": {
          "PreToolUse": [{"matcher": "Edit|Write", "hooks": [
            {"type": "command", "command": "swiftformat --lint stdin", "timeout": 10}
          ]}],
          "PostToolUse": [{"matcher": "Edit|Write", "hooks": [
            {"type": "command", "command": "swiftformat stdin", "required": true}
          ]}],
          "Stop": [{"hooks": [{"type": "command", "command": "notify-done"}]}],
          "SessionStart": [{"hooks": [{"type": "command", "command": "ignored-later"}]}]
        }}
        """
        let entries = IDEAgentHooks.parse(Data(json.utf8), origin: .claudeShared)
        XCTAssertEqual(entries.count, 3)
        let pre = try XCTUnwrap(entries.first { $0.event == .preToolUse })
        XCTAssertEqual(pre.matcher, "Edit|Write")
        XCTAssertEqual(pre.command, "swiftformat --lint stdin")
        XCTAssertEqual(pre.timeout, 10)
        XCTAssertFalse(pre.required)
        let post = try XCTUnwrap(entries.first { $0.event == .postToolUse })
        XCTAssertEqual(post.timeout, IDEAgentHookRunner.defaultTimeout)
        XCTAssertTrue(post.required)
        let stop = try XCTUnwrap(entries.first { $0.event == .stop })
        XCTAssertEqual(stop.matcher, "", "a Stop hook without a matcher matches everything")
        XCTAssertEqual(stop.command, "notify-done")
    }

    func testParsingSkipsNonCommandsAndBrokenFiles() {
        let json = """
        {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
          {"type": "other", "command": "skipped"},
          {"type": "command", "command": ""},
          {"type": "command"}
        ]]}}
        """
        XCTAssertTrue(IDEAgentHooks.parse(Data(json.utf8), origin: .app).isEmpty)
        XCTAssertTrue(IDEAgentHooks.parse(Data("not json".utf8), origin: .app).isEmpty)
        XCTAssertTrue(IDEAgentHooks.parse(Data("{}".utf8), origin: .app).isEmpty)
    }

    // MARK: - Aliases

    func testAliasTable() {
        for tool in ["run_command", "gradle", "maven", "project_task", "run_tests"] {
            XCTAssertTrue(IDEAgentHookMatcher.matches("Bash", tool: tool), "Bash matches \(tool)")
        }
        XCTAssertFalse(IDEAgentHookMatcher.matches("Bash", tool: "edit_file"))
        for tool in ["edit_file", "write_file", "apply_patch"] {
            XCTAssertTrue(IDEAgentHookMatcher.matches("Edit|Write", tool: tool))
        }
        XCTAssertFalse(IDEAgentHookMatcher.matches("Edit|Write", tool: "read_file"))
        XCTAssertTrue(IDEAgentHookMatcher.matches("Read", tool: "read_file"))
        XCTAssertTrue(IDEAgentHookMatcher.matches("Grep", tool: "grep"))
        XCTAssertTrue(IDEAgentHookMatcher.matches("Glob", tool: "glob"))
        XCTAssertTrue(IDEAgentHookMatcher.matches("", tool: "run_command"))
        XCTAssertTrue(IDEAgentHookMatcher.matches("*", tool: "run_command"))
        XCTAssertTrue(IDEAgentHookMatcher.matches("run_command", tool: "run_command"))
        XCTAssertFalse(IDEAgentHookMatcher.matches("run_command", tool: "gradle"))
        XCTAssertTrue(IDEAgentHookMatcher.matches("run_*", tool: "run_tests"))
        XCTAssertFalse(IDEAgentHookMatcher.matches("run_*", tool: "gradle"))
    }

    // MARK: - Consent

    @MainActor
    func testConsentAsksAgainAfterTheBlockChanges() async {
        let suite = "test-hooks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let trust = IDEAgentHookTrust(defaults: defaults)
        let block = [entry(command: "lint")]
        var confirms = 0

        let approved = await IDEAgentHookConsent.resolve(entries: block, trust: trust) {
            confirms += 1
            return true
        }
        XCTAssertEqual(approved, block)
        XCTAssertEqual(confirms, 1)

        let again = await IDEAgentHookConsent.resolve(entries: block, trust: trust) {
            confirms += 1
            return true
        }
        XCTAssertEqual(again, block)
        XCTAssertEqual(confirms, 1, "an approved block is not asked about again")

        let changed = [entry(command: "lint --fix")]
        _ = await IDEAgentHookConsent.resolve(entries: changed, trust: trust) {
            confirms += 1
            return false
        }
        XCTAssertEqual(confirms, 2, "a changed block asks again")
        let declined = await IDEAgentHookConsent.resolve(entries: changed, trust: trust) {
            confirms += 1
            return true
        }
        XCTAssertTrue(declined.isEmpty, "a declined project block never runs")
        XCTAssertEqual(confirms, 2, "a declined block is not asked about again until it changes")
    }

    @MainActor
    func testConsentKeepsAppHooksWithoutAsking() async {
        let suite = "test-hooks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let trust = IDEAgentHookTrust(defaults: defaults)
        var app = entry(command: "user-hook")
        app.origin = .app
        var confirms = 0
        let resolved = await IDEAgentHookConsent.resolve(entries: [app], trust: trust) {
            confirms += 1
            return false
        }
        XCTAssertEqual(resolved, [app])
        XCTAssertEqual(confirms, 0, "user-level hooks need no prompt")
    }

    // MARK: - Stdin JSON

    func testStdinJSONShape() throws {
        let data = IDEAgentHookRunner.stdinJSON(
            sessionID: "s1", root: URL(fileURLWithPath: "/proj"), event: .preToolUse,
            toolName: "run_command", argumentsJSON: #"{"command":"ls"}"#)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["session_id"] as? String, "s1")
        XCTAssertEqual(object["cwd"] as? String, "/proj")
        XCTAssertEqual(object["hook_event_name"] as? String, "PreToolUse")
        XCTAssertEqual(object["tool_name"] as? String, "run_command")
        XCTAssertEqual((object["tool_input"] as? [String: Any])?["command"] as? String, "ls")

        let after = IDEAgentHookRunner.stdinJSON(
            sessionID: "s1", root: URL(fileURLWithPath: "/proj"), event: .postToolUse,
            toolName: "edit_file", argumentsJSON: #"{"path":"A"}"#, output: "edited")
        let afterObject = try XCTUnwrap(JSONSerialization.jsonObject(with: after) as? [String: Any])
        XCTAssertEqual(afterObject["tool_response"] as? String, "edited")
    }

    // MARK: - Exit-code mapping

    func testExitCodeMapping() throws {
        var warnings: [String] = []
        let warn: (String) -> Void = { warnings.append($0) }
        func outcome(code: Int32?, stdout: String = "", stderr: String = "", timedOut: Bool = false, started: Bool = true) -> IDEAgentHookRunner.Outcome {
            IDEAgentHookRunner.Outcome(exitCode: code, stdout: stdout, stderr: stderr, timedOut: timedOut, started: started)
        }

        XCTAssertEqual(IDEAgentHookRunner.preDecision(outcome(code: 0), entry: entry(), warn: warn), .allow)
        let denied = IDEAgentHookRunner.preDecision(outcome(code: 2, stderr: "no rm"), entry: entry(), warn: warn)
        if case .deny(let reason) = denied {
            XCTAssertTrue(reason.contains("no rm"), "stderr goes to the model")
        } else {
            XCTFail("exit 2 blocks")
        }
        XCTAssertEqual(IDEAgentHookRunner.preDecision(outcome(code: 1), entry: entry(), warn: warn), .allow)
        XCTAssertEqual(warnings.count, 1, "any other failure warns and fails open")
        if case .deny = IDEAgentHookRunner.preDecision(outcome(code: 1), entry: entry(required: true), warn: warn) {}
        else { XCTFail("a required hook fails closed") }
        XCTAssertEqual(
            IDEAgentHookRunner.preDecision(outcome(code: nil, started: false), entry: entry(), warn: warn), .allow)
        XCTAssertEqual(
            IDEAgentHookRunner.preDecision(outcome(code: nil, timedOut: true), entry: entry(), warn: warn), .allow)

        let added = IDEAgentHookRunner.postText(outcome(code: 0, stdout: "formatted"), entry: entry(), warn: warn)
        XCTAssertTrue(added?.contains("formatted") == true, "stdout is added context for after-hooks")
        XCTAssertNil(IDEAgentHookRunner.postText(outcome(code: 0), entry: entry(), warn: warn))
        let blocked = try XCTUnwrap(IDEAgentHookRunner.postText(outcome(code: 2, stderr: "still dirty"), entry: entry(), warn: warn))
        XCTAssertTrue(blocked.contains("still dirty"))
        XCTAssertNil(IDEAgentHookRunner.postText(outcome(code: 3), entry: entry(), warn: warn))
        XCTAssertNotNil(IDEAgentHookRunner.postText(outcome(code: 3), entry: entry(required: true), warn: warn))

        XCTAssertEqual(try IDEAgentHookRunner.stopVerdict(outcome(code: 0), entry: entry()), .pass)
        let stopBlock = try IDEAgentHookRunner.stopVerdict(outcome(code: 2, stderr: "tests red"), entry: entry())
        if case .block(let reason) = stopBlock {
            XCTAssertTrue(reason.contains("tests red"))
        } else {
            XCTFail("exit 2 blocks the run")
        }
        XCTAssertThrowsError(try IDEAgentHookRunner.stopVerdict(outcome(code: 1), entry: entry()),
                             "a failing Stop hook fails open")
        let requiredBlock = try IDEAgentHookRunner.stopVerdict(outcome(code: 1), entry: entry(required: true))
        if case .block = requiredBlock {} else { XCTFail("a required Stop hook fails closed") }
    }

    // MARK: - Shell runs

    func testRunnerPassesStdinAndSeparatesStreams() async {
        let stdin = IDEAgentHookRunner.stdinJSON(
            sessionID: "s9", root: directory, event: .preToolUse,
            toolName: "run_command", argumentsJSON: #"{"command":"ls"}"#)
        let echoed = await IDEAgentHookRunner.run(
            entry: entry(command: "cat"), stdin: stdin,
            workingDirectory: directory, environment: environment)
        XCTAssertEqual(echoed.exitCode, 0)
        XCTAssertTrue(echoed.started && !echoed.timedOut)
        XCTAssertTrue(echoed.stdout.contains("s9"), "stdin reaches the hook: \(echoed.stdout)")
        XCTAssertTrue(echoed.stderr.isEmpty)

        let blocked = await IDEAgentHookRunner.run(
            entry: entry(command: "echo oops >&2; exit 2"), stdin: Data(),
            workingDirectory: directory, environment: environment)
        XCTAssertEqual(blocked.exitCode, 2)
        XCTAssertTrue(blocked.stderr.contains("oops"))
    }

    func testHostBeforeAndAfterWithRealShell() async {
        let context = IDEAgentHookHost.Context(
            sessionID: "s", root: directory, environment: environment, onWarning: { _ in })
        let denyHost = IDEAgentHookHost(
            entries: [entry(event: .preToolUse, matcher: "run_command", command: "echo blocked >&2; exit 2")],
            context: context)
        let blocked = await denyHost.before(
            HookCall(toolName: "run_command", risk: .command, argumentsJSON: #"{"command":"rm -rf /"}"#))
        if case .deny(let reason) = blocked {
            XCTAssertTrue(reason.contains("blocked"))
        } else {
            XCTFail("exit 2 stops the command")
        }
        let unmatched = await denyHost.before(
            HookCall(toolName: "read_file", risk: .read, argumentsJSON: "{}"))
        XCTAssertEqual(unmatched, .allow, "a hook only sees the tools its matcher names")

        let formatHost = IDEAgentHookHost(
            entries: [entry(event: .postToolUse, matcher: "Edit", command: "echo formatted")],
            context: context)
        let appended = await formatHost.after(
            HookCall(toolName: "edit_file", risk: .edit, argumentsJSON: "{}"), output: "done")
        XCTAssertTrue(appended?.contains("formatted") == true)
    }

    func testRunnerTimesOut() async {
        let started = Date()
        let outcome = await IDEAgentHookRunner.run(
            entry: entry(command: "sleep 5", timeout: 1), stdin: Data(),
            workingDirectory: directory, environment: environment)
        XCTAssertTrue(outcome.started)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }
}
