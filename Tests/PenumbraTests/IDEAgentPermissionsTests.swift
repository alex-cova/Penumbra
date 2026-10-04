import AgentKit
import Foundation
import XCTest

@testable import Umbra

/// The chat's permission modes and rules, through a real window and the real tools.
@MainActor
final class IDEAgentPermissionsTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-permissions-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "one\ntwo\nthree\n".write(to: project.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        try "alpha\nbeta\n".write(to: project.appendingPathComponent("B.txt"), atomically: true, encoding: .utf8)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    private func makeController(_ turns: [MockTurn], mode: PermissionMode) -> IDEAgentController {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        settings.mode = mode
        let client = MockLLMClient(turns: turns)
        let controller = IDEAgentController(settings: settings, clientFactory: { _ in client })
        controller.attach(host: workspace)
        return controller
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func send(_ controller: IDEAgentController, _ text: String = "go") {
        controller.draft = text
        controller.send()
    }

    private func finish(_ controller: IDEAgentController) async {
        await waitFor("the run ends") { !controller.isRunning }
    }

    private func disk(_ path: String) -> String? { try? String(contentsOf: project.appendingPathComponent(path), encoding: .utf8) }

    private func writeSettings(_ json: String, _ path: String = ".umbra/settings.local.json") throws {
        let url = project.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    private func readA() -> MockTurn { .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)) }
    private func editA(_ id: String = "e", _ old: String = "two", _ new: String = "2") -> MockTurn {
        .toolCalls((id: id, name: "edit_file", arguments: #"{"path":"A.txt","old_string":"\#(old)","new_string":"\#(new)"}"#))
    }
    private func echo(_ word: String, id: String) -> MockTurn {
        .toolCalls((id: id, name: "run_command", arguments: #"{"command":"echo \#(word)"}"#))
    }

    // MARK: - Rules from files

    func testAnAllowRuleInTheProjectLetsAnEditThroughInManualMode() async throws {
        try writeSettings(#"{"permissions":{"allow":["Edit(A.txt)"]}}"#)
        let controller = makeController([readA(), editA(), .text("done")], mode: .manual)
        send(controller)
        await finish(controller)

        XCTAssertNil(controller.entries.first { $0.approval != nil || $0.approvalOutcome != nil }, "nothing asked")
        XCTAssertEqual(disk("A.txt"), "one\n2\nthree\n")
    }

    func testADenyRuleRefusesAnEditEvenWhereTheModeWouldApplyIt() async throws {
        try writeSettings(#"{"permissions":{"deny":["Edit(A.txt)"]}}"#, ".claude/settings.json")
        let controller = makeController([readA(), editA(), .text("ok")], mode: .acceptEdits)
        send(controller)
        await finish(controller)

        XCTAssertEqual(disk("A.txt"), "one\ntwo\nthree\n", "the file did not change")
        let output = try XCTUnwrap(controller.entries.first { $0.callID == "e" }?.output)
        XCTAssertTrue(output.isError && output.text.contains("Blocked by the user's permission rules"))
    }

    func testRulesAreReadAtEachSendSoAnEditedFileTakesEffectAtOnce() async throws {
        let controller = makeController([readA(), .text("a"), editA(), .text("b")], mode: .manual)
        send(controller, "look")
        await finish(controller)

        try writeSettings(#"{"permissions":{"allow":["Edit"]}}"#)
        send(controller, "now change it")
        await finish(controller)
        XCTAssertEqual(disk("A.txt"), "one\n2\nthree\n", "the new rule applied without a restart")
    }

    // MARK: - The approval card's shortcuts

    func testAcceptEditsForThisChatApprovesNowAndStopsAskingAfter() async throws {
        let controller = makeController(
            [readA(), editA(), editA("e2", "three", "3"), .text("done")], mode: .manual)
        send(controller)
        await waitFor("the first edit asks") { controller.entries.contains { $0.approval != nil } }
        let request = try XCTUnwrap(controller.entries.compactMap(\.approval).first)

        controller.selected.approve(callID: request.callID, shortcut: .acceptEdits)
        await finish(controller)

        XCTAssertEqual(controller.mode, .acceptEdits)
        XCTAssertEqual(disk("A.txt"), "one\n2\n3\n")
        XCTAssertEqual(controller.entries.compactMap(\.approvalOutcome), ["Approved"], "the second edit did not ask")
    }

    func testAlwaysAllowInTheProjectWritesTheLocalFileAndTheNextCommandDoesNotAsk() async throws {
        let controller = makeController([echo("one", id: "c1"), echo("two", id: "c2"), .text("done")], mode: .acceptEdits)
        send(controller)
        await waitFor("the first command asks") { controller.entries.contains { $0.approval != nil } }
        let request = try XCTUnwrap(controller.entries.compactMap(\.approval).first)
        XCTAssertEqual(request.suggestedRule, "Bash(echo:*)")

        controller.selected.approve(callID: request.callID, shortcut: .allowInProject(try XCTUnwrap(PermissionRule(parsing: "Bash(echo:*)"))))
        await finish(controller)

        XCTAssertEqual(controller.entries.compactMap(\.approvalOutcome), ["Approved"], "only the first command asked")
        XCTAssertTrue(controller.entries.first { $0.callID == "c2" }?.output?.text.contains("two") == true)
        let saved = try String(contentsOf: project.appendingPathComponent(".umbra/settings.local.json"), encoding: .utf8)
        XCTAssertTrue(saved.contains("Bash(echo:*)"))
        let notice = try XCTUnwrap(controller.entries.first { $0.kind == .notice && $0.text.hasPrefix("Saved Bash(echo:*)") })
        XCTAssertTrue(notice.text.contains(".gitignore"), "a newly created personal file says so")
    }

    func testAllowForThisChatEndsWithTheConversation() async throws {
        let controller = makeController(
            [echo("one", id: "c1"), echo("two", id: "c2"), .text("done"), echo("three", id: "c3"), .text("again")], mode: .acceptEdits)
        send(controller)
        await waitFor("the first command asks") { controller.entries.contains { $0.approval != nil } }
        let request = try XCTUnwrap(controller.entries.compactMap(\.approval).first)
        controller.selected.approve(callID: request.callID, shortcut: .allowForChat(try XCTUnwrap(PermissionRule(parsing: "Bash(echo:*)"))))
        await finish(controller)
        XCTAssertEqual(controller.entries.compactMap(\.approvalOutcome), ["Approved"], "the second echo ran on the chat's rule")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".umbra").path), "nothing was saved to the project")

        controller.newConversation()
        send(controller, "again")
        await waitFor("a new conversation asks again") { controller.entries.contains { $0.approval != nil } }
        let again = try XCTUnwrap(controller.entries.compactMap(\.approval).first)
        controller.decide(callID: again.callID, .deny(note: nil))
        await finish(controller)
    }

    func testARuleThatCannotBeSavedIsReportedAndStillAppliesToThisChat() async throws {
        try writeSettings("{ not json")
        let controller = makeController([echo("one", id: "c1"), echo("two", id: "c2"), .text("done")], mode: .acceptEdits)
        send(controller)
        await waitFor("the first command asks") { controller.entries.contains { $0.approval != nil } }
        let request = try XCTUnwrap(controller.entries.compactMap(\.approval).first)
        controller.selected.approve(callID: request.callID, shortcut: .allowInProject(try XCTUnwrap(PermissionRule(parsing: "Bash(echo:*)"))))
        await finish(controller)

        XCTAssertTrue(controller.entries.contains { $0.kind == .error && $0.text.contains("Could not save the rule") })
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent(".umbra/settings.local.json"), encoding: .utf8), "{ not json")
        XCTAssertEqual(controller.entries.compactMap(\.approvalOutcome), ["Approved"])
    }

    // MARK: - Auto

    func testAutoRunsAReadOnlyCommandWithoutAsking() async throws {
        let controller = makeController([.toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"ls"}"#)), .text("done")], mode: .auto)
        send(controller)
        await finish(controller)
        XCTAssertNil(controller.entries.first { $0.approvalOutcome != nil })
        XCTAssertTrue(controller.entries.first { $0.callID == "c1" }?.output?.text.contains("A.txt") == true)
    }

    func testAutoStillAsksAboutACommandItDoesNotKnow() async throws {
        let controller = makeController([echo("hi > out.txt", id: "c1"), .text("done")], mode: .auto)
        send(controller)
        await waitFor("a redirection asks") { controller.entries.contains { $0.approval != nil } }
        let request = try XCTUnwrap(controller.entries.compactMap(\.approval).first)
        XCTAssertFalse(request.notes.isEmpty, "the card says why it asked")
        controller.decide(callID: request.callID, .deny(note: nil))
        await finish(controller)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("out.txt").path))
    }

    // MARK: - Tools

    func testGradleToolsExposeTheCommandLineToRules() throws {
        let support = IDEAgentCommandSupport(root: project, box: IDEAgentHostBox(workspace))
        let gradle = IDEGradleTool(support: support)
        XCTAssertEqual(
            gradle.permissionSubject(for: try ToolArguments(json: #"{"tasks":["build"],"options":["--info"],"reason":"r"}"#)),
            .command("gradle build --info"))
        XCTAssertEqual(gradle.permissionSubject(for: try ToolArguments(json: #"{"tasks":[]}"#)), .none)

        let tests = IDERunTestsTool(support: support)
        XCTAssertEqual(
            tests.permissionSubject(for: try ToolArguments(json: #"{"module":":app","tests":["FooTest"],"reason":"r"}"#)),
            .command("gradle :app:test --tests FooTest"))
    }
}
