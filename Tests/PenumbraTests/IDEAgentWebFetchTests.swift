import AgentKit
import Foundation
import XCTest
@testable import Umbra

@MainActor
final class IDEAgentWebFetchTests: XCTestCase {
    private func makeSettings(_ suite: String = "umbra.webfetch.\(UUID().uuidString)") -> (IDEAgentSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        return (IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore()), defaults)
    }

    func testWebPagesAreOffByDefaultAndTheChoiceIsRememberedAndInTheFingerprint() {
        let (settings, defaults) = makeSettings()
        XCTAssertFalse(settings.webFetchEnabled)
        let off = settings.fingerprint
        settings.webFetchEnabled = true
        XCTAssertNotEqual(settings.fingerprint, off, "a change starts a new session")
        XCTAssertTrue(defaults.bool(forKey: "umbra.agent.webFetch"))

        let again = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        XCTAssertTrue(again.webFetchEnabled)
    }

    func testTheToolTheSessionOffersIsReadOnlyAndAsks() {
        let tool = WebFetchTool()
        XCTAssertEqual(tool.name, "web_fetch")
        XCTAssertEqual(tool.risk, .read)
        XCTAssertTrue(tool.asksUnlessAllowed)
        XCTAssertTrue(tool.honorsDenyRules)
    }
}
