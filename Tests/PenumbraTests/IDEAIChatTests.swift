import AgentKit
import Foundation
import XCTest
@testable import Umbra

/// Chat is a plain conversation: no project, no tools, any model. These run it against a scripted client.
@MainActor
final class IDEAIChatTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ai-chat-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSettings() -> IDEAgentSettings {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.ai.chat.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.acceptDisclosure(for: .anthropic)
        return settings
    }

    private func makeAISettings() -> IDEAISettings {
        IDEAISettings(defaults: UserDefaults(suiteName: "umbra.ai.prefs.\(UUID().uuidString)")!)
    }

    private func makeController(
        _ clients: [MockLLMClient], settings: IDEAgentSettings? = nil, aiSettings: IDEAISettings? = nil
    ) -> IDEAIChatController {
        var remaining = clients
        return IDEAIChatController(
            settings: settings ?? makeSettings(), aiSettings: aiSettings ?? makeAISettings(), store: SessionStore(directory: directory),
            clientFactory: { _, _ in remaining.isEmpty ? MockLLMClient(turns: []) : remaining.removeFirst() })
    }

    private func send(_ controller: IDEAIChatController, _ text: String) async {
        controller.selected.draft = text
        controller.selected.send()
        for _ in 0..<500 where controller.selected.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.selected.isRunning, "the run should have finished")
    }

    private let claude = IDEAIModelChoice(provider: .anthropic, model: "claude-sonnet-5-5", reasoningEffort: "low")

    // MARK: - A plain conversation

    func testAChatAnswersWithNoToolsAndTheChatPrompt() async throws {
        let client = MockLLMClient(turns: [.text("Hello there")])
        let controller = makeController([client])
        controller.choose(claude)
        await send(controller, "hi")

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertTrue(request.tools.isEmpty, "plain chat offers no tools")
        XCTAssertEqual(request.model, "claude-sonnet-5-5")
        XCTAssertEqual(request.reasoningEffort, "low")
        XCTAssertEqual(request.system, IDEAISettings.defaultChatSystemPrompt)
        XCTAssertEqual(controller.selected.entries.map(\.kind), [.user, .assistant])
        XCTAssertEqual(controller.selected.entries.last?.text, "Hello there")
        XCTAssertFalse(controller.selected.entries.last?.isStreaming ?? true)
        XCTAssertEqual(controller.selected.title, "hi")
        XCTAssertNil(controller.selected.status)
    }

    func testARemoteChatNeedsConsentBeforeItCanSend() async throws {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.ai.chat.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        let client = MockLLMClient(turns: [.text("x")])
        let controller = makeController([client], settings: settings)
        controller.choose(claude)
        controller.selected.draft = "hello"
        XCTAssertFalse(controller.selected.hasConsent)
        XCTAssertFalse(controller.selected.canSend)
        controller.selected.send()
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertTrue(controller.selected.entries.isEmpty, "nothing was added or sent")

        settings.acceptDisclosure(for: .anthropic)
        XCTAssertTrue(controller.selected.canSend)
    }

    func testAFailedSendCanBeRetriedWithoutTheMessageTwice() async throws {
        let first = MockLLMClient(turns: [MockTurn([], failure: .unreachable("Could not connect to localhost."))])
        let controller = makeController([first])
        controller.choose(claude)
        await send(controller, "are you there")
        XCTAssertEqual(controller.selected.entries.map(\.kind), [.user, .error])
        XCTAssertTrue(controller.selected.entries.last?.canRetry == true)

        // The same session answers the retry; its client is the one made first.
        controller.selected.retry()
        for _ in 0..<500 where controller.selected.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.selected.entries.filter { $0.kind == .user }.count, 1, "the message is not added again")
        XCTAssertFalse(controller.selected.entries.contains { $0.canRetry && $0.kind == .error && $0.text.isEmpty })
    }

    func testAConfigurationProblemIsShownAsAnErrorAndEndsTheRun() async throws {
        let settings = makeSettings()
        let controller = IDEAIChatController(
            settings: settings, aiSettings: makeAISettings(), store: SessionStore(directory: directory),
            clientFactory: { settings, choice in try settings.makeClient(for: choice, requiresTools: false) })
        controller.choose(claude) // no key saved
        await send(controller, "hi")
        XCTAssertEqual(controller.selected.entries.last?.kind, .error)
        XCTAssertTrue(controller.selected.entries.last?.text.contains("API key") == true)
        XCTAssertFalse(controller.selected.isRunning)
    }

    func testChangingTheModelKeepsTheConversation() async throws {
        let first = MockLLMClient(turns: [.text("a")])
        let second = MockLLMClient(turns: [.text("b")])
        let controller = makeController([first, second])
        controller.choose(claude)
        await send(controller, "one")
        controller.choose(IDEAIModelChoice(provider: .anthropic, model: "claude-haiku-5-5"))
        await send(controller, "two")

        XCTAssertEqual(first.requests.map(\.model), ["claude-sonnet-5-5"])
        XCTAssertEqual(second.requests.map(\.model), ["claude-haiku-5-5"])
        XCTAssertTrue(second.requests[0].items.contains { if case .assistant("a") = $0 { true } else { false } })
        XCTAssertEqual(controller.selected.entries.map(\.text), ["one", "a", "two", "b"])
    }

    // MARK: - Saving

    func testAChatIsSavedApartFromProjectsAndComesBackWithItsModel() async throws {
        let controller = makeController([MockLLMClient(turns: [.text("saved reply")])])
        controller.choose(claude)
        await send(controller, "remember this")
        for _ in 0..<200 where controller.history.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(controller.history.map(\.title), ["remember this"])
        XCTAssertEqual(controller.history.first?.projectRoot, IDEAIChatConversation.storeRoot)
        XCTAssertEqual(controller.history.first?.messageCount, 1)

        // Another window, same store.
        let other = makeController([])
        XCTAssertEqual(other.history.map(\.title), ["remember this"])
        other.resume(try XCTUnwrap(other.history.first?.id))
        XCTAssertEqual(other.selected.entries.map(\.text), ["remember this", "saved reply"])
        XCTAssertEqual(other.selected.modelChoice, claude)
        XCTAssertEqual(other.conversations.count, 1, "the empty chat was filled, not left beside it")
    }

    func testChatsNeverAppearInAProjectsList() async throws {
        let store = SessionStore(directory: directory)
        let controller = makeController([MockLLMClient(turns: [.text("r")])])
        controller.choose(claude)
        await send(controller, "private chat")
        for _ in 0..<200 where controller.history.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.list(projectRoot: "/Users/someone/project").isEmpty)
        XCTAssertEqual(store.listAll().map(\.projectRoot), [IDEAIChatConversation.storeRoot])
    }

    func testDeletingASavedChatRemovesItAndClosesItsTab() async throws {
        let controller = makeController([MockLLMClient(turns: [.text("r")])])
        controller.choose(claude)
        await send(controller, "to delete")
        for _ in 0..<200 where controller.history.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        let id = try XCTUnwrap(controller.history.first?.id)
        controller.delete(id)
        XCTAssertTrue(controller.history.isEmpty)
        XCTAssertTrue(controller.selected.isEmpty, "the only chat was emptied instead of closed")
    }

    // MARK: - Chats of a window

    func testANewChatReusesAnEmptyOneAndOtherwiseOpensAnotherWithTheSameModel() async throws {
        let controller = makeController([MockLLMClient(turns: [.text("r")])])
        controller.choose(claude)
        controller.newChat()
        XCTAssertEqual(controller.conversations.count, 1, "an empty chat is reused")

        await send(controller, "first")
        controller.newChat()
        XCTAssertEqual(controller.conversations.count, 2)
        XCTAssertTrue(controller.selected.isEmpty)
        XCTAssertEqual(controller.selected.modelChoice, claude)
    }

    func testClosingTheSelectedChatSelectsANeighbourAndTheLastOneIsEmptied() async throws {
        let controller = makeController([MockLLMClient(turns: [.text("r")])])
        controller.choose(claude)
        await send(controller, "first")
        controller.newChat()
        let second = controller.selected.id
        controller.close(second)
        XCTAssertEqual(controller.conversations.count, 1)
        XCTAssertFalse(controller.selected.isEmpty)
        controller.close(controller.selected.id)
        XCTAssertTrue(controller.selected.isEmpty)
        XCTAssertEqual(controller.conversations.count, 1)
    }

    func testTheDefaultModelIsTheLastOnePickedElseTheGlobalOne() {
        let settings = makeSettings()
        let ai = makeAISettings()
        settings.provider = .anthropic
        settings.model = "claude-haiku-5-5"
        XCTAssertEqual(IDEAIChatController.defaultChoice(aiSettings: ai, settings: settings).model, "claude-haiku-5-5")
        ai.chatChoice = claude
        XCTAssertEqual(IDEAIChatController.defaultChoice(aiSettings: ai, settings: settings), claude)
    }

    func testANewChatPrefersAModelThatIsReadyOverTheGlobalOneThatIsNot() async throws {
        let settings = makeSettings()
        let ai = makeAISettings()
        // The global model is OpenAI with no key; a Claude key is saved.
        XCTAssertEqual(settings.provider, .openAIResponses)
        XCTAssertNotNil(settings.setupHint)
        settings.saveAPIKey("sk-ant-test", for: .anthropic)
        let chosen = IDEAIChatController.defaultChoice(aiSettings: ai, settings: settings)
        XCTAssertEqual(chosen.provider, .anthropic)
        XCTAssertEqual(chosen.model, "claude-opus-5-5")

        // Once a message is sent the chat keeps that model, whatever the default becomes.
        let client = MockLLMClient(turns: [.text("r")])
        let controller = IDEAIChatController(
            settings: settings, aiSettings: ai, store: nil, clientFactory: { _, _ in client })
        XCTAssertNil(controller.selected.modelChoice)
        await send(controller, "hello")
        XCTAssertEqual(controller.selected.modelChoice?.provider, .anthropic)
        settings.removeAPIKey(for: .anthropic)
        XCTAssertEqual(controller.selected.effectiveChoice.provider, .anthropic, "pinned at the first send")
    }

    func testTheSettingsRememberTheChoicesAndThePrompt() {
        let suite = "umbra.ai.remember.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = IDEAISettings(defaults: defaults)
        XCTAssertNil(first.chatChoice)
        XCTAssertEqual(first.chatSystemPrompt, IDEAISettings.defaultChatSystemPrompt)
        first.chatChoice = claude
        first.codeChoice = IDEAIModelChoice(provider: .ollama, model: "coder:7b")
        first.chatSystemPrompt = "Be terse."

        let second = IDEAISettings(defaults: defaults)
        XCTAssertEqual(second.chatChoice, claude)
        XCTAssertEqual(second.codeChoice?.model, "coder:7b")
        XCTAssertEqual(second.chatSystemPrompt, "Be terse.")
        second.chatChoice = nil
        XCTAssertNil(IDEAISettings(defaults: defaults).chatChoice)
    }
}

