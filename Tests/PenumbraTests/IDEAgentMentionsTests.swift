import AgentKit
import Foundation
import XCTest

@testable import Umbra

/// `@` mentions in a real chat: what reaches the model, what the transcript shows, and the list.
@MainActor
final class IDEAgentMentionsTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var storeDirectory: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-mentions-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project")
        storeDirectory = base.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src/util"), withIntermediateDirectories: true)
        try "class A {}\n".write(to: project.appendingPathComponent("src/A.java"), atomically: true, encoding: .utf8)
        try "one\ntwo\nthree\n".write(to: project.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        try "helper".write(to: project.appendingPathComponent("src/util/Helper.java"), atomically: true, encoding: .utf8)
        try "TOKEN=abc\n".write(to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    private func makeController(_ turns: [MockTurn]) -> (IDEAgentController, MockLLMClient) {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let client = MockLLMClient(turns: turns)
        let controller = IDEAgentController(settings: settings, store: SessionStore(directory: storeDirectory), clientFactory: { _ in client })
        controller.attach(host: workspace)
        controller.newConversation()
        return (controller, client)
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<800 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func send(_ controller: IDEAgentController, _ text: String) async {
        controller.draft = text
        controller.submit()
        await waitFor("the run ends") { !controller.isRunning }
    }

    private func firstUserItem(_ client: MockLLMClient) throws -> String {
        guard case .user(let text) = try XCTUnwrap(client.requests.first?.items.first) else { throw XCTSkip("no user item") }
        return text
    }

    func testAMentionedFileReachesTheModelAndTheRowShowsWhatWasAttached() async throws {
        let (controller, client) = makeController([.text("seen")])
        await send(controller, "What does @src/A.java declare?")

        let sent = try firstUserItem(client)
        XCTAssertTrue(sent.contains("What does @src/A.java declare?"))
        XCTAssertTrue(sent.contains("<untrusted source=\"attachment:src/A.java\">\nclass A {}\n\n</untrusted>"))
        let user = try XCTUnwrap(controller.entries.first { $0.kind == .user })
        XCTAssertEqual(user.text, "What does @src/A.java declare?", "the transcript shows what was typed")
        XCTAssertEqual(user.attachments, ["src/A.java · 11 B"])
    }

    func testAnAttachedFileCanBeEditedWithoutReadingItFirst() async throws {
        let (controller, _) = makeController([
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            .text("done"),
        ])
        await send(controller, "change two to 2 in @A.txt")
        let output = try XCTUnwrap(controller.entries.first { $0.callID == "e" }?.output)
        XCTAssertFalse(output.isError, output.text)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("A.txt"), encoding: .utf8), "one\n2\nthree\n")
    }

    func testAFileThatWasOnlyPartlyAttachedStillNeedsAReadBeforeAnEdit() async throws {
        let (controller, _) = makeController([
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            .text("done"),
        ])
        await send(controller, "change two to 2 in @A.txt:1-2")
        let output = try XCTUnwrap(controller.entries.first { $0.callID == "e" }?.output)
        XCTAssertTrue(output.isError, "a slice is not a read of the file")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("A.txt"), encoding: .utf8), "one\ntwo\nthree\n")
    }

    func testACredentialsFileAndAMissingPathAreReportedNotAttached() async throws {
        let (controller, client) = makeController([.text("ok")])
        await send(controller, "use @.env and @src/Missing.java and @alex too")

        let sent = try firstUserItem(client)
        XCTAssertFalse(sent.contains("TOKEN=abc"), "the credential never reaches the provider")
        XCTAssertFalse(sent.contains("<attachment"))
        let notices = controller.entries.filter { $0.kind == .notice }.map(\.text)
        XCTAssertTrue(notices.contains { $0.hasPrefix("Could not attach @.env: it looks like a credentials file") })
        XCTAssertTrue(notices.contains("Could not attach @src/Missing.java: no such file."))
        XCTAssertFalse(notices.contains { $0.contains("@alex") }, "a bare name is probably not a path")
        XCTAssertTrue(controller.entries.first { $0.kind == .user }?.attachments.isEmpty == true)
    }

    func testAFolderMentionListsItsEntries() async throws {
        let (controller, client) = makeController([.text("ok")])
        await send(controller, "what is in @src/")
        let sent = try firstUserItem(client)
        XCTAssertTrue(sent.contains("<untrusted source=\"attachment:src/\">\nutil/\nA.java\n</untrusted>"), sent)
    }

    func testMentionsInACommandExpansionAreAttachedToo() async throws {
        let commands = project.appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try "Review @src/A.java for $ARGUMENTS".write(to: commands.appendingPathComponent("rev.md"), atomically: true, encoding: .utf8)
        let (controller, client) = makeController([.text("ok")])
        await send(controller, "/rev style")
        let sent = try firstUserItem(client)
        XCTAssertTrue(sent.contains("Review @src/A.java for style"))
        XCTAssertTrue(sent.contains("<untrusted source=\"attachment:src/A.java\">"))
    }

    func testTheSessionKeepsTheAttachmentsInItsHistoryForLaterTurns() async throws {
        let (controller, client) = makeController([.text("one"), .text("two")])
        await send(controller, "look at @A.txt")
        await send(controller, "and now?")
        let second = try XCTUnwrap(client.requests.last)
        guard case .user(let first) = second.items[0] else { return XCTFail("no first user item") }
        XCTAssertTrue(first.contains("<untrusted source=\"attachment:A.txt\">"), "the model still has what it was given")
    }

    // MARK: - The list

    func testTheListOffersFilesBestMatchFirstAndTheSpecials() async throws {
        let (controller, _) = makeController([.text("x")])
        controller.restoreLatestIfNeeded()
        let rows = controller.suggestions(for: .mention(query: "", range: NSRange(location: 0, length: 1)))
        XCTAssertTrue(rows.contains { $0.title == "@changes" } && rows.contains { $0.title == "@terminal" })
        XCTAssertFalse(rows.contains { $0.title == "@selection" }, "nothing is selected, so it is not offered")
        XCTAssertFalse(rows.contains { $0.title == "@problems" })
        XCTAssertTrue(rows.allSatisfy { $0.insertion.hasPrefix("@") && $0.insertion.hasSuffix(" ") })
    }

    func testTheSpecialsFilterByTheQuery() {
        let (controller, _) = makeController([.text("x")])
        let rows = controller.suggestions(for: .mention(query: "chan", range: NSRange(location: 0, length: 5)))
        XCTAssertEqual(rows.first?.title, "@changes")
        XCTAssertNil(rows.first { $0.title == "@terminal" })
    }

    func testSkillsAreOfferedAsMentions() throws {
        let skills = project.appendingPathComponent(".claude/skills/review")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try "---\ndescription: Review a diff\n---\nbody".write(to: skills.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let (controller, _) = makeController([.text("x")])
        let rows = controller.suggestions(for: .mention(query: "skill", range: NSRange(location: 0, length: 6)))
        let skill = try XCTUnwrap(rows.first { $0.title == "@skill:review" })
        XCTAssertEqual(skill.detail, "Review a diff")
    }

    func testAcceptingAFileInsertsItsMentionWithTheTrailingSpace() {
        let row = IDEAgentSuggestion(id: "f", icon: "doc", title: "A.java", detail: nil, insertion: IDEAgentMentionToken.format(path: "My Dir/A.java") + " ")
        XCTAssertEqual(row.insertion, "@\"My Dir/A.java\" ")
    }
}
