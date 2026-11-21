import Foundation
import UmbraAgentSupport
import XCTest
@testable import Umbra

/// Counts the reads of a secret. `contains` is the attribute lookup that cannot prompt; `load` is a real read.
private final class CountingKeyStore: IDEAgentKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]
    private(set) var loads: [String] = []

    func load(account: String) throws -> String? {
        lock.withLock {
            loads.append(account)
            return keys[account]
        }
    }

    func contains(account: String) throws -> Bool { lock.withLock { keys[account]?.isEmpty == false } }

    func save(_ key: String, account: String) throws { lock.withLock { keys[account] = key } }

    func delete(account: String) throws { lock.withLock { keys[account] = nil } }
}

/// Umbra reads an API key only when the API mode builds a client for a send: never to fill in the UI, the
/// setup hint or the session fingerprint, so opening a window cannot raise a Keychain prompt.
@MainActor
final class IDEAgentKeyStateTests: XCTestCase {
    private func settings(_ store: CountingKeyStore) -> IDEAgentSettings {
        IDEAgentSettings(defaults: UserDefaults(suiteName: "umbra.keystate.\(UUID().uuidString)")!, keyStore: store)
    }

    func testCheckingForSavedKeysReadsNoSecret() throws {
        let store = CountingKeyStore()
        let settings = settings(store)
        settings.webSearchEnabled = true
        let host = settings.endpointHost(for: .anthropic)
        try store.save("sk-ant-test", account: host)
        try store.save("brave", account: IDEAgentSettings.webSearchAccount)

        XCTAssertTrue(settings.hasAPIKey(for: .anthropic))
        XCTAssertFalse(settings.hasAPIKey(for: .openAIResponses))
        XCTAssertTrue(settings.hasWebSearchKey)
        _ = settings.setupHint
        _ = settings.setupHint(for: IDEAIModelChoice(provider: .anthropic, model: "claude-sonnet-5-5"))
        _ = settings.fingerprint
        settings.refreshKeyState()

        XCTAssertEqual(store.loads, [], "only a send may read a key")
        XCTAssertEqual(settings.apiKey(for: .anthropic), "sk-ant-test")
        XCTAssertEqual(store.loads, [host])
    }

    func testMetaModelsAreNotFetchedWithoutASavedKey() async {
        let store = CountingKeyStore()
        let settings = settings(store)
        await settings.refreshMetaModels()
        XCTAssertEqual(store.loads, [])
    }
}