/// What the sidebar lists, and how a model reads in a label.
final class IDEAISessionsTests: XCTestCase {
    private func summary(_ title: String, _ root: String?, _ seconds: Double) -> SessionSummary {
        SessionSummary(id: UUID(), title: title, updatedAt: Date(timeIntervalSince1970: seconds), projectRoot: root)
    }

    func testTheCurrentProjectComesFirstThenOthersNewestFirst() {
        let current = [summary("c1", "/p/current", 500)]
        let others = [
            summary("b-new", "/p/b", 900), summary("a-old", "/p/a", 100), summary("b-old", "/p/b", 800),
            summary("current-stale", "/p/current", 400),
        ]
        let groups = IDEAISessions.groups(current: current, currentRoot: "/p/current", others: others, query: "")
        XCTAssertEqual(groups.map(\.projectRoot), ["/p/current", "/p/b", "/p/a"])
        XCTAssertEqual(groups[0].rows.map(\.title), ["c1"], "the current project is built from what the window knows now")
        XCTAssertEqual(groups[1].rows.map(\.title), ["b-new", "b-old"])
        XCTAssertEqual(groups[1].name, "b")
    }

    func testTheCurrentProjectIsListedEvenWithNoSessionsButNotWhenAQueryMatchesNothing() {
        let others = [summary("fix the build", "/p/b", 10)]
        XCTAssertEqual(IDEAISessions.groups(current: [], currentRoot: "/p/current", others: others, query: "").map(\.projectRoot), ["/p/current", "/p/b"])
        XCTAssertEqual(IDEAISessions.groups(current: [], currentRoot: "/p/current", others: others, query: "build").map(\.projectRoot), ["/p/b"])
        XCTAssertTrue(IDEAISessions.groups(current: [], currentRoot: "/p/current", others: others, query: "zzzz").isEmpty)
    }

