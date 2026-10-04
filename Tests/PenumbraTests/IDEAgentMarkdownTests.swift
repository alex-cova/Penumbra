import AgentKit
import Foundation
import XCTest

@testable import Umbra

final class IDEAgentMarkdownTests: XCTestCase {
    private func parse(_ text: String) -> [IDEAgentMarkdownBlock] { IDEAgentMarkdown.parse(text) }

    func testHeadingsParagraphsAndLineBreaks() {
        XCTAssertEqual(parse("# Title\n\nFirst line\nsecond line\n\nNext"), [
            .heading(level: 1, text: "Title"), .paragraph("First line\nsecond line"), .paragraph("Next"),
        ])
        XCTAssertEqual(parse("###### Six"), [.heading(level: 6, text: "Six")])
        XCTAssertEqual(parse("####### seven"), [.paragraph("####### seven")], "past six hashes it is text")
        XCTAssertEqual(parse("#nospace"), [.paragraph("#nospace")])
    }

    func testBulletedAndNumberedListsKeepTheirNestingAndNumbers() {
        XCTAssertEqual(parse("- one\n  - nested\n* star\n+ plus\n1. first\n2) second\n10. tenth"), [
            .listItem(marker: "•", indent: 0, text: "one"), .listItem(marker: "•", indent: 1, text: "nested"),
            .listItem(marker: "•", indent: 0, text: "star"), .listItem(marker: "•", indent: 0, text: "plus"),
            .listItem(marker: "1.", indent: 0, text: "first"), .listItem(marker: "2.", indent: 0, text: "second"),
            .listItem(marker: "10.", indent: 0, text: "tenth"),
        ])
        XCTAssertEqual(parse("-not a list"), [.paragraph("-not a list")])
        XCTAssertEqual(parse("999. still a list"), [.listItem(marker: "999.", indent: 0, text: "still a list")])
        XCTAssertEqual(parse("2024. was a year"), [.paragraph("2024. was a year")], "a year at the start of a sentence is not a list")
    }

    func testFencedCodeKeepsItsTextAndLanguageAndSurvivesMarkdownInside() {
        let blocks = parse("Before\n```swift\nlet x = 1\n# not a heading\n- not a list\n```\nAfter")
        XCTAssertEqual(blocks, [
            .paragraph("Before"), .code(language: "swift", text: "let x = 1\n# not a heading\n- not a list"), .paragraph("After"),
        ])
        XCTAssertEqual(parse("~~~\nplain\n~~~"), [.code(language: nil, text: "plain")])
    }

    func testAnUnclosedFenceRunsToTheEndSoStreamingTextLooksRight() {
        XCTAssertEqual(parse("```sh\nmake\nmake test"), [.code(language: "sh", text: "make\nmake test")])
        XCTAssertEqual(parse("```"), [.code(language: nil, text: "")])
    }

    func testQuotesJoinConsecutiveLines() {
        XCTAssertEqual(parse("> one\n> two\n\nafter"), [.quote("one\ntwo"), .paragraph("after")])
        XCTAssertEqual(parse(">tight"), [.quote("tight")])
    }

    func testRulesAndTables() {
        XCTAssertEqual(parse("a\n\n---\n\nb"), [.paragraph("a"), .rule, .paragraph("b")])
        XCTAssertEqual(parse("***"), [.rule])
        XCTAssertEqual(parse("--"), [.paragraph("--")])
        let table = parse("| Name | Size |\n|------|-----:|\n| A.java | 12 |\n| B | 7 |")
        XCTAssertEqual(table, [.table(rows: [["Name", "Size"], ["A.java", "12"], ["B", "7"]])])
        XCTAssertEqual(IDEAgentMarkdown.alignedTable([["Name", "Size"], ["A.java", "12"], ["B", "7"]]), "Name    Size\nA.java  12\nB       7")
    }

    func testPlainTextAndEmptyInput() {
        XCTAssertEqual(parse(""), [])
        XCTAssertEqual(parse("\n\n"), [])
        XCTAssertEqual(parse("just words"), [.paragraph("just words")])
        XCTAssertEqual(parse("a\r\nb"), [.paragraph("a\nb")], "Windows line endings are read as newlines")
    }

    func testARealisticPlanParsesIntoItsParts() {
        let plan = """
        ## Plan

        1. Add `PermissionMode.next`.
        2. Update the chip:
           - show the title
           - tint by mode

        **Verify:** run the tests.

        ```
        swift test
        ```
        """
        let blocks = parse(plan)
        XCTAssertEqual(blocks.first, .heading(level: 2, text: "Plan"))
        XCTAssertEqual(blocks.filter { if case .listItem = $0 { true } else { false } }.count, 4)
        XCTAssertTrue(blocks.contains(.paragraph("**Verify:** run the tests.")))
        XCTAssertEqual(blocks.last, .code(language: nil, text: "swift test"))
    }
}

