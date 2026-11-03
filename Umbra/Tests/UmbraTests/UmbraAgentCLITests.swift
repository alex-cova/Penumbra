import AgentKit
import Foundation
import XCTest
import UmbraAgentSupport

/// CLI parsing and headless-run behavior for `umbra-agent run`
/// (docs/harness/agent-harness-6.md Phase 2 tests).
final class UmbraAgentCommandLineTests: XCTestCase {
    func testParseRunPromptAndFlags() throws {
        let parsed = try UmbraAgentCommandLine.parse([
            "run", "add a unit test", "--provider", "openai", "--model", "gpt-5",
            "--mode", "accept-edits", "--max-iterations", "20",
            "--cwd", "/tmp/work", "--output", "json",
        ])
        XCTAssertEqual(parsed.prompt, "add a unit test")
        XCTAssertEqual(parsed.provider, "openai")
        XCTAssertEqual(parsed.model, "gpt-5")
        XCTAssertEqual(parsed.mode, "accept-edits")
        XCTAssertEqual(parsed.maxIterations, 20)
        XCTAssertEqual(parsed.workingDirectory, "/tmp/work")
        XCTAssertEqual(parsed.output, "json")
        XCTAssertFalse(parsed.allowMCP)
        XCTAssertFalse(parsed.sandbox)
    }

    func testParseMultiWordPromptAndBooleans() throws {
        let parsed = try UmbraAgentCommandLine.parse([
            "run", "fix", "the", "build", "--allow-mcp", "--sandbox",
            "--env", "FOO=bar", "--env", "PATH=/x:$PATH",
        ])
        XCTAssertEqual(parsed.prompt, "fix the build")
        XCTAssertTrue(parsed.allowMCP)
        XCTAssertTrue(parsed.sandbox)
        XCTAssertEqual(parsed.extraEnvironment, ["FOO": "bar", "PATH": "/x:$PATH"])
    }

    func testParseRejectsUnknownFlagAndMode() {
        XCTAssertThrowsError(try UmbraAgentCommandLine.parse(["run", "hi", "--bogus"]))
        XCTAssertThrowsError(try UmbraAgentCommandLine.parse(["run", "hi", "--mode", "turbo"]))
        XCTAssertThrowsError(try UmbraAgentCommandLine.parse(["run", "hi", "--output", "yaml"]))
        XCTAssertThrowsError(try UmbraAgentCommandLine.parse(["run"]))
    }

    func testModeAndOutputMapping() throws {
        XCTAssertEqual(try UmbraAgentCommandLine.parse(["run", "x", "--mode", "plan"]).permissionMode(), .plan)
        XCTAssertEqual(try UmbraAgentCommandLine.parse(["run", "x", "--mode", "auto"]).permissionMode(), .auto)
        XCTAssertEqual(try UmbraAgentCommandLine.parse(["run", "x"]).permissionMode(), .acceptEdits)
        XCTAssertEqual(try UmbraAgentCommandLine.parse(["run", "x", "--output", "stream-json"]).outputFormat(), .streamJson)
    }
}

final class UmbraAgentHeadlessRunTests: XCTestCase {
    private func scratch() throws -> (root: URL, sessions: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-agent-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("work", isDirectory: true)
        let sessions = base.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        return (root.resolvingSymlinksInPath(), sessions)
    }

    private func request(
        prompt: String = "say hi", client: MockLLMClient, root: URL, sessions: URL,
        mode: PermissionMode = .acceptEdits, maxIterations: Int? = nil
    ) -> UmbraAgentRunRequest {
        UmbraAgentRunRequest(
            prompt: prompt,
            provider: UmbraAgentProviderConfig(provider: .openAIResponses, model: "mock"),
            client: client, mode: mode, maxIterations: maxIterations,
            workingDirectory: root, output: .json,
            sessionsDirectory: sessions)
    }

    func testTextRunExitsZeroWithStableJSON() async throws {
        let (root, sessions) = try scratch()
        let result = await UmbraAgentHeadlessRun.run(request(
            client: MockLLMClient(turns: [.text("hello there")]), root: root, sessions: sessions))
        XCTAssertEqual(result.exitCode, .finished)
        XCTAssertEqual(result.text, "hello there")
        XCTAssertTrue(result.refusals.isEmpty)
        let object = result.jsonObject()
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["exit_code"] as? Int, 0)
        XCTAssertEqual(object["ending"] as? String, "completed")
        XCTAssertEqual(object["text"] as? String, "hello there")
        // The session is saved through SessionStore, so it opens in the app afterwards.
        let store = SessionStore(directory: sessions)
        XCTAssertEqual(store.list(projectRoot: root.path).count, 1)
    }

    func testRefusedCommandExitsThreeWithCommandInJSON() async throws {
        let (root, sessions) = try scratch()
        let result = await UmbraAgentHeadlessRun.run(request(
            client: MockLLMClient(turns: [
                .toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"ls","reason":"list"}"#)),
                .text("could not list"),
            ]), root: root, sessions: sessions))
        XCTAssertEqual(result.exitCode, .approvalRefused)
        XCTAssertEqual(result.refusals.count, 1)
        XCTAssertEqual(result.refusals.first?.command, "ls")
        let refused = (result.jsonObject()["refused"] as? [[String: Any]])?.first
        XCTAssertEqual(refused?["command"] as? String, "ls")
    }

    func testHeadlessEditWritesFilesAndExitsZero() async throws {
        // The Done-when path: a headless run edits files in the working directory and exits 0.
        let (root, sessions) = try scratch()
        try "hello\n".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let result = await UmbraAgentHeadlessRun.run(request(
            client: MockLLMClient(turns: [
                .toolCalls((id: "c1", name: "read_file", arguments: #"{"path":"note.txt"}"#)),
                .toolCalls((id: "c2", name: "write_file", arguments: #"{"path":"added.txt","content":"made by the agent"}"#)),
                .text("added the file"),
            ]),
            root: root, sessions: sessions))
        XCTAssertEqual(result.exitCode, .finished)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("added.txt"), encoding: .utf8),
            "made by the agent")
    }

    func testIterationCapExitsTwo() async throws {
        // The cap trips at the next turn boundary after a turn that ran tools; the grace
        // turn wraps up, then the run ends .iterationCap.
        let (root, sessions) = try scratch()
        let result = await UmbraAgentHeadlessRun.run(request(
            client: MockLLMClient(turns: [
                .toolCalls((id: "c1", name: "read_file", arguments: #"{"path":"missing.txt"}"#)),
                .text("wrapping up"),
            ]),
            root: root, sessions: sessions, maxIterations: 1))
        XCTAssertEqual(result.exitCode, .budget)
        XCTAssertEqual(result.ending, .iterationCap)
    }

    func testProviderFactoryBuildsAnthropicAndMeta() async throws {
        let local = URL(string: "http://localhost:1")!
        let anthropic = try await UmbraAgentProviderFactory.make(UmbraAgentProviderConfig(
            provider: .anthropic, model: "claude-opus-5-5", baseURL: local.absoluteString))
        XCTAssertTrue(anthropic.client is AnthropicMessagesClient)
        let meta = try await UmbraAgentProviderFactory.make(UmbraAgentProviderConfig(
            provider: .meta, model: "muse-spark-1.3", baseURL: local.absoluteString))
        XCTAssertTrue(meta.client is OpenAIResponsesClient)
    }
}