    func testSessionsWithNoProjectAreSkippedAndPathsAreComparedStandardized() {
        let others = [summary("orphan", nil, 5), summary("same project", "/p/current/./", 4)]
        let groups = IDEAISessions.groups(current: [], currentRoot: "/p/current", others: others, query: "")
        XCTAssertEqual(groups.map(\.projectRoot), ["/p/current"], "a path spelled differently is still the current project")
    }

    func testNoProjectOpenListsOnlyOtherProjects() {
        let groups = IDEAISessions.groups(current: [], currentRoot: nil, others: [summary("x", "/p/a", 1)], query: "")
        XCTAssertEqual(groups.map(\.projectRoot), ["/p/a"])
    }

    func testModelNamesReadWell() {
        XCTAssertEqual(IDEAIModelNames.display(provider: .anthropic, model: "claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(IDEAIModelNames.display(provider: .anthropic, model: "claude-custom"), "claude-custom")
        XCTAssertEqual(IDEAIModelNames.display(provider: .ollama, model: "qwen3:8b"), "qwen3:8b")
        XCTAssertEqual(IDEAIModelNames.display(provider: .ollama, model: ""), "Ollama")
        XCTAssertEqual(IDEAIModelNames.effortLabel("high"), "High")
        XCTAssertNil(IDEAIModelNames.effortLabel("off"))
    }
}
