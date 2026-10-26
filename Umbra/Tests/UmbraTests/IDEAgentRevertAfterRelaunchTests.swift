import AgentKit
import Foundation
import XCTest

@testable import Umbra

/// Revert Run after the window was closed and the project reopened.
@MainActor
final class IDEAgentRevertAfterRelaunchTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var storeDirectory: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-relaunch-\(UUID().uuidString)", isDirectory: true)
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
    private var blobs: IDEAgentCheckpointBlobs { IDEAgentCheckpointBlobs(store: store, projectRoot: project.path) }

    private func makeController(_ turns: [MockTurn], failingClient: Bool = false, settings: IDEAgentSettings? = nil) -> IDEAgentController {
        let settings = settings ?? {
            let made = IDEAgentSettings(
                defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
            made.saveAPIKey("sk-test")
            made.acceptDisclosure()
            return made
        }()
        let client = MockLLMClient(turns: turns)
        let controller = IDEAgentController(
            settings: settings, store: store,
            clientFactory: { _ in
                if failingClient { throw CocoaError(.fileNoSuchFile) }
                return client
            })
        controller.attach(host: workspace)
        controller.newConversation()
        return controller
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<800 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func disk(_ path: String) -> String? { try? String(contentsOf: project.appendingPathComponent(path), encoding: .utf8) }

    private func editAndSave() async throws -> IDEAgentController {
        let controller = makeController([
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            .toolCalls((id: "w", name: "write_file", arguments: #"{"path":"New.txt","content":"created\n"}"#)),
            .text("done"),
            // The run changed files and ran no check, so the loop asks once more before it ends.
            .text("checked"),
        ])
        controller.draft = "edit it"
        controller.submit()
        await waitFor("saved") { !controller.isRunning && !controller.history.isEmpty }
        XCTAssertEqual(disk("A.txt"), "one\n2\nthree\n")
        XCTAssertEqual(disk("New.txt"), "created\n")
        return controller
    }

    func testTheOriginalsAreOnDiskAfterARun() async throws {
        let controller = try await editAndSave()
        let card = try XCTUnwrap(controller.entries.first { $0.kind == .changes })
        let run = try XCTUnwrap(card.run)
        XCTAssertEqual(blobs.get(run: run, path: "A.txt"), "one\ntwo\nthree\n")
        XCTAssertNil(blobs.get(run: run, path: "New.txt"), "a created file has no original")
    }

    func testTheFilesChangedCardComesBackAndRevertsWithNoSessionAtAll() async throws {
        let first = try await editAndSave()
        let runCard = try XCTUnwrap(first.entries.first { $0.kind == .changes })

        // A new window for the same project: nothing in memory but what is on disk.
        let reopened = makeController([])
        reopened.resume(first.conversationID)
        let card = try XCTUnwrap(reopened.entries.first { $0.kind == .changes }, "the card was saved")
        XCTAssertEqual(card.run, runCard.run)
        XCTAssertEqual(card.fileChanges.map(\.path), ["A.txt", "New.txt"])
        XCTAssertEqual(card.fileChanges.first?.original, "one\ntwo\nthree\n", "Show Diff has its original")
        XCTAssertTrue(card.fileChanges.last?.isCreation == true)
        XCTAssertNil(reopened.selected.currentSessionForTesting, "no session exists yet")

        reopened.revert(entryID: card.id)
        await waitFor("reverted") { reopened.entries.first { $0.kind == .changes }?.isReverted == true }
        XCTAssertEqual(disk("A.txt"), "one\ntwo\nthree\n")
        XCTAssertNil(disk("New.txt"))
        XCTAssertNil(reopened.selected.currentSessionForTesting, "reverting did not need a provider")
    }

    func testRevertWorksEvenWhenTheProviderIsNotSetUp() async throws {
        let first = try await editAndSave()
        let reopened = makeController([], failingClient: true)
        reopened.resume(first.conversationID)
        let card = try XCTUnwrap(reopened.entries.first { $0.kind == .changes })
        reopened.revert(entryID: card.id)
        await waitFor("reverted") { reopened.entries.first { $0.kind == .changes }?.isReverted == true }
        XCTAssertEqual(disk("A.txt"), "one\ntwo\nthree\n")
        XCTAssertFalse(reopened.entries.contains { $0.kind == .error })
    }

    func testARevertedRunStaysRevertedAfterAnotherRelaunch() async throws {
        let first = try await editAndSave()
        let reopened = makeController([.text("hi")])
        reopened.resume(first.conversationID)
        reopened.revert(entryID: try XCTUnwrap(reopened.entries.first { $0.kind == .changes }).id)
        await waitFor("reverted") { reopened.entries.first { $0.kind == .changes }?.isReverted == true }
        // Sending persists the conversation again, with the card's new state.
        reopened.draft = "thanks"
        reopened.submit()
        await waitFor("saved again") { !reopened.isRunning }

        let third = makeController([])
        third.resume(first.conversationID)
        XCTAssertEqual(third.entries.first { $0.kind == .changes }?.isReverted, true)
    }

    func testAFileTheUserEditedAfterwardsIsLeftAloneAfterARelaunch() async throws {
        let first = try await editAndSave()
        try "the user typed this\n".write(to: project.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        let reopened = makeController([])
        reopened.resume(first.conversationID)
        reopened.revert(entryID: try XCTUnwrap(reopened.entries.first { $0.kind == .changes }).id)
        await waitFor("done") { reopened.entries.contains { $0.kind == .notice && $0.text.contains("changed since") } }
        XCTAssertEqual(disk("A.txt"), "the user typed this\n")
        XCTAssertNil(disk("New.txt"), "the file the agent created, and the user left alone, still goes")
        XCTAssertEqual(reopened.entries.first { $0.kind == .changes }?.conflicts.map(\.path), ["A.txt"])
    }

    func testACardWhoseOriginalsAreGoneIsNotShownBecauseItCouldNotWork() async throws {
        let first = try await editAndSave()
        let run = try XCTUnwrap(first.entries.first { $0.kind == .changes }?.run)
        blobs.removeRun(run)

        let reopened = makeController([])
        reopened.resume(first.conversationID)
        XCTAssertNil(reopened.entries.first { $0.kind == .changes })
        XCTAssertFalse(reopened.entries.isEmpty, "the rest of the conversation is there")
    }

    func testRevertSurvivesASettingsChangeThatStartsANewSession() async throws {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let controller = makeController([
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            .text("done"), .text("next"),
        ], settings: settings)
        controller.draft = "edit it"
        controller.submit()
        await waitFor("done") { !controller.isRunning }
        let card = try XCTUnwrap(controller.entries.first { $0.kind == .changes })

        settings.iterationCap = settings.iterationCap + 1  // part of the session fingerprint
        controller.draft = "something else"
        controller.submit()
        await waitFor("second run done") { !controller.isRunning }

        controller.revert(entryID: card.id)
        await waitFor("reverted") { controller.entries.first { $0.id == card.id }?.isReverted == true }
        XCTAssertEqual(disk("A.txt"), "one\ntwo\nthree\n", "the first run is still revertable after the new session")
    }

    func testDeletingAConversationRemovesItsOriginalsAndClearingHistoryRemovesAll() async throws {
        let first = try await editAndSave()
        let run = try XCTUnwrap(first.entries.first { $0.kind == .changes }?.run)
        XCTAssertTrue(blobs.hasRun(run))
        first.deleteConversation(first.conversationID)
        XCTAssertFalse(blobs.hasRun(run))

        // The first run's edits are still in the project; start from the original files again.
        try "one\ntwo\nthree\n".write(to: project.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: project.appendingPathComponent("New.txt"))
        let second = try await editAndSave()
        let secondRun = try XCTUnwrap(second.entries.first { $0.kind == .changes }?.run)
        XCTAssertTrue(blobs.hasRun(secondRun))
        second.clearHistory()
        XCTAssertFalse(blobs.hasRun(secondRun))
    }
}
