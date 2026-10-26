@_spi(HelperTesting) @testable import AgentKit
import Foundation
import XCTest
@testable import Umbra

@MainActor
final class IDEAgentHelperModelTests: XCTestCase {
    private var project: URL!
    private var storeDirectory: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-helper-\(UUID().uuidString)", isDirectory: true)
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

    private func send(_ controller: IDEAgentController, _ message: String) async {
        controller.draft = message
        controller.send()
        for _ in 0..<500 where controller.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isRunning, "the run should have finished")
    }
    private func makeSettings() -> (IDEAgentSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: "umbra.agent.helper.tests.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        return (settings, defaults)
    }

    func testParsingModelKeys() {
        let ollama = IDEAIModelChoice(parsing: "ollama:qwen3-coder:30b")
        XCTAssertEqual(ollama?.provider, .ollama)
        XCTAssertEqual(ollama?.model, "qwen3-coder:30b")
        XCTAssertEqual(IDEAIModelChoice(parsing: "mlx:my-org/my-model")?.provider, .mlx)
        XCTAssertEqual(IDEAIModelChoice(parsing: "anthropic:claude-haiku-5-5")?.model, "claude-haiku-5-5")
        XCTAssertNil(IDEAIModelChoice(parsing: "helper"), "a bare word is not a provider:model id")
        XCTAssertNil(IDEAIModelChoice(parsing: "bogus:model"), "unknown providers are refused")
        XCTAssertNil(IDEAIModelChoice(parsing: "ollama:"), "an empty model is refused")
        XCTAssertNil(IDEAIModelChoice(parsing: ""), "an empty key is refused")
        XCTAssertNil(IDEAIModelChoice(parsing: "ollama:-x"), "flags are refused")
    }

    func testHelperChoicePersistsAcrossLaunches() {
        let (settings, defaults) = makeSettings()
        XCTAssertNil(settings.helperChoice)
        XCTAssertFalse(settings.helperEnabled)
        settings.helperEnabled = true
        XCTAssertNotNil(settings.helperChoice, "enabling picks a choice to refine")
        settings.helperProvider = .ollama
        settings.helperModelName = "qwen3-coder:30b"
        XCTAssertEqual(settings.helperChoice?.model, "qwen3-coder:30b")

        let reloaded = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        XCTAssertEqual(reloaded.helperChoice, settings.helperChoice)
        XCTAssertTrue(reloaded.helperEnabled)

        settings.helperEnabled = false
        XCTAssertNil(IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore()).helperChoice)
    }

    func testHelperChoiceJoinsTheFingerprint() {
        let (settings, _) = makeSettings()
        let plain = settings.fingerprint(for: .init(provider: .openAIResponses, model: "gpt-x"))
        settings.helperChoice = IDEAIModelChoice(provider: .ollama, model: "qwen3-coder:30b")
        let withHelper = settings.fingerprint(for: .init(provider: .openAIResponses, model: "gpt-x"))
        XCTAssertNotEqual(plain, withHelper, "a helper change starts a new session")
        settings.helperChoice = IDEAIModelChoice(provider: .ollama, model: "other:7b")
        XCTAssertNotEqual(withHelper, settings.fingerprint(for: .init(provider: .openAIResponses, model: "gpt-x")))
    }

    func testResolverBuildsTheHelperClient() throws {
        let (settings, _) = makeSettings()
        settings.helperChoice = IDEAIModelChoice(provider: .ollama, model: "qwen3-coder:30b")
        let resolved = try settings.clientFactory().childClient(for: "helper")
        XCTAssertTrue(resolved.client is OllamaClient)
        XCTAssertEqual(resolved.model, "qwen3-coder:30b")
        XCTAssertEqual(resolved.contextWindow, settings.localContextLength)
    }

    func testResolverBuildsAnExplicitProviderKeyWithoutAHelper() throws {
        let (settings, _) = makeSettings()
        let resolved = try settings.clientFactory().childClient(for: "ollama:qwen3-coder:30b")
        XCTAssertTrue(resolved.client is OllamaClient)
        XCTAssertEqual(resolved.model, "qwen3-coder:30b")
    }

    func testExploreUsesTheHelperWhenItIsOn() async throws {
        let (settings, _) = makeSettings()
        settings.helperChoice = IDEAIModelChoice(provider: .ollama, model: "qwen3-coder:30b")
        let client = MockLLMClient(turns: [.text("hi")])
        let controller = IDEAgentController(
            settings: settings, store: SessionStore(directory: storeDirectory), clientFactory: { _ in client })
        controller.attach(host: workspace)
        await send(controller, "hi")

        let session = try XCTUnwrap(controller.currentSessionForTesting)
        let tools = await session.toolsForTesting
        let explore = try XCTUnwrap(tools.compactMap({ $0 as? ExploreTool }).first)
        XCTAssertEqual(explore.model, "helper", "explore is delegated to the helper when it is on")
        let configuration = await session.configurationForTesting
        let resolved = try configuration.makeChildClient?("helper")
        XCTAssertTrue(resolved?.client is OllamaClient, "the helper key resolves without touching the network")
        XCTAssertEqual(resolved?.model, "qwen3-coder:30b")
        XCTAssertNotNil(configuration.summaryClient, "summaries use the helper too")
    }

    func testExploreSharesTheParentWhenItIsOff() async throws {
        let (settings, _) = makeSettings()
        XCTAssertNil(settings.helperChoice)
        let client = MockLLMClient(turns: [.text("hi")])
        let controller = IDEAgentController(
            settings: settings, store: SessionStore(directory: storeDirectory), clientFactory: { _ in client })
        controller.attach(host: workspace)
        await send(controller, "hi")

        let session = try XCTUnwrap(controller.currentSessionForTesting)
        let tools = await session.toolsForTesting
        let explore = try XCTUnwrap(tools.compactMap({ $0 as? ExploreTool }).first)
        XCTAssertNil(explore.model, "explore shares the parent model when the helper is off")
        let configuration = await session.configurationForTesting
        XCTAssertThrowsError(try configuration.makeChildClient?("helper")) { error in
            XCTAssertEqual(error as? IDEAgentSettings.ConfigurationError, .noHelperModel)
        }
        XCTAssertNil(configuration.summaryClient)
    }

    private func makeFactory(
        ollamaModels: [OllamaModel] = [],
        helper: IDEAIModelChoice? = IDEAIModelChoice(provider: .ollama, model: "qwen3-coder:30b")
    ) -> IDEAgentClientFactory {
        IDEAgentClientFactory(
            baseURLs: [:], keyStore: IDEAgentMemoryKeyStore(), transport: URLSessionTransport(),
            ollamaModels: ollamaModels, installedMLXModels: [], localContextLength: 32_768,
            contextWindowOverride: 0, appleStatuses: [:], appleWindows: [:],
            hostedContextWindows: IDEAgentSettings.hostedContextWindows, helper: helper)
    }

    func testGateRefusesAModelWithoutToolSupport() {
        let factory = makeFactory(ollamaModels: [OllamaModel(
            name: "qwen3-coder:30b", parameterSize: nil, quantization: nil, sizeBytes: 0,
            capabilities: ["completion"], contextLength: 32_768)])
        let issue = factory.helperIssue()
        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.contains("no tool support") == true, issue ?? "")
        XCTAssertThrowsError(try factory.childClient(for: "helper")) { error in
            XCTAssertEqual(error as? IDEAgentSettings.ConfigurationError, .helperUnavailable(issue ?? ""))
        }
    }

    func testGateRefusesASmallWindow() {
        let factory = makeFactory(ollamaModels: [OllamaModel(
            name: "qwen3-coder:30b", parameterSize: nil, quantization: nil, sizeBytes: 0,
            capabilities: ["tools"], contextLength: 8_192)])
        let issue = factory.helperIssue()
        XCTAssertNotNil(issue)
        XCTAssertTrue(issue?.contains("below") == true, issue ?? "")
        XCTAssertThrowsError(try factory.childClient(for: "helper"))
    }

    func testGateAcceptsAnUnknownModel() throws {
        let factory = makeFactory()
        XCTAssertNil(factory.helperIssue(), "with no list loaded, the request decides")
        XCTAssertTrue(try factory.childClient(for: "helper").client is OllamaClient)
    }

    func testADeletedHelperFallsBackWithANotice() async throws {
        let (settings, _) = makeSettings()
        settings.helperChoice = IDEAIModelChoice(provider: .mlx, model: "deleted-model-xyz")
        XCTAssertNotNil(settings.helperIssue, "a model that was never downloaded fails the gate")
        let client = MockLLMClient(turns: [.text("hi")])
        let controller = IDEAgentController(
            settings: settings, store: SessionStore(directory: storeDirectory), clientFactory: { _ in client })
        controller.attach(host: workspace)
        await send(controller, "hi")

        let entries = controller.selected.entries
        let notice = entries.first { $0.kind == .notice && $0.text.contains("Helper model") }
        XCTAssertNotNil(notice, "the session says the helper is ignored")
        let session = try XCTUnwrap(controller.currentSessionForTesting)
        let tools = await session.toolsForTesting
        XCTAssertNil(tools.compactMap({ $0 as? ExploreTool }).first?.model, "explore shares the parent")
        let deletedConfiguration = await session.configurationForTesting
        XCTAssertNil(deletedConfiguration.summaryClient)
    }

    func testResolverErrors() {
        let (settings, _) = makeSettings()
        XCTAssertThrowsError(try settings.clientFactory().childClient(for: "helper")) { error in
            XCTAssertEqual(error as? IDEAgentSettings.ConfigurationError, .noHelperModel)
        }
        XCTAssertThrowsError(try settings.clientFactory().childClient(for: "bogus:model")) { error in
            XCTAssertEqual(error as? IDEAgentSettings.ConfigurationError, .unknownModel("bogus:model"))
        }
        settings.helperChoice = IDEAIModelChoice(provider: .ollama, model: "qwen3-coder:30b")
        XCTAssertThrowsError(try settings.clientFactory().childClient(for: "bogus:model")) { error in
            XCTAssertEqual(error as? IDEAgentSettings.ConfigurationError, .unknownModel("bogus:model"))
        }
    }
}
