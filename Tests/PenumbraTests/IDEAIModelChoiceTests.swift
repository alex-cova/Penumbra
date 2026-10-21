import AgentKit
import Foundation
import XCTest
@testable import Umbra

/// Answers Ollama's model list from memory, so no server is needed.
private final class ListTransport: LLMTransport, @unchecked Sendable {
    func open(_ request: URLRequest) async throws -> LLMHTTPResponse {
        let (status, data) = try await fetch(request)
        return LLMHTTPResponse(status: status, lines: AsyncThrowingStream { continuation in
            continuation.yield(String(decoding: data, as: UTF8.self))
            continuation.finish()
        })
    }

    func fetch(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        switch request.url?.path {
        case "/api/tags":
            return (200, Data(#"{"models":[{"name":"coder:7b","size":1},{"name":"chat-only:1b","size":1}]}"#.utf8))
        case "/api/show":
            let body = (try? JSONValue(parsing: String(decoding: request.httpBody ?? Data(), as: UTF8.self))) ?? .null
            let tools = body["model"]?.stringValue == "coder:7b"
            return (200, Data((tools ? #"{"capabilities":["completion","tools"]}"# : #"{"capabilities":["completion"]}"#).utf8))
        default:
            return (404, Data())
        }
    }
}

@MainActor
final class IDEAIModelChoiceTests: XCTestCase {
    private var project: URL!
    private var storeDirectory: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ai-choice-\(UUID().uuidString)", isDirectory: true)
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

    private func makeSettings(defaults: UserDefaults? = nil, transport: any LLMTransport = ListTransport()) -> IDEAgentSettings {
        IDEAgentSettings(
            defaults: defaults ?? UserDefaults(suiteName: "umbra.ai.tests.\(UUID().uuidString)")!,
            keyStore: IDEAgentMemoryKeyStore(), transport: transport)
    }

    // MARK: - Providers and keys

    func testAnthropicIsAProviderWithItsOwnEndpointModelAndEfforts() {
        let settings = makeSettings()
        XCTAssertEqual(settings.baseURL(for: .anthropic), "https://api.anthropic.com/v1")
        XCTAssertEqual(settings.model(for: .anthropic), "claude-opus-5-5")
        XCTAssertEqual(settings.endpointHost(for: .anthropic), "api.anthropic.com")
        XCTAssertTrue(IDEAgentProvider.anthropic.reasoningEfforts.contains("xhigh"))
        XCTAssertFalse(IDEAgentProvider.openAIResponses.reasoningEfforts.contains("xhigh"))
        XCTAssertTrue(settings.requiresAPIKey(for: .anthropic))
        XCTAssertFalse(settings.requiresAPIKey(for: .ollama))
        XCTAssertEqual(IDEAgentProvider.allCases.map(\.rawValue).sorted(), Set(IDEAgentProvider.allCases.map(\.rawValue)).sorted())
    }

    func testAKeyIsSavedPerProviderAndTheChoiceNeedsOneBeforeItIsReady() throws {
        let settings = makeSettings()
        let choice = IDEAIModelChoice(provider: .anthropic, model: "claude-sonnet-5-5")
        XCTAssertEqual(settings.setupHint(for: choice), "Add an API key in the agent settings.")
        XCTAssertThrowsError(try settings.makeClient(for: choice)) {
            XCTAssertEqual($0 as? IDEAgentSettings.ConfigurationError, .missingAPIKey(host: "api.anthropic.com"))
        }

        settings.saveAPIKey("sk-ant-test", for: .anthropic)
        XCTAssertTrue(settings.hasAPIKey(for: .anthropic))
        XCTAssertFalse(settings.hasAPIKey(for: .openAIResponses), "another host's key is not this one's")
        XCTAssertNil(settings.setupHint(for: choice))
        XCTAssertEqual(try settings.makeClient(for: choice).providerID, "anthropic")

        settings.removeAPIKey(for: .anthropic)
        XCTAssertFalse(settings.hasAPIKey(for: .anthropic))
    }

    func testTheRemoteEndpointNeedsConsentButOllamaDoesNot() {
        let settings = makeSettings()
        XCTAssertFalse(settings.hasAcceptedDisclosure(for: .anthropic))
        XCTAssertTrue(settings.hasAcceptedDisclosure(for: .ollama))
        settings.acceptDisclosure(for: .anthropic)
        XCTAssertTrue(settings.hasAcceptedDisclosure(for: .anthropic))
        XCTAssertFalse(settings.hasAcceptedDisclosure(for: .openAIResponses), "consent is per host")
    }

    // MARK: - Tools or not

    func testAModelWithoutToolsIsRefusedForCodeAndAllowedForChat() async throws {
        let settings = makeSettings()
        settings.provider = .ollama
        await settings.refreshOllamaModels()
        let choice = IDEAIModelChoice(provider: .ollama, model: "chat-only:1b")
        XCTAssertThrowsError(try settings.makeClient(for: choice, requiresTools: true)) {
            XCTAssertEqual($0 as? IDEAgentSettings.ConfigurationError, .modelCannotUseTools("chat-only:1b"))
        }
        XCTAssertEqual(try settings.makeClient(for: choice, requiresTools: false).providerID, "ollama")
        XCTAssertEqual(try settings.makeClient(for: IDEAIModelChoice(provider: .ollama, model: "coder:7b")).providerID, "ollama")
    }

    // MARK: - What a choice changes

    func testTheCurrentChoiceIsTheGlobalSettingsAndItsFingerprintMatches() {
        let settings = makeSettings()
        settings.provider = .anthropic
        settings.model = "claude-haiku-5-5"
        settings.reasoningEffort = "low"
        XCTAssertEqual(settings.currentChoice, IDEAIModelChoice(provider: .anthropic, model: "claude-haiku-5-5", reasoningEffort: "low"))
        XCTAssertEqual(settings.fingerprint, settings.fingerprint(for: settings.currentChoice))
        var other = settings.currentChoice
        other.model = "claude-opus-5-5"
        XCTAssertNotEqual(settings.fingerprint(for: other), settings.fingerprint)
        other = IDEAIModelChoice(provider: .openAIResponses, model: "gpt-5")
        XCTAssertNotEqual(settings.fingerprint(for: other), settings.fingerprint)
        XCTAssertEqual(settings.provider, .anthropic, "reading a choice never switches the global provider")
    }

    func testContextWindowsAndCostsComeFromTheChoicesModel() {
        let settings = makeSettings()
        XCTAssertEqual(settings.contextWindow(for: IDEAIModelChoice(provider: .anthropic, model: "claude-opus-5-5")), 1_000_000)
        XCTAssertEqual(settings.contextWindow(for: IDEAIModelChoice(provider: .anthropic, model: "claude-haiku-4-5")), 200_000)
        XCTAssertEqual(settings.contextWindow(for: IDEAIModelChoice(provider: .openAIResponses, model: "gpt-5")), 400_000)

        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, cachedInputTokens: 500_000)
        // 500k fresh at $4, 500k cached at $0.20, 1M output at $20.
        XCTAssertEqual(try XCTUnwrap(settings.cost(of: usage, for: IDEAIModelChoice(provider: .anthropic, model: "claude-opus-5-5"))), 22.1, accuracy: 0.0001)
        XCTAssertNil(settings.cost(of: usage, for: IDEAIModelChoice(provider: .ollama, model: "coder:7b")), "local models have no price")
        XCTAssertNil(settings.cost(of: usage, for: IDEAIModelChoice(provider: .anthropic, model: "claude-unknown-future")), "a model the table lacks has no price")
    }

    func testAnEditedPriceTableIsKeptButAnUntouchedOldDefaultGainsTheClaudeRows() {
        let suite = "umbra.ai.prices.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(IDEAgentPrices.supersededDefaultTexts[0], forKey: "umbra.agent.priceTable")
        XCTAssertEqual(makeSettings(defaults: defaults).priceTableText, IDEAgentPrices.defaultText)

        defaults.set("gpt-5 9 9 9", forKey: "umbra.agent.priceTable")
        XCTAssertEqual(makeSettings(defaults: defaults).priceTableText, "gpt-5 9 9 9")
    }

    func testAnAcpAgentRunsOnlyWhenTheChoiceNamesItAndItIsAllowed() {
        let settings = makeSettings()
        settings.addACPAgent(name: "Claude Code", commandLine: "claude-code-acp")
        let agent = settings.acpAgents[0]
        settings.setACPAllowed(false, agentID: agent.id)
        let choice = IDEAIModelChoice(provider: .anthropic, model: "m", acpAgentID: agent.id)
        XCTAssertNil(settings.acpAgent(for: choice), "not allowed yet")
        settings.setACPAllowed(true, agentID: agent.id)
        XCTAssertEqual(settings.acpAgent(for: choice)?.id, agent.id)
        XCTAssertNil(settings.acpAgent(for: IDEAIModelChoice(provider: .anthropic, model: "m")))
    }

    // MARK: - A chat with its own choice

    private func conversationController(settings: IDEAgentSettings, global: MockLLMClient) -> IDEAgentController {
        let controller = IDEAgentController(
            settings: settings, store: SessionStore(directory: storeDirectory), clientFactory: { _ in global })
        controller.attach(host: workspace)
        return controller
    }

    private func send(_ controller: IDEAgentController, _ text: String) async {
        controller.draft = text
        controller.send()
        for _ in 0..<500 where controller.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isRunning)
    }

    func testAChatWithAChoiceUsesItsClientAndModelWhileOthersFollowTheSettings() async throws {
        let settings = makeSettings()
        settings.acceptDisclosure(for: .anthropic)
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let global = MockLLMClient(turns: [.text("from settings")])
        let controller = conversationController(settings: settings, global: global)
        let chosen = MockLLMClient(turns: [.text("from the choice")])
        var asked: [IDEAIModelChoice] = []
        controller.choiceClientFactory = { _, choice in
            asked.append(choice)
            return chosen
        }

        // A chat with no choice follows the global settings.
        await send(controller, "one")
        XCTAssertEqual(global.requests.count, 1)
        XCTAssertTrue(asked.isEmpty)

        // A second chat picks a model for itself.
        controller.newChatChoice = IDEAIModelChoice(provider: .anthropic, model: "claude-sonnet-5-5", reasoningEffort: "high")
        controller.addConversation()
        await send(controller, "two")
        XCTAssertEqual(chosen.requests.count, 1)
        XCTAssertEqual(chosen.requests.first?.model, "claude-sonnet-5-5")
        XCTAssertEqual(chosen.requests.first?.reasoningEffort, "high")
        XCTAssertEqual(asked.map(\.model), ["claude-sonnet-5-5"])
        XCTAssertEqual(global.requests.count, 1, "the first chat's client was not used again")
        XCTAssertEqual(controller.selected.effectiveChoice.model, "claude-sonnet-5-5")
    }

    func testChangingTheChoiceStartsANewSessionThatKeepsTheConversation() async throws {
        let settings = makeSettings()
        settings.acceptDisclosure(for: .anthropic)
        let global = MockLLMClient(turns: [])
        let controller = conversationController(settings: settings, global: global)
        let first = MockLLMClient(turns: [.text("a")])
        let second = MockLLMClient(turns: [.text("b")])
        var clients = [first, second]
        controller.choiceClientFactory = { _, _ in clients.removeFirst() }

        controller.selected.modelChoice = IDEAIModelChoice(provider: .anthropic, model: "claude-opus-5-5")
        await send(controller, "hello")
        controller.selected.modelChoice = IDEAIModelChoice(provider: .anthropic, model: "claude-haiku-5-5")
        await send(controller, "again")

        XCTAssertEqual(first.requests.map(\.model), ["claude-opus-5-5"])
        XCTAssertEqual(second.requests.map(\.model), ["claude-haiku-5-5"])
        let items = second.requests[0].items
        XCTAssertTrue(items.contains { if case .assistant("a") = $0 { true } else { false } }, "the earlier answer is still in the history")
    }

    func testAChatWithoutConsentForItsEndpointCannotSendAndOneForThisMacCan() {
        let settings = makeSettings()
        let controller = conversationController(settings: settings, global: MockLLMClient(turns: []))
        controller.selected.modelChoice = IDEAIModelChoice(provider: .anthropic, model: "claude-opus-5-5")
        controller.draft = "hi"
        XCTAssertFalse(controller.selected.canSend, "api.anthropic.com was not accepted")
        controller.selected.modelChoice = IDEAIModelChoice(provider: .ollama, model: "coder:7b")
        XCTAssertTrue(controller.selected.canSend)
    }

    func testTheChoiceIsSavedWithTheChatAndComesBack() async throws {
        let settings = makeSettings()
        settings.acceptDisclosure(for: .anthropic)
        let controller = conversationController(settings: settings, global: MockLLMClient(turns: []))
        controller.choiceClientFactory = { _, _ in MockLLMClient(turns: [.text("saved")]) }
        let choice = IDEAIModelChoice(provider: .anthropic, model: "claude-sonnet-5-5", reasoningEffort: "low")
        controller.selected.modelChoice = choice
        await send(controller, "remember me")
        let id = controller.selected.conversationID

        let store = SessionStore(directory: storeDirectory)
        let snapshot = try XCTUnwrap(store.load(id, projectRoot: project.path))
        XCTAssertEqual(IDEAgentSavedTranscript.decode(snapshot.host).modelChoice, choice)

        let restored = conversationController(settings: settings, global: MockLLMClient(turns: []))
        restored.selected.load(snapshot)
        XCTAssertEqual(restored.selected.modelChoice, choice)
        // A chat saved before AI mode has none and follows the settings.
        var legacy = snapshot
        legacy.host = IDEAgentSavedTranscript.encode(entries: [], cost: 0)
        restored.selected.load(legacy)
        XCTAssertNil(restored.selected.modelChoice)
    }
}
