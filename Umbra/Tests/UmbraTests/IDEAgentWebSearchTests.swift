import AgentKit
import XCTest
@testable import Umbra

@MainActor
final class IDEAgentWebSearchTests: XCTestCase {
    private func settings() -> (IDEAgentSettings, IDEAgentMemoryKeyStore) {
        let defaults = UserDefaults(suiteName: "umbra.websearch.\(UUID().uuidString)")!
        let store = IDEAgentMemoryKeyStore()
        return (IDEAgentSettings(defaults: defaults, keyStore: store), store)
    }

    func testWebSearchStaysOffWithoutAKeyAndTheFingerprintTracksBoth() throws {
        let (settings, store) = settings()
        let off = settings.fingerprint
        XCTAssertFalse(settings.webSearchEnabled)
        XCTAssertNil(IDEAgentWebSearch.tool(settings: settings))

        settings.webSearchEnabled = true
        let enabledWithoutKey = settings.fingerprint
        XCTAssertNil(IDEAgentWebSearch.tool(settings: settings))
        XCTAssertNotEqual(enabledWithoutKey, off)

        settings.saveAPIKey("sk-model")
        settings.saveWebSearchKey("brave-key")
        let tool = IDEAgentWebSearch.tool(settings: settings)
        XCTAssertEqual(tool?.name, "web_search")
        XCTAssertNotEqual(settings.fingerprint, enabledWithoutKey)
        XCTAssertEqual(try store.load(account: IDEAgentSettings.webSearchAccount), "brave-key")
        XCTAssertEqual(try store.load(account: settings.endpointHost), "sk-model")

        settings.removeWebSearchKey()
        XCTAssertNil(IDEAgentWebSearch.tool(settings: settings))
        XCTAssertNotEqual(settings.fingerprint, off)
        XCTAssertNil(try store.load(account: IDEAgentSettings.webSearchAccount))
    }

    func testTheChoiceIsRemembered() {
        let defaults = UserDefaults(suiteName: "umbra.websearch.\(UUID().uuidString)")!
        defaults.set(true, forKey: "umbra.agent.webSearch")
        let store = IDEAgentMemoryKeyStore()
        let settings = IDEAgentSettings(defaults: defaults, keyStore: store)
        XCTAssertTrue(settings.webSearchEnabled)
    }

    func testTheCardTitleIsTheQuery() {
        XCTAssertEqual(
            IDEAgentToolSummary.title(name: "web_search", arguments: #"{"query":"swift actors"}"#),
            "web_search  “swift actors”")
        XCTAssertEqual(IDEAgentToolSummary.title(name: "web_search", arguments: "{}"), "web_search")
    }
}
