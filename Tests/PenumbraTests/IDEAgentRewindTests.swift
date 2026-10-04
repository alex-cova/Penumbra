import AgentKit
import Foundation
import XCTest

@testable import Umbra

final class IDEAgentRewindTargetTests: XCTestCase {
    private func user(_ text: String, at index: Int?) -> IDEAgentEntry {
        var entry = IDEAgentEntry(kind: .user, text: text)
        entry.itemIndex = index
        return entry
    }

    private func changes(run: UUID, files: Int, reverted: Bool = false) -> IDEAgentEntry {
        var entry = IDEAgentEntry(kind: .changes, text: "")
        entry.run = run
        entry.fileChanges = (0..<files).map { IDEAgentFileChange(path: "f\($0).txt", original: "x") }
        entry.isReverted = reverted
        return entry
    }

    func testTargetsAreNewestFirstWithWhatComesAfterEach() {
        let r1 = UUID(), r2 = UUID()
        let entries = [
            user("one", at: 0), IDEAgentEntry(kind: .assistant, text: "a"), changes(run: r1, files: 2),
            user("two", at: 4), changes(run: r2, files: 1),
            user("three", at: 8), IDEAgentEntry(kind: .assistant, text: "c"),
        ]
        let targets = IDEAgentRewind.targets(in: entries)
        XCTAssertEqual(targets.map(\.text), ["three", "two", "one"])
        XCTAssertEqual(targets[0].runs, [])
        XCTAssertEqual(targets[0].laterMessages, 0)
        XCTAssertEqual(targets[1].runs, [r2])
        XCTAssertEqual(targets[1].files, 1)
        XCTAssertEqual(targets[1].laterMessages, 1)
        XCTAssertEqual(targets[2].runs, [r1, r2], "oldest first, so reverting newest first undoes them in order")
        XCTAssertEqual(targets[2].files, 3)
        XCTAssertEqual(targets[2].laterMessages, 2)
        XCTAssertEqual(targets.map(\.itemIndex), [8, 4, 0])
    }

    func testARevertedRunIsNotCountedAndAMessageWithoutAPositionIsSkipped() {
        let r1 = UUID(), r2 = UUID()
        let entries = [user("old", at: nil), changes(run: r1, files: 1, reverted: true), user("kept", at: 5), changes(run: r2, files: 2)]
        let targets = IDEAgentRewind.targets(in: entries)
        XCTAssertEqual(targets.map(\.text), ["kept"])
        XCTAssertEqual(targets[0].runs, [r2])
        XCTAssertTrue(IDEAgentRewind.targets(in: [user("x", at: nil)]).isEmpty)
        XCTAssertTrue(IDEAgentRewind.targets(in: []).isEmpty)
    }
}

