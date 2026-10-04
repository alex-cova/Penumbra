import AgentKit
import Foundation
import XCTest

@testable import Umbra

@MainActor
final class IDEAgentConversationTests: XCTestCase {
    private func makeSettings() -> IDEAgentSettings {
        IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
    }

    func testTheCacheKeyIsStableForAProjectAndDiffersPerConversation() {
        let root = URL(fileURLWithPath: "/tmp/some-project")
        let first = UUID()
        let key = IDEAgentConversation.cacheKey(root: root, conversationID: first)

        XCTAssertEqual(key, IDEAgentConversation.cacheKey(root: root, conversationID: first))
        XCTAssertNotEqual(key, IDEAgentConversation.cacheKey(root: root, conversationID: UUID()))
        XCTAssertNotEqual(
            key, IDEAgentConversation.cacheKey(root: URL(fileURLWithPath: "/tmp/other"), conversationID: first))
        XCTAssertTrue(key.contains(first.uuidString), "the key names the conversation, not a per-process hash")
    }

    func testAClearKeepsTheTabButStartsANewSavedConversation() {
        let controller = IDEAgentController(settings: makeSettings(), clientFactory: { _ in MockLLMClient(turns: []) })
        let tab = controller.selected.id
        let saved = controller.selected.conversationID

        controller.clear()

        XCTAssertEqual(controller.selected.id, tab, "the panel keeps showing the same tab")
        XCTAssertNotEqual(controller.selected.conversationID, saved, "a new conversation is saved under a new id")
    }

    func testTheControllerStartsWithOneSelectedConversation() {
        let controller = IDEAgentController(settings: makeSettings(), clientFactory: { _ in MockLLMClient(turns: []) })
        XCTAssertEqual(controller.conversations.count, 1)
        XCTAssertEqual(controller.selectedID, controller.conversations[0].id)
        XCTAssertTrue(controller.selected.isEmpty)
    }
}
