import AgentKit
import Foundation
import XCTest

@testable import Umbra

@MainActor
final class IDEAgentQueueTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-queue-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "alpha\nbeta\n".write(to: project.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
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
        let controller = IDEAgentController(settings: settings, clientFactory: { _ in client })
        controller.attach(host: workspace)
        controller.newConversation()
        return (controller, client)
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<800 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    /// A tool call, slowly, so a message can be written while the model is still at it.
    private func slowRead(delay: Int = 200) -> MockTurn {
        MockTurn(
            [.toolCallStarted(id: "r", name: "read_file"), .toolCallFinished(id: "r", name: "read_file", arguments: #"{"path":"A.txt"}"#), .finished(.toolCalls)],
            delayPerEvent: .milliseconds(delay))
    }

    /// Sends a message and waits until the model is in the middle of its first step (its tool call has
    /// started), so what is written next is for the *next* step.
    private func start(_ controller: IDEAgentController, _ text: String) async {
        controller.draft = text
        controller.submit()
        await waitFor("running") { controller.isRunning }
        await waitFor("the first step is under way") {
            controller.entries.contains { if case .toolCall = $0.kind { true } else { false } }
        }
    }

    func testAMessageWrittenDuringARunIsQueuedAndTheFieldIsFree() async throws {
        let (controller, _) = makeController([slowRead(), .text("done")])
        await start(controller, "first")
        controller.draft = "also look at B"
        controller.submit()
        XCTAssertEqual(controller.selected.queue.map(\.text), ["also look at B"])
        XCTAssertEqual(controller.draft, "")
        XCTAssertFalse(controller.entries.contains { $0.text == "also look at B" }, "not in the transcript until the model takes it")
        await waitFor("finished") { !controller.isRunning && controller.selected.queue.isEmpty }
    }

    func testTheModelGetsItAtItsNextTurnAndTheTranscriptShowsItInPlace() async throws {
        let (controller, client) = makeController([slowRead(), .text("done")])
        await start(controller, "first")
        controller.draft = "also look at B"
        controller.submit()
        await waitFor("finished") { !controller.isRunning && controller.selected.queue.isEmpty }

        let second = try XCTUnwrap(client.requests.last)
        XCTAssertEqual(second.items.last, .user("also look at B"), "after the tool's output")
        let kinds = controller.entries.map(\.kind)
        XCTAssertEqual(kinds.first, .user)
        let queuedAt = try XCTUnwrap(controller.entries.firstIndex { $0.text == "also look at B" })
        let toolAt = try XCTUnwrap(controller.entries.firstIndex { if case .toolCall = $0.kind { true } else { false } })
        XCTAssertGreaterThan(queuedAt, toolAt, "it comes after the step it interrupted")
        XCTAssertEqual(controller.entries.last?.text, "done")
    }

    func testADeliveredMessageKnowsItsPlaceSoItCanBeRewoundTo() async throws {
        let (controller, _) = makeController([slowRead(), .text("done")])
        await start(controller, "first")
        controller.draft = "also look at B"
        controller.submit()
        await waitFor("finished") { !controller.isRunning && controller.selected.queue.isEmpty }
        let session = try XCTUnwrap(controller.selected.currentSessionForTesting)
        let items = await session.items
        let entry = try XCTUnwrap(controller.entries.first { $0.text == "also look at B" })
        let index = try XCTUnwrap(entry.itemIndex)
        XCTAssertEqual(items[index], .user("also look at B"))
    }

    func testATakenBackMessageIsNotDelivered() async throws {
        let (controller, client) = makeController([slowRead(), .text("done")])
        await start(controller, "first")
        controller.draft = "never mind this"
        controller.submit()
        let queued = try XCTUnwrap(controller.selected.queue.first)
        controller.selected.removeQueued(queued.id)
        XCTAssertTrue(controller.selected.queue.isEmpty)
        await waitFor("finished") { !controller.isRunning }
        XCTAssertFalse(try XCTUnwrap(client.requests.last).items.contains { if case .user(let text) = $0 { text.contains("never mind this") } else { false } })
        XCTAssertFalse(controller.entries.contains { $0.text == "never mind this" })
    }

    func testSeveralQueuedMessagesArriveInOrder() async throws {
        let (controller, client) = makeController([slowRead(), .text("done")])
        await start(controller, "first")
        controller.draft = "one"
        controller.submit()
        controller.draft = "two"
        controller.submit()
        XCTAssertEqual(controller.selected.queue.map(\.text), ["one", "two"])
        await waitFor("finished") { !controller.isRunning && controller.selected.queue.isEmpty }
        let items = try XCTUnwrap(client.requests.last).items
        XCTAssertEqual(Array(items.suffix(2)), [.user("one"), .user("two")])
        XCTAssertEqual(controller.entries.compactMap { $0.kind == .user ? $0.text : nil }, ["first", "one", "two"])
    }

    func testAMentionInAQueuedMessageIsAttachedWhenItIsDelivered() async throws {
        let (controller, client) = makeController([slowRead(), .text("done")])
        await start(controller, "first")
        controller.draft = "compare with @A.txt"
        controller.submit()
        await waitFor("finished") { !controller.isRunning && controller.selected.queue.isEmpty }
        guard case .user(let sent) = try XCTUnwrap(try XCTUnwrap(client.requests.last).items.last) else { return XCTFail("no message") }
        XCTAssertTrue(sent.contains("<attachment name=\"A.txt\">\nalpha\nbeta\n\n</attachment>"), sent)
        XCTAssertEqual(controller.entries.first { $0.text == "compare with @A.txt" }?.attachments.count, 1)
    }

    func testStoppingPutsTheQueuedMessagesBackInTheFieldInsteadOfSendingThem() async throws {
        let (controller, client) = makeController([slowRead(delay: 400), .text("never")])
        await start(controller, "first")
        controller.draft = "write this later"
        controller.submit()
        controller.stop()
        await waitFor("stopped") { !controller.isRunning }
        XCTAssertTrue(controller.selected.queue.isEmpty)
        XCTAssertEqual(controller.draft, "write this later", "nothing is lost, nothing is sent")
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertFalse(controller.entries.contains { $0.text == "write this later" })
    }

    func testWhatToDoWithTheQueueWhenARunEnds() {
        typealias Action = IDEAgentConversation.DrainAction
        XCTAssertEqual(IDEAgentConversation.drainAction(queued: [], ending: .completed), Action.none)
        XCTAssertEqual(IDEAgentConversation.drainAction(queued: ["a"], ending: .completed), .send("a"))
        XCTAssertEqual(IDEAgentConversation.drainAction(queued: ["a", "b"], ending: .completed), .send("a\n\nb"), "one message, not a run each")
        XCTAssertEqual(IDEAgentConversation.drainAction(queued: ["a"], ending: .stopped), .restore("a"))
        XCTAssertEqual(IDEAgentConversation.drainAction(queued: ["a"], ending: .failed("boom")), .restore("a"))
        XCTAssertEqual(IDEAgentConversation.drainAction(queued: ["a"], ending: .iterationCap), .restore("a"))
        XCTAssertEqual(IDEAgentConversation.drainAction(queued: ["a"], ending: nil), .restore("a"))
    }

    func testNothingIsQueuedWhenNoRunIsGoingOrTheTextIsBlank() async throws {
        let (controller, _) = makeController([MockTurn([.textDelta("slow"), .finished(.completed)], delayPerEvent: .milliseconds(200))])
        controller.selected.enqueue("not running")
        XCTAssertTrue(controller.selected.queue.isEmpty)
        controller.draft = "go"
        controller.submit()
        await waitFor("running") { controller.isRunning }
        controller.selected.enqueue("   ")
        XCTAssertTrue(controller.selected.queue.isEmpty)
        await waitFor("done") { !controller.isRunning }
    }

    func testACommandThatSendsAMessageStillWaitsForTheRunToEnd() async throws {
        let commands = project.appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try "Say $ARGUMENTS".write(to: commands.appendingPathComponent("say.md"), atomically: true, encoding: .utf8)
        let (controller, _) = makeController([slowRead(), .text("done")])
        await start(controller, "first")
        controller.draft = "/say hello"
        controller.submit()
        XCTAssertEqual(controller.draft, "/say hello", "kept in the field")
        XCTAssertTrue(controller.selected.queue.isEmpty)
        await waitFor("finished") { !controller.isRunning }
    }

    func testBuiltInCommandsRunDuringARun() async throws {
        let (controller, _) = makeController([slowRead(), .text("done")])
        await start(controller, "first")
        controller.draft = "/mode plan"
        controller.submit()
        XCTAssertEqual(controller.mode, .plan)
        XCTAssertTrue(controller.selected.queue.isEmpty)
        await waitFor("finished") { !controller.isRunning }
    }
}

@MainActor
final class IDEAgentShellShortcutTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-shell-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "marker\n".write(to: project.appendingPathComponent("A.txt"), atomically: true, encoding: .utf8)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    private func makeController(_ turns: [MockTurn] = [.text("ok")]) -> (IDEAgentController, MockLLMClient) {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let client = MockLLMClient(turns: turns)
        let controller = IDEAgentController(settings: settings, clientFactory: { _ in client })
        controller.attach(host: workspace)
        controller.newConversation()
        return (controller, client)
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<800 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func type(_ controller: IDEAgentController, _ text: String) async {
        controller.draft = text
        controller.submit()
        await waitFor("done") { !controller.isRunning }
    }

    func testABangCommandRunsInTheProjectAndShowsItsOutputWithoutTouchingTheModel() async throws {
        let (controller, client) = makeController()
        await type(controller, "!cat A.txt")
        XCTAssertEqual(controller.entries.first?.kind, .user)
        XCTAssertEqual(controller.entries.first?.text, "!cat A.txt")
        let card = try XCTUnwrap(controller.entries.first { if case .toolCall = $0.kind { true } else { false } })
        XCTAssertTrue(card.output?.text.contains("marker") == true, "it ran in the project folder")
        XCTAssertTrue(card.output?.text.contains("[exit code 0") == true)
        XCTAssertEqual(card.output?.isError, false)
        XCTAssertNil(card.approval, "you wrote it, so it did not ask")
        XCTAssertTrue(client.requests.isEmpty, "nothing was sent to the model")
        XCTAssertEqual(controller.draft, "")
    }

    func testTheOutputGoesToTheModelWithTheNextMessageAndTheRowSaysSo() async throws {
        let (controller, client) = makeController()
        await type(controller, "!echo built ok")
        await type(controller, "why did it build?")

        guard case .user(let sent) = try XCTUnwrap(client.requests.first?.items.first) else { return XCTFail("no message") }
        XCTAssertTrue(sent.contains("[Commands the user ran themselves since your last turn"))
        XCTAssertTrue(sent.contains("$ echo built ok") && sent.contains("built ok"))
        XCTAssertTrue(sent.hasSuffix("why did it build?"))
        let row = try XCTUnwrap(controller.entries.last { $0.kind == .user })
        XCTAssertEqual(row.text, "why did it build?", "the transcript shows what you wrote")
        XCTAssertNotNil(row.detail, "and the disclosure shows what the model got")

        // Only once: the next message does not repeat it.
        await type(controller, "and again?")
        XCTAssertEqual(controller.entries.last { $0.kind == .user }?.detail, nil)
    }

    func testAFailingCommandIsMarkedAndItsExitCodeIsKept() async throws {
        let (controller, client) = makeController()
        await type(controller, "!exit 3")
        let card = try XCTUnwrap(controller.entries.first { if case .toolCall = $0.kind { true } else { false } })
        XCTAssertEqual(card.output?.isError, true)
        XCTAssertTrue(card.output?.text.contains("exit code 3") == true)
        await type(controller, "what happened?")
        guard case .user(let sent) = try XCTUnwrap(client.requests.first?.items.first) else { return XCTFail("no message") }
        XCTAssertTrue(sent.contains("exit code 3"))
    }

    func testSeveralCommandsAreAllKeptInOrderForTheNextMessage() async throws {
        let (controller, client) = makeController()
        await type(controller, "!echo first-one")
        await type(controller, "!echo second-one")
        await type(controller, "summarize")
        guard case .user(let sent) = try XCTUnwrap(client.requests.first?.items.first) else { return XCTFail("no message") }
        let first = try XCTUnwrap(sent.range(of: "first-one"))
        let second = try XCTUnwrap(sent.range(of: "second-one"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
    }

    func testStopCancelsALongCommand() async throws {
        let (controller, _) = makeController()
        controller.draft = "!sleep 30"
        controller.submit()
        await waitFor("running") { controller.isRunning }
        controller.stop()
        await waitFor("stopped") { !controller.isRunning }
        let card = try XCTUnwrap(controller.entries.first { if case .toolCall = $0.kind { true } else { false } })
        XCTAssertTrue(card.output?.text.contains("cancelled") == true, card.output?.text ?? "")
    }

    func testABangCommandIsIgnoredWhileTheAgentIsWorkingAndStaysInTheField() async throws {
        let (controller, _) = makeController([MockTurn([.textDelta("slow"), .finished(.completed)], delayPerEvent: .milliseconds(300))])
        controller.draft = "go"
        controller.submit()
        await waitFor("running") { controller.isRunning }
        controller.draft = "!echo nope"
        controller.submit()
        XCTAssertEqual(controller.draft, "!echo nope")
        XCTAssertTrue(controller.selected.queue.isEmpty, "a command is not a message to queue")
        await waitFor("done") { !controller.isRunning }
        XCTAssertFalse(controller.entries.contains { $0.text == "!echo nope" })
    }

    func testABangAloneOrWithOnlySpacesIsNotACommand() async throws {
        let (controller, client) = makeController()
        await type(controller, "!")
        XCTAssertEqual(client.requests.count, 1, "it is just a message")
        XCTAssertFalse(controller.entries.contains { if case .toolCall = $0.kind { true } else { false } })
    }

    func testTheCommandIsRememberedInThePromptHistory() async throws {
        let (controller, _) = makeController()
        await type(controller, "!echo remembered")
        XCTAssertEqual(controller.promptHistory()?.prompts, ["!echo remembered"])
    }

    func testTheContextIsBoundedSoANoisyCommandCannotCrowdOutTheRest() {
        let noisy = String(repeating: "x", count: 50_000)
        let kept = IDEAgentShellContext.bounded(["small", noisy])
        XCTAssertEqual(kept[0], "small")
        XCTAssertLessThan(kept[1].count, 12_000)
        XCTAssertTrue(kept[1].contains("characters omitted"))

        let many = (0..<9).map { "command \($0)" }
        XCTAssertEqual(IDEAgentShellContext.bounded(many), Array(many.suffix(IDEAgentShellContext.maxCommands)), "the newest few")
        XCTAssertEqual(IDEAgentShellContext.prefix(for: []), "")
        XCTAssertTrue(IDEAgentShellContext.prefix(for: ["$ ls"]).hasSuffix("[End of the commands the user ran.]\n\n"))
    }
}

@MainActor
final class IDEAgentNotificationTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var workspace: IDEWorkspace!
    private var notified: [(chat: UUID, title: String, detail: String?, severity: IDENotificationSeverity)] = []

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-notify-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
        notified = []
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    private func makeController(_ turns: [MockTurn], watching: Bool = true) -> IDEAgentController {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let client = MockLLMClient(turns: turns)
        let controller = IDEAgentController(settings: settings, clientFactory: { _ in client })
        controller.attach(host: workspace)
        controller.newConversation()
        controller.isUserWatching = { watching }
        controller.onNotify = { [unowned self] chat, title, detail, severity in notified.append((chat, title, detail, severity)) }
        return controller
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<800 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func send(_ chat: IDEAgentConversation, _ text: String) async {
        chat.draft = text
        chat.send()
        await waitFor("done") { !chat.isRunning }
    }

    func testAChatThatFinishesInTheBackgroundTellsYouWhatItSaid() async throws {
        let controller = makeController([.text("All done.\nSecond line.")])
        let first = controller.selected
        controller.addConversation()
        await send(first, "do it")
        XCTAssertEqual(notified.count, 1)
        XCTAssertEqual(notified[0].chat, first.id)
        XCTAssertEqual(notified[0].title, "“do it” finished")
        XCTAssertEqual(notified[0].detail, "All done.", "the first line of its last answer")
        XCTAssertEqual(notified[0].severity, .success)
    }

    func testAChatYouAreLookingAtDoesNotNotify() async throws {
        let controller = makeController([.text("done")])
        controller.isPanelVisible = true
        await send(controller.selected, "hello")
        XCTAssertTrue(notified.isEmpty)
        XCTAssertTrue(controller.isInView(controller.selected))
    }

    func testAHiddenPanelOrAnInactiveWindowDoesNotCountAsLooking() async throws {
        let hidden = makeController([.text("done")])
        hidden.isPanelVisible = false
        await send(hidden.selected, "hello")
        XCTAssertEqual(notified.count, 1, "the panel is closed")

        notified = []
        let inactive = makeController([.text("done")], watching: false)
        inactive.isPanelVisible = true
        await send(inactive.selected, "hello")
        XCTAssertEqual(notified.count, 1, "the window is not the one in front")
        XCTAssertFalse(inactive.isInView(inactive.selected))
    }

    func testNeedingAnApprovalTellsYouWhatItWantsToRun() async throws {
        let controller = makeController([.toolCalls((id: "c", name: "run_command", arguments: #"{"command":"make deploy"}"#)), .text("ok")])
        let chat = controller.selected
        controller.addConversation()
        chat.draft = "deploy"
        chat.send()
        await waitFor("asked") { chat.isAwaitingUser }
        XCTAssertEqual(notified.count, 1)
        XCTAssertEqual(notified[0].title, "“deploy” needs you")
        XCTAssertEqual(notified[0].detail, "Wants to run: make deploy")
        XCTAssertEqual(notified[0].severity, .warning)
        chat.decide(callID: "c", .deny(note: nil))
        await waitFor("done") { !chat.isRunning }
    }

    func testAQuestionAndAPlanAlsoNeedYou() async throws {
        let controller = makeController([.toolCalls((id: "q", name: "ask_user", arguments: #"{"question":"Which database?"}"#)), .text("ok")])
        let chat = controller.selected
        controller.addConversation()
        chat.draft = "set it up"
        chat.send()
        await waitFor("asked") { chat.isAwaitingUser }
        XCTAssertEqual(notified.first?.detail, "Which database?")
        chat.answer(callID: "q", text: "Postgres")
        await waitFor("done") { !chat.isRunning }

        notified = []
        chat.handle(.planProposed(callID: "p", plan: "1. Do it"))
        XCTAssertEqual(notified.first?.detail, "A plan is ready for your approval.")
    }

    func testStopPressedBeforeTheSessionExistsStillStopsTheRun() async throws {
        let controller = makeController([.text("must not be asked")])
        controller.isPanelVisible = true
        controller.selected.draft = "go"
        controller.selected.send()
        XCTAssertNil(controller.selected.currentSessionForTesting, "the session is made asynchronously, after send returns")
        controller.stop()
        await waitFor("stopped") { !controller.isRunning }
        XCTAssertEqual(controller.entries.last?.text, "Stopped.")
        XCTAssertEqual(controller.entries.last?.kind, .notice)
    }

    func testAStoppedRunIsQuietAndAFailedOneSaysWhy() async throws {
        let stopped = makeController([MockTurn([.textDelta("slow"), .finished(.completed)], delayPerEvent: .milliseconds(300))])
        let chat = stopped.selected
        stopped.addConversation()
        chat.draft = "go"
        chat.send()
        await waitFor("running") { chat.isRunning }
        chat.stop()
        await waitFor("stopped") { !chat.isRunning }
        XCTAssertTrue(notified.isEmpty, "you pressed Stop, you know")

        let failing = makeController([MockTurn([], failure: .server(status: 500, message: "the server is down"))])
        let broken = failing.selected
        failing.addConversation()
        await send(broken, "go")
        XCTAssertEqual(notified.count, 1)
        XCTAssertEqual(notified[0].title, "“go” stopped")
        XCTAssertEqual(notified[0].severity, .error)
        XCTAssertNotNil(notified[0].detail)
    }

    func testTheWorkspacePostsToTheBellAndClickingOpensThatChat() async throws {
        let first = workspace.agent.selected
        let second = workspace.agent.addConversation()
        workspace.agent.select(first.id)
        workspace.agent.isPanelVisible = false

        workspace.agent.onNotify?(second.id, "“other” finished", "done", .success)
        let posted = try XCTUnwrap(workspace.notifications.items.first)
        XCTAssertEqual(posted.category, .agent)
        XCTAssertEqual(posted.action, .showAgentChat(second.id))
        XCTAssertEqual(posted.title, "“other” finished")

        workspace.activate(posted)
        XCTAssertEqual(workspace.agent.selectedID, second.id)
        XCTAssertTrue(workspace.agent.isPanelVisible)
    }

    func testAgentIsACategoryTheBellCanSwitchOff() {
        XCTAssertTrue(IDENotificationCategory.allCases.contains(.agent))
        XCTAssertEqual(IDENotificationCategory.agent.displayName, "Agent")
    }

    func testFirstLineIsCutAndSkipsBlankLines() {
        XCTAssertEqual(IDEAgentConversation.firstLine(of: "\n\n  hello there \nmore", limit: 50), "hello there")
        XCTAssertEqual(IDEAgentConversation.firstLine(of: String(repeating: "x", count: 300), limit: 10), "xxxxxxxxx…")
        XCTAssertEqual(IDEAgentConversation.firstLine(of: "", limit: 10), "")
    }
}

final class IDEAgentHistorySearchTests: XCTestCase {
    private func summary(_ title: String, _ seconds: Double) -> SessionSummary {
        SessionSummary(id: UUID(), title: title, updatedAt: Date(timeIntervalSince1970: seconds))
    }

    private lazy var all = [
        summary("fix the parser bug", 300), summary("write the release notes", 200), summary("refactor parser module", 100),
    ]

    func testAnEmptyQueryIsEverythingInTheOrderGiven() {
        XCTAssertEqual(IDEAgentHistorySearch.rank(all, query: "").map(\.title), all.map(\.title))
        XCTAssertEqual(IDEAgentHistorySearch.rank(all, query: "   ").map(\.title), all.map(\.title))
    }

    func testAQueryKeepsWhatMatchesBestMatchFirst() {
        let titles = IDEAgentHistorySearch.rank(all, query: "parser").map(\.title)
        XCTAssertEqual(Set(titles), ["fix the parser bug", "refactor parser module"])
        XCTAssertTrue(IDEAgentHistorySearch.rank(all, query: "zzzzz").isEmpty)
    }

    func testEqualMatchesKeepTheNewestFirst() {
        let same = [summary("same title", 300), summary("same title", 200), summary("same title", 100)]
        XCTAssertEqual(IDEAgentHistorySearch.rank(same, query: "same").map(\.updatedAt.timeIntervalSince1970), [300, 200, 100])
    }

    func testRequiringAMatchGivesNothingForABlankQuery() {
        XCTAssertTrue(IDEAgentHistorySearch.rank(all, query: "", requiresMatch: true).isEmpty)
        XCTAssertEqual(IDEAgentHistorySearch.rank(all, query: "release", requiresMatch: true).map(\.title), ["write the release notes"])
    }
}