@MainActor
final class IDEAgentRewindTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var storeDirectory: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-rewind-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project")
        storeDirectory = base.appendingPathComponent("store")
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

    private var store: SessionStore { SessionStore(directory: storeDirectory) }

    private func makeController(_ turns: [MockTurn]) -> (IDEAgentController, MockLLMClient) {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let client = MockLLMClient(turns: turns)
        let controller = IDEAgentController(settings: settings, store: store, clientFactory: { _ in client })
        controller.attach(host: workspace)
        controller.newConversation()
        return (controller, client)
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<800 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func say(_ controller: IDEAgentController, _ text: String) async {
        controller.draft = text
        controller.submit()
        await waitFor("the run ends") { !controller.isRunning }
    }

    private func disk(_ path: String) -> String? { try? String(contentsOf: project.appendingPathComponent(path), encoding: .utf8) }

    private let editTwo = MockTurn.toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#))
    private let readA = MockTurn.toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#))

    /// Three messages; the second one edits A.txt.
    private func threeMessages() async throws -> (IDEAgentController, MockLLMClient) {
        let (controller, client) = makeController([
            .text("answer one"),
            readA, editTwo, .text("answer two"),
            .text("answer three"),
            .text("after the rewind"),
        ])
        await say(controller, "first question")
        await say(controller, "second: change two")
        await say(controller, "third question")
        XCTAssertEqual(disk("A.txt"), "one\n2\nthree\n")
        return (controller, client)
    }

    // MARK: - Positions

    func testEachMessageKnowsItsPlaceInTheHistory() async throws {
        let (controller, _) = try await threeMessages()
        let session = try XCTUnwrap(controller.selected.currentSessionForTesting)
        let items = await session.items
        for entry in controller.entries where entry.kind == .user {
            let index = try XCTUnwrap(entry.itemIndex, entry.text)
            guard case .user(let sent) = items[index] else { return XCTFail("item \(index) is not a user message") }
            XCTAssertTrue(sent.hasSuffix(entry.text), "\(sent) / \(entry.text)")
        }
    }

    func testPositionsSurviveARelaunchEvenWithProviderItemsInTheHistory() async throws {
        let (controller, _) = makeController([.text("one"), .text("two")])
        await say(controller, "first")
        await say(controller, "second")
        // Insert provider-specific items before each message, as a Responses reasoning item would be.
        var snapshot = try XCTUnwrap(store.load(controller.conversationID, projectRoot: project.path))
        var items: [ConversationItem] = []
        var entryPositions: [Int] = []
        for item in snapshot.items {
            if case .user = item { items.append(.opaque(OpaqueItem(provider: "openai-responses", payload: .null))) }
            items.append(item)
            if case .user = item { entryPositions.append(items.count - 1) }
        }
        var saved = IDEAgentSavedTranscript.decode(snapshot.host)
        var rows = saved.entries
        var next = 0
        for index in rows.indices where rows[index].kind == .user {
            rows[index].itemIndex = entryPositions[next]
            next += 1
        }
        snapshot.items = items
        snapshot.host = try JSONEncoder().encode(IDEAgentSavedTranscript(entries: rows, cost: 0, todos: nil))
        saved.entries = rows
        try store.save(snapshot)

        let (reopened, _) = makeController([])
        reopened.resume(snapshot.id)
        let kept = reopened.entries.filter { $0.kind == .user }.compactMap(\.itemIndex)
        XCTAssertEqual(kept, [0, 2], "the opaque items were dropped, and the positions moved with the history")
        reopened.draft = ""
    }

    func testAShorteningOfTheHistoryTakesAwayEveryPosition() async throws {
        let (controller, _) = try await threeMessages()
        XCTAssertEqual(controller.selected.rewindTargets.count, 3)
        var report = CompactionReport()
        report.stubbedOutputs = 4
        controller.handle(.compacted(report))
        XCTAssertEqual(controller.selected.rewindTargets.count, 3, "clearing old tool outputs moves nothing")

        report.summarizedItems = 6
        controller.handle(.compacted(report))
        XCTAssertTrue(controller.selected.rewindTargets.isEmpty, "a summary replaces the start of the history")
        controller.draft = "next"
    }

    // MARK: - Rewinding

    func testRewindingBothPutsTheFilesBackForgetsTheLaterConversationAndReturnsTheMessage() async throws {
        let (controller, client) = try await threeMessages()
        let second = try XCTUnwrap(controller.entries.first { $0.text == "second: change two" })

        let done = await controller.selected.rewind(to: second.id, scope: .both)
        XCTAssertTrue(done)
        XCTAssertEqual(disk("A.txt"), "one\ntwo\nthree\n", "the file is back")
        XCTAssertEqual(controller.entries.compactMap { $0.kind == .user ? $0.text : nil }, ["first question"])
        XCTAssertFalse(controller.entries.contains { $0.kind == .changes }, "the card went with the messages")
        XCTAssertEqual(controller.draft, "second: change two", "the message is back in the field")
        XCTAssertTrue(controller.entries.last?.text.contains("Reverted 1 file") == true, controller.entries.last?.text ?? "")

        // The conversation goes on from what is left.
        await say(controller, "second, differently")
        let request = try XCTUnwrap(client.requests.last)
        XCTAssertEqual(request.items.count, 3, "first question, its answer, and the new message")
        guard case .user(let first) = request.items[0], case .user(let latest) = request.items[2] else { return XCTFail("unexpected items") }
        XCTAssertTrue(first.hasSuffix("first question") && latest.hasSuffix("second, differently"))
        XCTAssertFalse(request.items.contains { if case .toolCall = $0 { true } else { false } })
    }

    func testRewindingTheConversationOnlyLeavesTheFilesAlone() async throws {
        let (controller, _) = try await threeMessages()
        let second = try XCTUnwrap(controller.entries.first { $0.text == "second: change two" })
        await controller.selected.rewind(to: second.id, scope: .conversation)
        XCTAssertEqual(disk("A.txt"), "one\n2\nthree\n")
        XCTAssertEqual(controller.draft, "second: change two")
        XCTAssertEqual(controller.entries.compactMap { $0.kind == .user ? $0.text : nil }, ["first question"])
    }

    func testRewindingTheCodeOnlyKeepsTheConversationAndMarksTheCardReverted() async throws {
        let (controller, _) = try await threeMessages()
        let second = try XCTUnwrap(controller.entries.first { $0.text == "second: change two" })
        await controller.selected.rewind(to: second.id, scope: .code)
        XCTAssertEqual(disk("A.txt"), "one\ntwo\nthree\n")
        XCTAssertEqual(controller.entries.compactMap { $0.kind == .user ? $0.text : nil }.count, 3, "nothing forgotten")
        XCTAssertEqual(controller.entries.first { $0.kind == .changes }?.isReverted, true)
        XCTAssertEqual(controller.draft, "")
    }

    func testAFileTheUserEditedSinceIsLeftAloneAndSaidSo() async throws {
        let (controller, _) = try await threeMessages()
        try "the user typed this\n".write(to: project.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        let second = try XCTUnwrap(controller.entries.first { $0.text == "second: change two" })
        await controller.selected.rewind(to: second.id, scope: .both)
        XCTAssertEqual(disk("A.txt"), "the user typed this\n")
        XCTAssertTrue(controller.entries.contains { $0.kind == .notice && $0.text.contains("left as is") })
    }

    func testRewindingNeverHappensWhileARunIsGoing() async throws {
        let (controller, _) = makeController([MockTurn([.textDelta("slow"), .finished(.completed)], delayPerEvent: .milliseconds(400))])
        controller.draft = "go"
        controller.submit()
        await waitFor("running") { controller.isRunning }
        let entry = try XCTUnwrap(controller.entries.first { $0.kind == .user })
        let done = await controller.selected.rewind(to: entry.id, scope: .both)
        XCTAssertFalse(done)
        await waitFor("done") { !controller.isRunning }
    }

    func testAnAssistantRowOrAnUnknownIdCannotBeRewoundTo() async throws {
        let (controller, _) = try await threeMessages()
        let answer = try XCTUnwrap(controller.entries.first { $0.kind == .assistant })
        let first = await controller.selected.rewind(to: answer.id, scope: .both)
        let second = await controller.selected.rewind(to: UUID(), scope: .both)
        XCTAssertFalse(first)
        XCTAssertFalse(second)
    }

    func testTheChecklistGoesBackToWhatItWasThen() async throws {
        let (controller, _) = makeController([
            .toolCalls((id: "t1", name: "todo", arguments: #"{"items":["[ ] one"]}"#)), .text("a"),
            .toolCalls((id: "t2", name: "todo", arguments: #"{"items":["[x] one","[ ] two"]}"#)), .text("b"),
        ])
        await say(controller, "first")
        await say(controller, "second")
        XCTAssertEqual(controller.todos.count, 2)
        let second = try XCTUnwrap(controller.entries.first { $0.text == "second" })
        await controller.selected.rewind(to: second.id, scope: .conversation)
        XCTAssertEqual(controller.todos.map(\.content), ["one"])
    }

    func testRewindingAfterARelaunchNeedsNoSession() async throws {
        let (first, _) = try await threeMessages()
        let (reopened, client) = makeController([.text("continued")])
        reopened.resume(first.conversationID)
        XCTAssertNil(reopened.selected.currentSessionForTesting)
        let second = try XCTUnwrap(reopened.entries.first { $0.text == "second: change two" })

        let done = await reopened.selected.rewind(to: second.id, scope: .both)
        XCTAssertTrue(done)
        XCTAssertEqual(disk("A.txt"), "one\ntwo\nthree\n")
        XCTAssertNil(reopened.selected.currentSessionForTesting, "still no session")
        XCTAssertEqual(reopened.draft, "second: change two")

        await say(reopened, "second, differently")
        XCTAssertEqual(try XCTUnwrap(client.requests.last).items.count, 3, "the history was cut before the session was made")
        // And it was saved: a third window sees the rewound conversation.
        let (third, _) = makeController([])
        third.resume(first.conversationID)
        XCTAssertFalse(third.entries.contains { $0.text == "third question" })
        XCTAssertTrue(third.entries.contains { $0.text == "second, differently" })
    }

    // MARK: - Fork

    func testAForkContinuesFromBeforeAMessageInANewTabAndLeavesTheOriginalAlone() async throws {
        let (controller, client) = try await threeMessages()
        let original = controller.selected
        let second = try XCTUnwrap(controller.entries.first { $0.text == "second: change two" })
        let before = original.entries.count

        let forked = await controller.fork(original.id, before: second.id)
        let fork = try XCTUnwrap(forked)
        XCTAssertEqual(controller.conversations.count, 2)
        XCTAssertEqual(controller.selected.id, fork.id)
        XCTAssertEqual(original.entries.count, before, "the original is untouched")
        XCTAssertEqual(disk("A.txt"), "one\n2\nthree\n", "files are not touched by a fork")
        XCTAssertEqual(fork.entries.compactMap { $0.kind == .user ? $0.text : nil }, ["first question"])
        XCTAssertTrue(fork.title.hasSuffix("(fork)"), fork.title)
        XCTAssertNotEqual(fork.conversationID, original.conversationID)

        fork.draft = "a different second question"
        fork.send()
        await waitFor("the fork's run ends") { !fork.isRunning }
        XCTAssertEqual(try XCTUnwrap(client.requests.last).items.count, 3, "the fork carries the first exchange only")
        XCTAssertEqual(original.entries.count, before, "and the original did not hear about it")
    }

    func testForkingTheWholeChatCopiesTheTranscriptWithoutTheFileCards() async throws {
        let (controller, _) = try await threeMessages()
        let original = controller.selected
        XCTAssertTrue(original.entries.contains { $0.kind == .changes })
        let forked = await controller.fork(original.id)
        let fork = try XCTUnwrap(forked)
        XCTAssertEqual(fork.entries.compactMap { $0.kind == .user ? $0.text : nil }.count, 3)
        XCTAssertFalse(fork.entries.contains { $0.kind == .changes }, "the originals belong to the first chat")
    }

    func testAForkIsSavedSoItComesBackWithTheWindow() async throws {
        let (controller, _) = try await threeMessages()
        let forked = await controller.fork(controller.selected.id)
        let fork = try XCTUnwrap(forked)
        await waitFor("saved") { controller.history.contains { $0.id == fork.conversationID } }
        XCTAssertTrue(controller.restorableTabs.ids.contains(fork.conversationID))
    }

    func testAChatThatIsRunningCannotBeForked() async throws {
        let (controller, _) = makeController([MockTurn([.textDelta("slow"), .finished(.completed)], delayPerEvent: .milliseconds(400))])
        controller.draft = "go"
        controller.submit()
        await waitFor("running") { controller.isRunning }
        let fork = await controller.fork(controller.selected.id)
        XCTAssertNil(fork)
        XCTAssertEqual(controller.conversations.count, 1)
        await waitFor("done") { !controller.isRunning }
    }

    // MARK: - Commands

    func testTheRewindCommandOpensTheSheetOnlyWhenThereIsSomewhereToGo() async throws {
        let (controller, _) = makeController([.text("one")])
        controller.draft = "/rewind"
        controller.submit()
        XCTAssertNil(controller.rewindRequest)
        XCTAssertEqual(controller.entries.last?.text, "There is no earlier message to go back to.")

        await say(controller, "hello")
        controller.draft = "/rewind"
        controller.submit()
        XCTAssertNotNil(controller.rewindRequest)
        XCTAssertNil(controller.rewindRequest?.entryID)
    }

    func testTheForkCommandOpensANewTab() async throws {
        let (controller, _) = makeController([.text("one")])
        await say(controller, "hello")
        controller.draft = "/fork"
        controller.submit()
        await waitFor("a second tab") { controller.conversations.count == 2 }
        XCTAssertEqual(controller.selected.entries.first?.text, "hello")
    }
}
