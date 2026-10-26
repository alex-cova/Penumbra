import AgentKit
import Foundation
import XCTest

@testable import Umbra

@MainActor
final class IDEAgentTabsTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var storeDirectory: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-tabs-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project", isDirectory: true)
        storeDirectory = base.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "one\ntwo\nthree\n".write(to: project.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    /// A controller whose n-th session talks to the n-th client, so each chat gets its own script.
    private func makeController(_ clients: [MockLLMClient], mode: PermissionMode = .acceptEdits) -> IDEAgentController {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        settings.mode = mode
        var next = 0
        let controller = IDEAgentController(
            settings: settings, store: SessionStore(directory: storeDirectory),
            clientFactory: { _ in
                defer { next += 1 }
                return clients[min(next, clients.count - 1)]
            })
        controller.attach(host: workspace)
        return controller
    }

    private func waitFor(_ message: String, timeout: Int = 800, _ condition: () -> Bool) async {
        for _ in 0..<timeout where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func send(_ conversation: IDEAgentConversation, _ text: String) {
        conversation.draft = text
        conversation.send()
    }

    private func disk(_ path: String) -> String? { try? String(contentsOf: project.appendingPathComponent(path), encoding: .utf8) }

    private func slow(_ text: String, seconds: Double = 1.5) -> MockTurn {
        MockTurn([.textDelta(text), .finished(.completed)], delayPerEvent: .milliseconds(Int(seconds * 1000)))
    }

    // MARK: - Tabs

    func testANewChatIsSelectedAndKeepsItsOwnDraft() {
        let controller = makeController([MockLLMClient(turns: [])])
        let first = controller.selected
        first.draft = "typed in the first"

        let second = controller.addConversation()
        XCTAssertEqual(controller.conversations.map(\.id), [first.id, second.id])
        XCTAssertEqual(controller.selected.id, second.id)
        XCTAssertEqual(controller.draft, "", "the forwarders follow the selection")

        controller.select(first.id)
        XCTAssertEqual(controller.draft, "typed in the first")
    }

    func testNewConversationReusesAnEmptyChatAndOtherwiseOpensATab() async throws {
        let controller = makeController([MockLLMClient(turns: [.text("hello")])])
        controller.newConversation()
        XCTAssertEqual(controller.conversations.count, 1, "an empty chat is not duplicated")

        send(controller.selected, "hi")
        await waitFor("the run ends") { !controller.isRunning }
        controller.newConversation()
        XCTAssertEqual(controller.conversations.count, 2)
        XCTAssertTrue(controller.selected.isEmpty)
        XCTAssertEqual(controller.conversations[0].entries.first?.text, "hi", "the first chat is untouched")
    }

    func testClearEmptiesTheChatInPlace() async {
        let controller = makeController([MockLLMClient(turns: [.text("hello")])])
        let tab = controller.selected.id
        send(controller.selected, "hi")
        await waitFor("the run ends") { !controller.isRunning }
        controller.clear()
        XCTAssertEqual(controller.conversations.count, 1)
        XCTAssertEqual(controller.selected.id, tab)
        XCTAssertTrue(controller.selected.isEmpty)
    }

    func testTwoChatsRunAtTheSameTimeWithTheirOwnTranscripts() async throws {
        let clientA = MockLLMClient(turns: [slow("answer from A")])
        let clientB = MockLLMClient(turns: [slow("answer from B")])
        let controller = makeController([clientA, clientB])
        let a = controller.selected
        let b = controller.addConversation()

        send(a, "question A")
        send(b, "question B")
        await waitFor("both are running at once") { a.isRunning && b.isRunning }
        XCTAssertTrue(a.isRunning && b.isRunning)
        await waitFor("both finish", timeout: 1000) { !a.isRunning && !b.isRunning }

        XCTAssertEqual(a.entries.map(\.text), ["question A", "answer from A"])
        XCTAssertEqual(b.entries.map(\.text), ["question B", "answer from B"])
        XCTAssertEqual(controller.history.count, 2, "each is saved under its own id")
        XCTAssertNotEqual(a.conversationID, b.conversationID)
        XCTAssertEqual(clientA.requests.count, 1)
        XCTAssertEqual(clientB.requests.count, 1)
    }

    func testAReplyInABackgroundChatIsMarkedUnreadUntilItIsSelected() async {
        let controller = makeController([MockLLMClient(turns: [.text("done")])])
        let first = controller.selected
        controller.addConversation()
        send(first, "work")
        await waitFor("the background run ends") { !first.isRunning }

        XCTAssertTrue(first.isUnread)
        XCTAssertFalse(controller.selected.isUnread)
        controller.select(first.id)
        XCTAssertFalse(first.isUnread)
    }

    func testAChatWaitingForAnApprovalSaysSo() async throws {
        let controller = makeController([
            MockLLMClient(turns: [.toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"echo hi"}"#)), .text("done")])
        ])
        let chat = controller.selected
        send(chat, "run it")
        await waitFor("the approval is open") { chat.entries.contains { $0.approval != nil } }
        XCTAssertTrue(chat.isAwaitingUser)

        chat.decide(callID: "c1", .deny(note: nil))
        XCTAssertFalse(chat.isAwaitingUser)
        await waitFor("the run ends") { !chat.isRunning }
    }

    func testClosingATabEndsItsRunAndSelectsANeighbor() async {
        let controller = makeController([MockLLMClient(turns: [slow("a")]), MockLLMClient(turns: [])])
        let a = controller.selected
        let b = controller.addConversation()
        let c = controller.addConversation()
        send(a, "go")
        await waitFor("a runs") { a.isRunning }

        controller.select(b.id)
        controller.close(b.id)
        XCTAssertEqual(controller.conversations.map(\.id), [a.id, c.id])
        XCTAssertEqual(controller.selected.id, c.id, "the tab that took its place")

        controller.close(a.id)
        await waitFor("a stops") { !a.isRunning }
        XCTAssertEqual(controller.conversations.map(\.id), [c.id])
        XCTAssertEqual(controller.selected.id, c.id)
    }

    func testClosingTheLastTabEmptiesItInstead() async {
        let controller = makeController([MockLLMClient(turns: [.text("x")])])
        send(controller.selected, "hi")
        await waitFor("done") { !controller.isRunning }
        let tab = controller.selected.id

        controller.close(tab)
        XCTAssertEqual(controller.conversations.count, 1)
        XCTAssertEqual(controller.selected.id, tab)
        XCTAssertTrue(controller.selected.isEmpty)
    }

    func testCycleAndCloseOthers() {
        let controller = makeController([MockLLMClient(turns: [])])
        let a = controller.selected
        let b = controller.addConversation()
        let c = controller.addConversation()

        controller.selectNeighbor(1)
        XCTAssertEqual(controller.selected.id, a.id, "wraps around")
        controller.selectNeighbor(-1)
        XCTAssertEqual(controller.selected.id, c.id)

        controller.closeOthers(keeping: b.id)
        XCTAssertEqual(controller.conversations.map(\.id), [b.id])
        XCTAssertEqual(controller.selected.id, b.id)
    }

    // MARK: - Titles

    func testATabIsNamedAfterItsFirstMessageAndTheUserCanRenameIt() async {
        let controller = makeController([MockLLMClient(turns: [.text("ok")])])
        let chat = controller.selected
        XCTAssertEqual(chat.title, "New Chat")

        send(chat, "Refactor the parser to use a lookup table instead of a long switch statement\nplus details")
        await waitFor("done") { !chat.isRunning }
        XCTAssertEqual(chat.title, "Refactor the parser to use a lookup…")

        controller.rename(chat.id, to: "  Parser work ")
        XCTAssertEqual(chat.title, "Parser work")
        controller.rename(chat.id, to: "   ")
        XCTAssertTrue(chat.title.hasPrefix("Refactor"), "an empty name goes back to the first message")
    }

    func testARenameIsSavedWithTheConversation() async {
        let controller = makeController([MockLLMClient(turns: [.text("ok")])])
        send(controller.selected, "hello there")
        await waitFor("done") { !controller.isRunning }

        controller.rename(controller.selected.id, to: "My chat")
        await waitFor("the history shows the name") { controller.history.first?.title == "My chat" }
    }

    // MARK: - Resume

    private func savedConversation(_ text: String) async -> UUID {
        let controller = makeController([MockLLMClient(turns: [.text("reply to \(text)")])])
        // A fresh controller would bring back the latest saved conversation on its first send.
        controller.newConversation()
        send(controller.selected, text)
        await waitFor("saved") { !controller.isRunning && !controller.history.isEmpty }
        return controller.conversationID
    }

    func testResumeFillsAnEmptyChatButOpensATabOverAUsedOne() async throws {
        let first = await savedConversation("first topic")
        let second = await savedConversation("second topic")

        let controller = makeController([MockLLMClient(turns: [])])
        controller.refreshHistory()
        controller.resume(first)
        XCTAssertEqual(controller.conversations.count, 1, "the empty chat took it")
        XCTAssertEqual(controller.entries.first?.text, "first topic")

        controller.resume(second)
        XCTAssertEqual(controller.conversations.count, 2, "the used chat is left alone")
        XCTAssertEqual(controller.entries.first?.text, "second topic")
        XCTAssertEqual(controller.conversations[0].entries.first?.text, "first topic")
    }

    func testResumingAConversationThatIsOpenSelectsItsTab() async throws {
        let id = await savedConversation("topic")
        let controller = makeController([MockLLMClient(turns: [])])
        controller.resume(id)
        let tab = controller.selected.id
        controller.addConversation()

        controller.resume(id)
        XCTAssertEqual(controller.selected.id, tab)
        XCTAssertEqual(controller.conversations.count, 2, "no duplicate tab")
    }

    func testDeletingASavedConversationClosesTheTabShowingIt() async throws {
        let id = await savedConversation("topic")
        let controller = makeController([MockLLMClient(turns: [])])
        controller.resume(id)
        controller.addConversation()
        XCTAssertEqual(controller.conversations.count, 2)

        controller.deleteConversation(id)
        XCTAssertEqual(controller.conversations.count, 1)
        XCTAssertTrue(controller.history.isEmpty)
    }

    // MARK: - Restoring a window's tabs

    func testSavedTabsComeBackAndOnlyTheSelectedOneIsReadAtOnce() async throws {
        let first = await savedConversation("alpha topic")
        let second = await savedConversation("beta topic")
        let third = await savedConversation("gamma topic")

        let controller = makeController([MockLLMClient(turns: [.text("more")])])
        controller.restoreTabs([first, second, UUID(), third], selected: second)

        XCTAssertEqual(controller.conversations.count, 3, "the conversation that was never saved is skipped")
        XCTAssertEqual(controller.selected.conversationID, second)
        XCTAssertEqual(controller.selected.entries.first?.text, "beta topic")
        let others = controller.conversations.filter { $0.id != controller.selectedID }
        XCTAssertTrue(others.allSatisfy { $0.entries.isEmpty && $0.pendingLoadID != nil }, "not read from disk yet")
        XCTAssertEqual(others.map(\.title).sorted(), ["alpha topic", "gamma topic"], "a pending tab still has its name")

        controller.select(try XCTUnwrap(others.first { $0.conversationID == first }).id)
        XCTAssertEqual(controller.selected.entries.first?.text, "alpha topic", "it loads when it is shown")
        XCTAssertNil(controller.selected.pendingLoadID)
    }

    func testSendingInAPendingTabLoadsItFirst() async throws {
        let id = await savedConversation("old topic")
        let client = MockLLMClient(turns: [.text("continued")])
        let controller = makeController([client])
        let other = await savedConversation("other topic")
        controller.restoreTabs([id, other], selected: other)
        let pending = try XCTUnwrap(controller.conversations.first { $0.conversationID == id })
        XCTAssertNotNil(pending.pendingLoadID)

        send(pending, "and then?")
        await waitFor("the run ends") { !pending.isRunning }
        XCTAssertEqual(pending.entries.map(\.text).prefix(2), ["old topic", "reply to old topic"])
        XCTAssertEqual(client.requests.first?.items.count, 3, "the earlier exchange went back to the model")
    }

    func testAPendingTabWhoseFileIsGoneBecomesAnEmptyChat() async throws {
        let id = await savedConversation("topic")
        let other = await savedConversation("other")
        let controller = makeController([MockLLMClient(turns: [])])
        controller.restoreTabs([id, other], selected: other)
        let pending = try XCTUnwrap(controller.conversations.first { $0.conversationID == id })
        SessionStore(directory: storeDirectory).delete(id, projectRoot: project.path)

        controller.select(pending.id)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(pending.title, "New Chat")
    }

    func testTheTabsAWindowKeepsAreTheSavedOnesAndTheSelection() async throws {
        let first = await savedConversation("alpha")
        let controller = makeController([MockLLMClient(turns: [.text("x")])])
        controller.resume(first)
        let added = controller.addConversation()
        send(added, "beta")
        await waitFor("saved") { !added.isRunning && controller.history.count == 2 }
        controller.addConversation()  // empty: nothing to restore

        let kept = controller.restorableTabs
        XCTAssertEqual(kept.ids, [first, added.conversationID])
        XCTAssertNil(kept.selected, "the selected chat is the empty one, which is not saved")
        controller.select(added.id)
        XCTAssertEqual(controller.restorableTabs.selected, added.conversationID)
    }

    // MARK: - The edit guard

    func testAnEditToAFileAnotherRunningChatIsChangingAsksFirst() async throws {
        let editA = MockLLMClient(turns: [
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            slow("still working on it", seconds: 1.5),
        ])
        let editB = MockLLMClient(turns: [
            .toolCalls((id: "r2", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e2", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"three","new_string":"3"}"#)),
            .text("done"),
        ])
        let controller = makeController([editA, editB])
        let a = controller.selected
        let b = controller.addConversation()
        send(a, "change two")
        await waitFor("A has edited the file") { self.disk("A.txt") == "one\n2\nthree\n" }
        XCTAssertTrue(a.isRunning, "A's run is still going")
        XCTAssertEqual(controller.fileClaims.claimedPaths, ["A.txt"])

        send(b, "change three")
        await waitFor("B is asked") { b.entries.contains { $0.approval != nil } }
        let request = try XCTUnwrap(b.entries.compactMap(\.approval).first)
        XCTAssertTrue(request.notes.contains { $0.contains("is changing this file in its current run") && $0.contains("change two") })
        XCTAssertEqual(disk("A.txt"), "one\n2\nthree\n", "B has not edited it")

        b.decide(callID: request.callID, .approve)
        await waitFor("B finishes", timeout: 1000) { !b.isRunning }
        XCTAssertEqual(disk("A.txt"), "one\n2\n3\n", "once approved, the edit lands on top of A's")
        await waitFor("A finishes", timeout: 1000) { !a.isRunning }
        XCTAssertTrue(controller.fileClaims.claimedPaths.isEmpty, "the claims end with the runs")
    }

    func testAChatsClaimsEndWhenItIsStoppedOrClosed() async throws {
        let client = MockLLMClient(turns: [
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            slow("working", seconds: 3),
        ])
        let controller = makeController([client, MockLLMClient(turns: [])])
        let a = controller.selected
        controller.addConversation()
        send(a, "go")
        await waitFor("claimed") { !controller.fileClaims.claimedPaths.isEmpty }

        controller.close(a.id)
        XCTAssertTrue(controller.fileClaims.claimedPaths.isEmpty)
    }

    func testClaimsAreNormalizedAndOwnedByTheirChat() {
        let claims = IDEAgentFileClaims()
        let a = UUID(), b = UUID()
        XCTAssertNil(claims.claim(["src/A.java", "docs/x.md"], for: a, title: "A"))
        XCTAssertEqual(claims.claim(["./src/../src/A.java"], for: b, title: "B")?.title, "A", "the same file by another spelling")
        XCTAssertNil(claims.claim(["src/A.java"], for: a, title: "A"), "a chat never conflicts with itself")
        XCTAssertNil(claims.claim(["other.txt"], for: b, title: "B"))
        XCTAssertEqual(claims.holder(of: "docs/x.md")?.tab, a)

        claims.release(tab: a)
        XCTAssertEqual(claims.claimedPaths, ["other.txt"])
        XCTAssertNil(claims.claim(["src/A.java"], for: b, title: "B"))
    }

    func testAConflictClaimsNothingForTheChatThatAsks() {
        let claims = IDEAgentFileClaims()
        let a = UUID(), b = UUID()
        _ = claims.claim(["one.txt"], for: a, title: "A")
        XCTAssertNotNil(claims.claim(["one.txt", "two.txt"], for: b, title: "B"))
        XCTAssertNil(claims.holder(of: "two.txt"), "a refused claim does not take the other files either")
    }

    // MARK: - The window session

    func testTheSessionKeepsTheChatsTheSelectionAndTheDockedPanel() async throws {
        let session = IDEWindowSession(
            isAgentPanelVisible: true, agentPanelWidth: 410, agentChats: [UUID(), UUID()], agentSelectedChat: nil)
        let decoded = try JSONDecoder().decode(IDEWindowSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.isAgentPanelVisible, true)
        XCTAssertEqual(decoded.agentPanelWidth, 410)
        XCTAssertEqual(decoded.agentChats, session.agentChats)
        XCTAssertNil(decoded.agentSelectedChat)
    }

    func testASessionFileFromBeforeChatTabsStillLoads() throws {
        let old = #"{"sidebarWidth": 250, "isSidebarVisible": true, "terminalHeight": 200}"#
        let decoded = try JSONDecoder().decode(IDEWindowSession.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.sidebarWidth, 250)
        XCTAssertNil(decoded.isAgentPanelVisible)
        XCTAssertNil(decoded.agentChats)
        XCTAssertNil(decoded.agentPanelWidth)
    }

    func testAWindowSessionCarriesTheAgentsWidthAndOnlyADockedPanel() {
        workspace.agentPanelWidth = 444
        workspace.agent.showPanel()
        workspace.agent.settings.opensAsPage = false
        XCTAssertEqual(workspace.makeSession().agentPanelWidth, 444)
        XCTAssertEqual(workspace.makeSession().isAgentPanelVisible, true)

        workspace.agent.settings.opensAsPage = true
        XCTAssertEqual(workspace.makeSession().isAgentPanelVisible, false, "a page over the editor is not reopened at launch")
        workspace.agent.settings.opensAsPage = false
    }

    func testTheWindowIsToldWhenTheChatsOrThePanelChangeButNotWhileRestoring() async {
        let controller = makeController([MockLLMClient(turns: [.text("x")])])
        var notifications = 0
        controller.onLayoutChanged = { notifications += 1 }

        let added = controller.addConversation()
        XCTAssertGreaterThan(notifications, 0, "a new chat")
        var count = notifications
        controller.select(controller.conversations[0].id)
        XCTAssertGreaterThan(notifications, count, "a different chat")
        count = notifications
        controller.close(added.id)
        XCTAssertGreaterThan(notifications, count, "a closed chat")
        count = notifications
        controller.isPanelVisible = true
        XCTAssertEqual(notifications, count + 1, "the panel")
        controller.isPanelVisible = true
        XCTAssertEqual(notifications, count + 1, "no change, no news")

        count = notifications
        controller.withoutLayoutNotifications {
            controller.addConversation()
            controller.isPanelVisible = false
        }
        XCTAssertEqual(notifications, count, "restoring a window is not a change to save")
        controller.addConversation()
        XCTAssertGreaterThan(notifications, count, "and notifications are back afterwards")
    }
}
