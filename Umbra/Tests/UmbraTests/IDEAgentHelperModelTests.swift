import AgentKit
import Foundation
import XCTest
@testable import Umbra

@MainActor
final class IDEAgentHelperModelTests: XCTestCase {
    private func makeSettings() -> (IDEAgentSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: "umbra.agent.helper.tests.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
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
