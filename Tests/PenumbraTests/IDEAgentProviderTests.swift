import AgentKit
import Foundation
import XCTest
@testable import Umbra

/// Answers each request from a closure keyed on its path, so no network is used.
private final class FakeOllamaTransport: LLMTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requestPaths: [String] = []
    var tags: Data
    var shows: [String: Data]
    var unreachable = false

    init(tags: String, shows: [String: String] = [:]) {
        self.tags = Data(tags.utf8)
        self.shows = shows.mapValues { Data($0.utf8) }
    }

    var paths: [String] { lock.withLock { requestPaths } }

    func open(_ request: URLRequest) async throws -> LLMHTTPResponse {
        let (status, data) = try await fetch(request)
        return LLMHTTPResponse(status: status, lines: AsyncThrowingStream { continuation in
            continuation.yield(String(decoding: data, as: UTF8.self))
            continuation.finish()
        })
    }

    func fetch(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        lock.withLock { requestPaths.append(request.url?.path ?? "") }
        if unreachable { throw URLError(.cannotConnectToHost) }
        switch request.url?.path {
        case "/api/tags": return (200, tags)
        case "/api/show":
            let body = (try? JSONValue(parsing: String(decoding: request.httpBody ?? Data(), as: UTF8.self))) ?? .null
            return (200, shows[body["model"]?.stringValue ?? ""] ?? Data("{}".utf8))
        default: return (404, Data())
        }
    }
}

private let tagsJSON = """
{"models":[
 {"name":"coder:7b","size":4000000000,"details":{"parameter_size":"7B","quantization_level":"Q4_K_M"}},
 {"name":"chat-only:1b","size":1000000000,"details":{"parameter_size":"1B","quantization_level":"Q8_0"}},
 {"name":"thinker:27b","size":16000000000,"details":{"parameter_size":"27B","quantization_level":"Q4_K_M"}}
]}
"""

private let showsJSON: [String: String] = [
    "coder:7b": #"{"capabilities":["completion","tools"],"model_info":{"qwen2.context_length":32768}}"#,
    "chat-only:1b": #"{"capabilities":["completion"],"model_info":{"llama.context_length":8192}}"#,
    "thinker:27b": #"{"capabilities":["completion","tools","thinking"],"model_info":{"qwen35.context_length":262144}}"#,
]

@MainActor
final class IDEAgentProviderTests: XCTestCase {
    private func makeSettings(transport: any LLMTransport = FakeOllamaTransport(tags: #"{"models":[]}"#)) -> IDEAgentSettings {
        IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!,
            keyStore: IDEAgentMemoryKeyStore(), transport: transport)
    }

    func testEachProviderKeepsItsOwnUrlModelAndReasoning() {
        let settings = makeSettings()
        settings.model = "gpt-x"
        settings.reasoningEffort = "high"

        settings.provider = .ollama
        XCTAssertEqual(settings.baseURL, "http://localhost:11434")
        XCTAssertEqual(settings.model, "")
        XCTAssertEqual(settings.reasoningEffort, "off", "a local model thinks only when asked")
        settings.model = "coder:7b"

        settings.provider = .openAIResponses
        XCTAssertEqual(settings.model, "gpt-x")
        XCTAssertEqual(settings.reasoningEffort, "high")
        settings.provider = .chatCompletions
        XCTAssertEqual(settings.model, "gpt-5", "Chat Completions has its own, untouched")
    }

    func testProviderChoicesPersistAcrossLaunches() {
        let defaults = UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        settings.provider = .ollama
        settings.model = "coder:7b"
        settings.localContextLength = 65_536

        let reloaded = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        XCTAssertEqual(reloaded.provider, .ollama)
        XCTAssertEqual(reloaded.model, "coder:7b")
        XCTAssertEqual(reloaded.localContextLength, 65_536)
    }

    func testAServerOnThisMacNeedsNeitherAKeyNorConsent() {
        let settings = makeSettings()
        settings.provider = .ollama
        settings.model = "coder:7b"
        XCTAssertTrue(settings.isLocalEndpoint)
        XCTAssertTrue(settings.hasAcceptedDisclosure, "nothing leaves the Mac")
        XCTAssertFalse(settings.requiresAPIKey)
        XCTAssertNil(settings.setupHint)
        XCTAssertNoThrow(try settings.makeClient())

        // The same holds for a local OpenAI-compatible server such as LM Studio.
        settings.provider = .chatCompletions
        settings.baseURL = "http://127.0.0.1:1234/v1"
        settings.model = "local"
        XCTAssertTrue(settings.hasAcceptedDisclosure && !settings.requiresAPIKey)
        XCTAssertNoThrow(try settings.makeClient())
    }

    func testARemoteServerStillNeedsConsentAndAKeyEvenForOllama() {
        let settings = makeSettings()
        settings.provider = .ollama
        settings.baseURL = "https://ollama.example.com"
        settings.model = "coder:7b"
        XCTAssertFalse(settings.isLocalEndpoint)
        XCTAssertFalse(settings.hasAcceptedDisclosure, "a remote Ollama is somebody else's server")
        XCTAssertFalse(settings.requiresAPIKey, "a key is optional there (a proxy may want a bearer token)")
        settings.acceptDisclosure()
        XCTAssertTrue(settings.hasAcceptedDisclosure)

        settings.provider = .openAIResponses
        settings.baseURL = "https://api.openai.com/v1"
        XCTAssertTrue(settings.requiresAPIKey)
        XCTAssertEqual(settings.setupHint, "Add an API key in the agent settings.")
        XCTAssertThrowsError(try settings.makeClient()) {
            XCTAssertEqual($0 as? IDEAgentSettings.ConfigurationError, .missingAPIKey(host: "api.openai.com"))
        }
    }

