import AgentKit
import Foundation
import XCTest
@testable import Umbra

@MainActor
final class IDEAgentInteractionTests: XCTestCase {
    private var project: URL!
    private var storeDirectory: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-interaction-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project", isDirectory: true)
        storeDirectory = base.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let base = project?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: base) }
    }

    private func makeController(_ turns: [MockTurn]) -> (IDEAgentController, MockLLMClient) {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let client = MockLLMClient(turns: turns)
        let controller = IDEAgentController(settings: settings, store: SessionStore(directory: storeDirectory), clientFactory: { _ in client })
        controller.attach(host: workspace)
        return (controller, client)
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func askTurn(_ options: String = #",\"options\":[\"tabs\",\"spaces\"]"#) -> MockTurn {
        .toolCalls((id: "q", name: "ask_user", arguments: "{\"question\":\"Tabs or spaces?\"\(options.replacingOccurrences(of: "\\\"", with: "\""))}"))
    }

    func testTheQuestionShowsOnItsCardAndAnAnswerContinuesTheRun() async throws {
        let (controller, client) = makeController([askTurn(), .text("Using spaces.")])
        controller.draft = "format it"
        controller.send()
        await waitFor("the question appears") { controller.entries.contains { $0.question != nil } }

        let entry = try XCTUnwrap(controller.entries.first { $0.question != nil })
        XCTAssertEqual(entry.question?.question, "Tabs or spaces?")
        XCTAssertEqual(entry.question?.options, ["tabs", "spaces"])
        XCTAssertEqual(controller.status, "Waiting for your answer…")
        XCTAssertTrue(controller.isRunning, "the run is paused, not finished")

        controller.answer(callID: "q", text: "spaces")
        await waitFor("the run finishes") { !controller.isRunning }
        let card = try XCTUnwrap(controller.entries.first { $0.callID == "q" })
        XCTAssertNil(card.question)
        XCTAssertEqual(card.questionOutcome, "Answered")
        XCTAssertEqual(card.output?.text, "The user answered: spaces")
        XCTAssertEqual(client.requests.count, 2)
    }

    func testSkippingAndStoppingBothEndTheWait() async throws {
        let (skipped, _) = makeController([askTurn(""), .text("assuming")])
        skipped.draft = "go"
        skipped.send()
        await waitFor("question") { skipped.entries.contains { $0.question != nil } }
        skipped.answer(callID: "q", text: nil)
        await waitFor("finished") { !skipped.isRunning }
        XCTAssertEqual(skipped.entries.first { $0.callID == "q" }?.questionOutcome, "Skipped")
        XCTAssertTrue(skipped.entries.first { $0.callID == "q" }?.output?.text.hasPrefix("The user did not answer.") == true)

        let (stopped, _) = makeController([askTurn(""), .text("never")])
        stopped.draft = "go"
        stopped.send()
        await waitFor("question") { stopped.entries.contains { $0.question != nil } }
        stopped.stop()
        await waitFor("stopped") { !stopped.isRunning }
        XCTAssertNil(stopped.entries.first { $0.callID == "q" }?.question, "a stopped run leaves no dangling question")
        XCTAssertEqual(stopped.entries.last?.text, "Stopped.")
    }

    func testTheChecklistFollowsTheModelAndIsSavedAndRestoredEvenIfTheHistoryLostIt() async throws {
        let (first, _) = makeController([
            .toolCalls((id: "t", name: "todo", arguments: #"{"items":["[x] read","[~] fix","[ ] test"]}"#)),
            .text("on it"),
        ])
        first.draft = "do the thing"
        first.send()
        await waitFor("finished") { !first.isRunning && first.history.count == 1 }
        XCTAssertEqual(first.todos.map(\.content), ["read", "fix", "test"])
        XCTAssertEqual(first.todos.map(\.status), [.completed, .inProgress, .pending])

        let (second, client) = makeController([.text("continuing")])
        second.restoreLatestIfNeeded()
        XCTAssertEqual(second.todos.count, 3, "the checklist comes back with the conversation")
        second.draft = "keep going"
        second.send()
        await waitFor("finished") { !second.isRunning }
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(second.todos.count, 3)

        // Compaction can remove the `todo` call from the history; the saved checklist still seeds the session.
        let store = SessionStore(directory: storeDirectory)
        let id = try XCTUnwrap(second.history.first?.id)
        var snapshot = try XCTUnwrap(store.load(id, projectRoot: project.path))
        snapshot.items = snapshot.items.filter { if case .toolCall(_, "todo", _) = $0 { false } else if case .toolOutput(let call, _) = $0, call == "t" { false } else { true } }
        try store.save(snapshot)
        let (third, _) = makeController([.text("again")])
        third.restoreLatestIfNeeded()
        XCTAssertEqual(third.todos.count, 3)
        third.draft = "more"
        third.send()
        await waitFor("finished") { !third.isRunning }
        let session = try XCTUnwrap(third.currentSessionForTesting)
        let restored = await session.todoList.items
        XCTAssertEqual(restored.count, 3, "the session has the saved checklist although its history does not")
    }

    func testANewConversationStartsWithoutTheOldChecklist() async {
        let (controller, _) = makeController([.toolCalls((id: "t", name: "todo", arguments: #"{"items":["[ ] a"]}"#)), .text("ok")])
        controller.draft = "go"
        controller.send()
        await waitFor("finished") { !controller.isRunning }
        XCTAssertEqual(controller.todos.count, 1)
        controller.newConversation()
        XCTAssertTrue(controller.todos.isEmpty)
    }

    func testAnUnreadableToolCallShowsANoticeAndTheRunGoesOn() async throws {
        let (controller, client) = makeController([
            MockTurn([.unreadableToolCall(detail: "malformed_syntax", raw: "<tool_call>{"), .finished(.completed)]),
            .text("Recovered."),
        ])
        controller.draft = "go"
        controller.send()
        await waitFor("finished") { !controller.isRunning }
        XCTAssertEqual(controller.entries.map(\.kind), [.user, .notice, .assistant])
        XCTAssertEqual(controller.entries[1].text, "The model wrote a tool call that could not be read. Asking it to try again.")
        XCTAssertEqual(client.requests.count, 2, "the model was asked again rather than the run ending")
    }

    func testToolCardTitlesForTheNewTools() {
        XCTAssertEqual(IDEAgentToolSummary.title(name: "ask_user", arguments: #"{"question":"Tabs or spaces?"}"#), "ask_user  Tabs or spaces?")
        XCTAssertEqual(IDEAgentToolSummary.title(name: "todo", arguments: #"{"items":["[ ] a","[ ] b"]}"#), "todo  2 items")
        XCTAssertEqual(IDEAgentToolSummary.title(name: "todo", arguments: #"{"items":["[ ] a"]}"#), "todo  1 item")
    }

    /// Opt-in, real model: `UMBRA_AGENT_OLLAMA_MODEL=qwen-fixed:latest swift test --filter testARealModelAsksAndKeepsAChecklist`.
    func testARealModelAsksAndKeepsAChecklist() async throws {
        guard let model = ProcessInfo.processInfo.environment["UMBRA_AGENT_OLLAMA_MODEL"] else {
            throw XCTSkip("set UMBRA_AGENT_OLLAMA_MODEL to run this against a real local model")
        }
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.provider = .ollama
        settings.model = model
        let controller = IDEAgentController(
            settings: settings, clientFactory: { _ in OllamaClient(contextLength: 16_384, supportsThinking: false) })
        controller.attach(host: workspace)
        controller.draft = "I want a greeting file in this project, but I have not decided its name. Use ask_user to ask me which name I want (offer two options), keep a todo checklist of your steps, then create that file with write_file containing the text hello."
        controller.send()

        var asked: [String] = []
        let deadline = Date().addingTimeInterval(600)
        while controller.isRunning, Date() < deadline {
            if let question = controller.entries.compactMap(\.question).first {
                asked.append(question.question)
                controller.answer(callID: question.callID, text: "greeting.txt")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if controller.isRunning { controller.stop() }

        let tools = controller.entries.compactMap { entry -> String? in
            if case .toolCall(let name) = entry.kind { return name }
            return nil
        }
        var log = ""
        for entry in controller.entries {
            switch entry.kind {
            case .user: log += "USER: \(entry.text.suffix(80))\n"
            case .assistant: log += "ASSISTANT: \(entry.text)\n"
            case .toolCall(let name): log += "TOOL \(name) \(entry.text)\n   -> \((entry.output?.text ?? "").prefix(300))\n"
            case .notice, .error: log += "NOTICE: \(entry.text)\n"
            case .changes: log += "CHANGES\n"
            }
        }
        try? log.write(toFile: NSTemporaryDirectory() + "agent-interaction-entries.txt", atomically: true, encoding: .utf8)
        try? "tools: \(tools)\nasked: \(asked)\ntodos: \(controller.todos)\nfiles: \((try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? [])\n".write(
            toFile: NSTemporaryDirectory() + "agent-interaction-transcript.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(asked.count, 1, "the model should ask exactly once: \(asked)")
        XCTAssertTrue(tools.contains("todo"), "\(tools)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("greeting.txt").path), "\(tools)")
    }
}
