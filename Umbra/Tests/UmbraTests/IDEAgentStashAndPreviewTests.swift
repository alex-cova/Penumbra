import AgentKit
import Foundation
import XCTest

@testable import Umbra

@MainActor
final class IDEAgentStashAndPreviewTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("stash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func image(_ byte: UInt8) -> IDEAttachedImage {
        IDEAttachedImage(mediaType: "image/png", data: Data([byte, byte, byte]), pixelSize: CGSize(width: 4, height: 3))
    }

    // MARK: Stash

    func testADraftAndItsImagesSurviveOnDiskUntilTaken() throws {
        let file = folder.appendingPathComponent("stash.json")
        let stash = IDEAgentPromptStash(file: file)
        let entry = try XCTUnwrap(stash.add(text: "Refactor the menu\nthen the prices", images: [image(1), image(2)]))
        XCTAssertEqual(entry.title, "Refactor the menu")

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let imageFolder = folder.appendingPathComponent("stash-images/\(entry.id.uuidString)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageFolder.path))

        // Another window (or a relaunch) reads the same stash.
        let reopened = IDEAgentPromptStash(file: file)
        XCTAssertEqual(reopened.entries.map(\.id), [entry.id])
        let taken = try XCTUnwrap(reopened.take(entry.id))
        XCTAssertEqual(taken.text, "Refactor the menu\nthen the prices")
        XCTAssertEqual(taken.images.map(\.data), [Data([1, 1, 1]), Data([2, 2, 2])])
        XCTAssertEqual(taken.images.first?.pixelSize, CGSize(width: 4, height: 3))
        XCTAssertTrue(reopened.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageFolder.path), "taking a draft removes its images")
        XCTAssertTrue(IDEAgentPromptStash(file: file).entries.isEmpty)
    }

    func testBlankDraftsAreIgnoredAndTheOldestIsDroppedPastTheLimit() {
        let stash = IDEAgentPromptStash(file: folder.appendingPathComponent("stash.json"), limit: 2)
        XCTAssertNil(stash.add(text: "  \n", images: []))
        let first = stash.add(text: "one", images: [image(1)], now: Date(timeIntervalSince1970: 1))!
        stash.add(text: "two", images: [], now: Date(timeIntervalSince1970: 2))
        stash.add(text: "three", images: [], now: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(stash.entries.map(\.text), ["three", "two"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("stash-images/\(first.id.uuidString)").path))
        XCTAssertEqual(stash.add(text: "", images: [image(3)])?.title, "1 image")
    }

    func testStashingEmptiesTheFieldAndRestoringStashesWhatItHeld() {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.stash.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        IDEWorkspace.isSessionPersistenceEnabled = false
        defer { IDEWorkspace.isSessionPersistenceEnabled = true }
        let workspace = IDEWorkspace()
        workspace.project.setRoot(folder)
        defer { workspace.teardown() }
        let agent = IDEAgentController(settings: settings, clientFactory: { _ in MockLLMClient(turns: []) })
        agent.attach(host: workspace)

        agent.draft = "Write the migration"
        agent.selected.pendingImages = [image(7)]
        agent.stashDraft()
        XCTAssertEqual(agent.draft, "")
        XCTAssertTrue(agent.selected.pendingImages.isEmpty)
        let stash = try! XCTUnwrap(agent.promptStash())
        XCTAssertEqual(stash.entries.map(\.text), ["Write the migration"])

        agent.draft = "Something quick first"
        agent.restoreStashed(stash.entries[0].id)
        XCTAssertEqual(agent.draft, "Write the migration")
        XCTAssertEqual(agent.selected.pendingImages.map(\.data), [Data([7, 7, 7])])
        XCTAssertEqual(stash.entries.map(\.text), ["Something quick first"], "what the field held is not lost")

        agent.draft = ""
        agent.stashDraft()
        XCTAssertEqual(stash.entries.count, 2, "an image alone is a draft worth keeping")
        XCTAssertEqual(stash.entries.first?.title, "1 image")

        agent.stashDraft()
        XCTAssertEqual(stash.entries.count, 2, "an empty field stashes nothing")
    }

    // MARK: Tab tooltip

    func testTheTooltipSaysTitleStatusReplyChangesAndCost() {
        let text = IDEAgentTabPreview.make(
            title: "Fix the menu", status: "Working · Running read_file…",
            lastReply: "I changed the price column.\nThen I ran the tests.\nAll pass.\nExtra line",
            filesChanged: 2, cost: 0.1234)
        XCTAssertEqual(text.components(separatedBy: "\n"), [
            "Fix the menu",
            "Working · Running read_file…",
            "“I changed the price column. Then I ran the tests. All pass.”",
            "2 files changed · ~" + IDEAgentPrices.format(0.1234),
        ])
        XCTAssertEqual(IDEAgentTabPreview.make(title: "New chat", status: nil, lastReply: nil, filesChanged: 0, cost: 0), "New chat")
    }

    func testAChatWaitingForAnApprovalSaysWhatItWantsToRun() {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.preview.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        let chat = IDEAgentConversation(settings: settings, store: nil, clientFactory: { _ in MockLLMClient(turns: []) })
        XCTAssertEqual(IDEAgentTabPreview.status(of: chat, now: Date()), "New chat")
        chat.handle(.toolCallStarted(id: "a", name: "run_command"))
        chat.handle(.approvalRequested(ApprovalRequest(title: "Run", command: "rm -rf build", callID: "a", toolName: "run_command")))
        XCTAssertEqual(IDEAgentTabPreview.status(of: chat, now: Date()), "Waiting for your approval: rm -rf build")
    }

    func testATabNotOpenedYetIsDescribedFromItsSavedSummaryWithoutLoadingIt() {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.preview.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        let chat = IDEAgentConversation(settings: settings, store: nil, clientFactory: { _ in MockLLMClient(turns: []) })
        let id = UUID()
        chat.showPending(id: id, title: "Port the parser")
        let now = Date()
        let saved = SessionSummary(id: id, title: "Port the parser", updatedAt: now.addingTimeInterval(-7200), messageCount: 12, cost: 0.5)
        let text = IDEAgentTabPreview.text(for: chat, saved: saved, now: now)
        XCTAssertTrue(text.hasPrefix("Port the parser\n12 messages · updated "), text)
        XCTAssertTrue(text.contains("~" + IDEAgentPrices.format(0.5)), text)
        XCTAssertTrue(text.hasSuffix("Not opened since Umbra started"), text)
        XCTAssertNotNil(chat.pendingLoadID, "the preview does not load the chat")
    }
}