    func testLookalikeHostsAreNotLocal() {
        let settings = makeSettings()
        for url in ["http://localhost.evil.com", "http://192.168.1.5:11434", "http://my-localhost.example", "https://evil.com/localhost"] {
            settings.baseURL = url
            XCTAssertFalse(settings.isLocalEndpoint, url)
        }
        settings.baseURL = "http://localhost:11434"
        XCTAssertTrue(settings.isLocalEndpoint)
        settings.baseURL = "http://[::1]:11434"
        XCTAssertTrue(settings.isLocalEndpoint)
    }

    func testEachProviderBuildsItsOwnClient() throws {
        let settings = makeSettings()
        settings.saveAPIKey("sk-test")
        XCTAssertTrue(try settings.makeClient() is OpenAIResponsesClient)
        settings.provider = .chatCompletions
        settings.saveAPIKey("sk-test")
        let openAI = try XCTUnwrap(settings.makeClient() as? OpenAIChatCompletionsClient)
        XCTAssertEqual(openAI.capabilities, .openAI, "the real OpenAI gets strict tools")
        settings.baseURL = "https://models.example.com/v1"
        settings.saveAPIKey("sk-other")
        let other = try XCTUnwrap(settings.makeClient() as? OpenAIChatCompletionsClient)
        XCTAssertEqual(other.capabilities, .compatible, "other servers get the conservative subset")
        settings.provider = .ollama
        settings.baseURL = "http://localhost:11434"
        settings.model = "coder:7b"
        XCTAssertTrue(try settings.makeClient() is OllamaClient)
    }

    func testOllamaModelsAreListedWithTheirCapabilitiesAndAUsableOneIsChosen() async throws {
        let transport = FakeOllamaTransport(tags: tagsJSON, shows: showsJSON)
        let settings = makeSettings(transport: transport)
        settings.provider = .ollama
        await settings.refreshOllamaModels()

        XCTAssertEqual(settings.ollamaModels.map(\.name), ["chat-only:1b", "coder:7b", "thinker:27b"])
        XCTAssertNil(settings.ollamaError)
        XCTAssertEqual(settings.model, "coder:7b", "the first model that can use tools, not the first model")
        XCTAssertEqual(transport.paths.filter { $0 == "/api/show" }.count, 3)
        XCTAssertEqual(IDEAgentOllamaLabel.title(settings.ollamaModels[0]), "chat-only:1b · 1B Q8_0 · 1 GB (no tool support)")
        XCTAssertEqual(IDEAgentOllamaLabel.title(settings.ollamaModels[1]), "coder:7b · 7B Q4_K_M · 4 GB")
    }

    func testAModelWithoutToolsIsRefusedBeforeAnythingIsSent() async throws {
        let settings = makeSettings(transport: FakeOllamaTransport(tags: tagsJSON, shows: showsJSON))
        settings.provider = .ollama
        await settings.refreshOllamaModels()
        settings.model = "chat-only:1b"
        XCTAssertThrowsError(try settings.makeClient()) {
            XCTAssertEqual($0 as? IDEAgentSettings.ConfigurationError, .modelCannotUseTools("chat-only:1b"))
        }
    }

    func testTheSavedModelSurvivesARefreshAndAMissingOneIsReplaced() async throws {
        let settings = makeSettings(transport: FakeOllamaTransport(tags: tagsJSON, shows: showsJSON))
        settings.provider = .ollama
        settings.model = "thinker:27b"
        await settings.refreshOllamaModels()
        XCTAssertEqual(settings.model, "thinker:27b")
        settings.model = "uninstalled:70b"
        await settings.refreshOllamaModels()
        XCTAssertEqual(settings.model, "coder:7b")
    }

    func testTheContextIsTheUsersCapLimitedByTheModelsOwnMaximumAndThinkingFollowsTheModel() async throws {
        let settings = makeSettings(transport: FakeOllamaTransport(tags: tagsJSON, shows: showsJSON))
        settings.provider = .ollama
        await settings.refreshOllamaModels()

        settings.model = "coder:7b"
        settings.localContextLength = 131_072
        XCTAssertEqual(settings.effectiveContextLength, 32_768, "the model supports 32K")
        settings.localContextLength = 16_384
        XCTAssertEqual(settings.effectiveContextLength, 16_384)
        let coder = try XCTUnwrap(settings.makeClient() as? OllamaClient)
        XCTAssertEqual(coder.contextLength, 16_384)
        XCTAssertFalse(coder.supportsThinking)

        settings.model = "thinker:27b"
        XCTAssertTrue(try XCTUnwrap(settings.makeClient() as? OllamaClient).supportsThinking)
        let before = settings.fingerprint
        settings.localContextLength = 65_536
        XCTAssertNotEqual(settings.fingerprint, before, "a new context means a new session (and a model reload)")
    }

    func testWhenOllamaIsNotRunningTheSettingsSayWhy() async throws {
        let transport = FakeOllamaTransport(tags: "{}")
        transport.unreachable = true
        let settings = makeSettings(transport: transport)
        settings.provider = .ollama
        await settings.refreshOllamaModels()
        XCTAssertEqual(settings.ollamaError, "Ollama isn't running at localhost:11434.")
        XCTAssertTrue(settings.ollamaModels.isEmpty)
        XCTAssertEqual(settings.setupHint, "Ollama isn't running at localhost:11434.")
    }

    func testNoInstalledModelsIsExplained() async throws {
        let settings = makeSettings(transport: FakeOllamaTransport(tags: #"{"models":[]}"#))
        settings.provider = .ollama
        await settings.refreshOllamaModels()
        XCTAssertEqual(settings.ollamaError, "No models are installed. Run `ollama pull <model>`.")
    }
}