@MainActor
final class IDEAgentPlanFlowTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-plan-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "one\ntwo\n".write(to: project.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    private func makeController(_ turns: [MockTurn], store: SessionStore? = nil) -> (IDEAgentController, MockLLMClient) {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        settings.mode = .plan
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

    private let planCall = MockTurn.toolCalls((id: "p", name: "exit_plan_mode", arguments: ###"{"plan":"## Plan\n1. Change two to 2"}"###))

    func testAPlanWaitsForTheUserAndApprovingLetsTheAgentEdit() async throws {
        let (controller, client) = makeController([
            planCall,
            .toolCalls((id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#)),
            .toolCalls((id: "e", name: "edit_file", arguments: #"{"path":"A.txt","old_string":"two","new_string":"2"}"#)),
            .text("done"),
        ])
        controller.draft = "change two to 2"
        controller.submit()
        await waitFor("the plan is waiting") { controller.entries.contains { $0.plan != nil } }

        let entry = try XCTUnwrap(controller.entries.first { $0.plan != nil })
        XCTAssertEqual(entry.planText, "## Plan\n1. Change two to 2")
        XCTAssertTrue(controller.selected.isAwaitingUser)
        XCTAssertEqual(controller.mode, .plan)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("A.txt"), encoding: .utf8), "one\ntwo\n")

        controller.selected.approvePlan(callID: "p", mode: .acceptEdits)
        XCTAssertEqual(controller.mode, .acceptEdits, "the chat's mode follows the approval")
        await waitFor("the run ends") { !controller.isRunning }
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("A.txt"), encoding: .utf8), "one\n2\n")
        let card = try XCTUnwrap(controller.entries.first { $0.callID == "p" })
        XCTAssertEqual(card.planOutcome, "Approved · Accept Edits")
        XCTAssertNil(card.plan, "no longer waiting")
        XCTAssertFalse(controller.selected.isAwaitingUser)
        XCTAssertTrue(card.planText?.contains("Change two to 2") == true, "the plan stays readable from the call's arguments")
        let tools = try XCTUnwrap(client.requests.last).tools.map(\.name)
        XCTAssertTrue(tools.contains("edit_file") && !tools.contains("exit_plan_mode"))
    }

    func testKeepPlanningSendsTheFeedbackAndStaysInPlanMode() async throws {
        let (controller, client) = makeController([planCall, .text("What should I change?")])
        controller.draft = "plan it"
        controller.submit()
        await waitFor("the plan is waiting") { controller.entries.contains { $0.plan != nil } }

        controller.selected.revisePlan(callID: "p", feedback: "split step one")
        await waitFor("the run ends") { !controller.isRunning }
        XCTAssertEqual(controller.mode, .plan)
        XCTAssertEqual(controller.entries.first { $0.callID == "p" }?.planOutcome, "Changes requested")
        let output = try XCTUnwrap(controller.entries.first { $0.callID == "p" }?.output?.text)
        XCTAssertTrue(output.contains("The user wants changes to the plan: split step one"))
        XCTAssertTrue(try XCTUnwrap(client.requests.last).tools.map(\.name).contains("exit_plan_mode"))
    }

    func testStoppingWhileAPlanWaitsLeavesNoDanglingCard() async throws {
        let (controller, _) = makeController([planCall, .text("never")])
        controller.draft = "plan it"
        controller.submit()
        await waitFor("the plan is waiting") { controller.entries.contains { $0.plan != nil } }
        controller.stop()
        await waitFor("the run ends") { !controller.isRunning }
        XCTAssertNil(controller.entries.first { $0.callID == "p" }?.plan)
        XCTAssertFalse(controller.selected.isAwaitingUser)
    }

    func testTheDecisionSurvivesARelaunch() async throws {
        let storeDirectory = base.appendingPathComponent("store")
        let store = SessionStore(directory: storeDirectory)
        let (controller, _) = makeController([planCall, .text("What next?")], store: store)
        controller.draft = "plan it"
        controller.submit()
        await waitFor("the plan is waiting") { controller.entries.contains { $0.plan != nil } }
        controller.selected.revisePlan(callID: "p", feedback: "")
        await waitFor("saved") { !controller.isRunning && !controller.history.isEmpty }

        let (reopened, _) = makeController([], store: store)
        reopened.resume(try XCTUnwrap(controller.history.first).id)
        let card = try XCTUnwrap(reopened.entries.first { $0.callID == "p" })
        XCTAssertEqual(card.planOutcome, "Changes requested")
        XCTAssertEqual(card.planText, "## Plan\n1. Change two to 2")
    }
}
