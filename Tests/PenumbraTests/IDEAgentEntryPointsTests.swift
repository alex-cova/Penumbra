import AgentKit
import Foundation
import XCTest
@testable import Umbra

final class IDEAgentPricesTests: XCTestCase {
    func testLongestPrefixWinsAndUnknownModelsHaveNoPrice() {
        let prices = IDEAgentPrices(text: "gpt-4o 2.5 1.25 10\ngpt-4o-mini 0.15 0.075 0.6\n")
        XCTAssertEqual(prices.entry(for: "gpt-4o-2024-08-06")?.prefix, "gpt-4o")
        XCTAssertEqual(prices.entry(for: "GPT-4o-mini")?.prefix, "gpt-4o-mini")
        XCTAssertNil(prices.entry(for: "llama3"))
        XCTAssertNil(prices.cost(of: TokenUsage(inputTokens: 1_000, outputTokens: 10), model: "llama3"))
    }

    func testCachedTokensArePricedSeparatelyAndAreNotCountedTwice() throws {
        let prices = IDEAgentPrices(text: "m 2 0.5 8")
        // 600k fresh + 400k cached input, 100k output (reasoning is part of output).
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 100_000, cachedInputTokens: 400_000, reasoningTokens: 60_000)
        let cost = try XCTUnwrap(prices.cost(of: usage, model: "m"))
        XCTAssertEqual(cost, 0.6 * 2 + 0.4 * 0.5 + 0.1 * 8, accuracy: 1e-9)
        // A bogus count of cached tokens above the input can't make the input free or negative.
        XCTAssertEqual(try XCTUnwrap(prices.cost(of: TokenUsage(inputTokens: 100, outputTokens: 0, cachedInputTokens: 500), model: "m")),
                       100 * 0.5 / 1_000_000, accuracy: 1e-12)
    }

    func testTheTableParsesCommentsCommasAndSkipsBrokenLines() {
        let prices = IDEAgentPrices(text: """
        # header
        a 1 2 3   # trailing comment
        b, 4, 5, 6
        broken line here
        c 1 2
        d -1 0 0
        e x y z
        """)
        XCTAssertEqual(prices.entries.map(\.prefix), ["a", "b"])
        XCTAssertEqual(prices.entries[1].output, 6)
        XCTAssertFalse(IDEAgentPrices.default.entries.isEmpty)
    }

    func testFormatting() {
        XCTAssertEqual(IDEAgentPrices.format(0), "<$0.01")
        XCTAssertEqual(IDEAgentPrices.format(0.004), "<$0.01")
        XCTAssertEqual(IDEAgentPrices.format(0.456), "$0.46")
        XCTAssertEqual(IDEAgentPrices.format(12.34), "$12.3")
    }
}

final class IDEAgentPromptsTests: XCTestCase {
    func testSelectionPromptQuotesTheCodeWithItsLocationAndLeavesRoomForAQuestion() {
        let text = IDEAgentPrompts.aboutSelection(path: "src/A.java", startLine: 3, endLine: 4, text: "int a;\nint b;\n")
        XCTAssertEqual(text, "About `src/A.java`, lines 3–4:\n\n```java\nint a;\nint b;\n```\n\n")
        XCTAssertTrue(IDEAgentPrompts.aboutSelection(path: "A.java", startLine: 7, endLine: 7, text: "x").hasPrefix("About `A.java`, line 7:"))
    }

    func testCodeContainingFencesCannotCloseTheQuoteEarlyAndLongSelectionsAreCut() {
        let tricky = IDEAgentPrompts.aboutSelection(path: "README.md", startLine: 1, endLine: 3, text: "a\n```\nb\n")
        XCTAssertTrue(tricky.contains("````md\na\n```\nb\n````"), tricky)
        let long = IDEAgentPrompts.aboutSelection(
            path: "A.txt", startLine: 1, endLine: 1, text: String(repeating: "x", count: IDEAgentPrompts.selectionLimit + 500))
        XCTAssertTrue(long.contains("The selection was cut here"))
        XCTAssertLessThan(long.count, IDEAgentPrompts.selectionLimit + 200)
    }

    func testFixPromptNamesTheProblemWhereItIsAndWhoReportedIt() {
        let text = IDEAgentPrompts.fixProblem(
            path: "src/A.java", line: 12, column: 5, severity: "Error", source: "javac", message: "cannot find symbol")
        XCTAssertTrue(text.hasPrefix("Fix this error in `src/A.java` at line 12, column 5 (reported by javac):"))
        XCTAssertTrue(text.contains("cannot find symbol"))
        XCTAssertFalse(IDEAgentPrompts.fixProblem(path: "A", line: 1, column: 1, severity: "Warning", source: "", message: "m").contains("reported by"))
    }
}

@MainActor
final class IDEAgentEntryPointsTests: XCTestCase {
    private var project: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        project = FileManager.default.temporaryDirectory.appendingPathComponent("agent-entry-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
    }

    /// An editor view needs the adapter that `bootstrap()` wires, which the window runs when it appears.
    private func waitForEditorSupport() async {
        workspace.bootstrap()
    }

    private func makeSettings(disclosed: Bool = true) -> IDEAgentSettings {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        if disclosed { settings.acceptDisclosure() }
        return settings
    }

    private func controller(_ turns: [MockTurn] = [.text("ok")], settings: IDEAgentSettings? = nil) -> (IDEAgentController, MockLLMClient) {
        let client = MockLLMClient(turns: turns)
        let controller = IDEAgentController(settings: settings ?? makeSettings(), clientFactory: { _ in client })
        controller.attach(host: workspace)
        return (controller, client)
    }

    private func waitIdle(_ controller: IDEAgentController) async {
        for _ in 0..<500 where controller.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testGitToolsAreOfferedInARepositoryAndJavaToolsOnlyWithJava() async throws {
        let plain = controller()
        plain.0.draft = "hi"
        plain.0.send()
        await waitIdle(plain.0)
        var names = Set(plain.1.requests.first?.tools.map(\.name) ?? [])
        XCTAssertFalse(names.contains("git_status") || names.contains("git_diff"), "not a repository")
        XCTAssertFalse(names.contains("go_to_definition") || names.contains("find_usages"), "no Java in this project")

        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q"]
        git.currentDirectoryURL = project
        try git.run()
        git.waitUntilExit()
        try "class A {}\n".write(to: project.appendingPathComponent("src/A.java"), atomically: true, encoding: .utf8)
        await waitForEditorSupport()
        await workspace.openDocument(from: project.appendingPathComponent("src/A.java"))

        let repo = controller()
        repo.0.draft = "hi"
        repo.0.send()
        await waitIdle(repo.0)
        names = Set(repo.1.requests.first?.tools.map(\.name) ?? [])
        XCTAssertTrue(names.isSuperset(of: ["git_status", "git_diff", "go_to_definition", "find_usages"]), "\(names.sorted())")
    }

    /// The setting is shared by every window and lives in `UserDefaults`; put it back after a test.
    private func withPageLayout(_ page: Bool) -> () -> Void {
        let settings = workspace.agent.settings
        let original = settings.opensAsPage
        settings.opensAsPage = page
        return { settings.opensAsPage = original }
    }

    func testDockedBesideTheEditorIsTheDefaultAndNothingElseClosesIt() async throws {
        let restore = withPageLayout(false)
        defer { restore() }
        await waitForEditorSupport()
        let file = project.appendingPathComponent("src/A.java")
        try "class A {}\n".write(to: file, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: file)

        workspace.toggleAgentPanel()
        XCTAssertTrue(workspace.agent.isPanelVisible)
        XCTAssertFalse(workspace.agent.coversEditor, "docked, it leaves the editor visible")

        workspace.showSettings()
        XCTAssertTrue(workspace.isSettingsVisible && workspace.agent.isPanelVisible, "Settings does not close a docked chat")
        workspace.hideSettings()

        let id = try XCTUnwrap(workspace.workbench.activePane.selectedDocumentID)
        workspace.selectTab(id)
        await workspace.openDocument(from: file)
        XCTAssertTrue(workspace.agent.isPanelVisible, "working in the editor keeps the chat open next to it")

        workspace.agent.compose("hello", send: false)
        XCTAssertTrue(workspace.agent.isPanelVisible && !workspace.agent.coversEditor)
        workspace.toggleAgentPanel()
        XCTAssertFalse(workspace.agent.isPanelVisible, "the brain button closes it")
    }

    func testTheChatOpensInPlaceOfSettingsAndSettingsInPlaceOfTheChat() async {
        let restore = withPageLayout(true)
        defer { restore() }
        await waitForEditorSupport()
        workspace.showSettings()
        XCTAssertTrue(workspace.isSettingsVisible)

        workspace.toggleAgentPanel()
        XCTAssertTrue(workspace.agent.isPanelVisible)
        XCTAssertFalse(workspace.isSettingsVisible, "only one of the two covers the editor")

        workspace.showSettings()
        XCTAssertTrue(workspace.isSettingsVisible)
        XCTAssertFalse(workspace.agent.isPanelVisible)

        workspace.agent.compose("hello", send: false)
        XCTAssertTrue(workspace.agent.isPanelVisible)
        XCTAssertFalse(workspace.isSettingsVisible, "Ask Agent / Fix with Agent also take Settings' place")

        workspace.toggleAgentPanel()
        XCTAssertFalse(workspace.agent.isPanelVisible, "the brain button closes it again")
    }

    func testSwitchingToAnEditorTabClosesTheChatWhenItIsAPage() async throws {
        let restore = withPageLayout(true)
        defer { restore() }
        let file = project.appendingPathComponent("src/A.java")
        try "class A {}\n".write(to: file, atomically: true, encoding: .utf8)
        await waitForEditorSupport()
        await workspace.openDocument(from: file)
        workspace.toggleAgentPanel()
        XCTAssertTrue(workspace.agent.isPanelVisible)
        let id = try XCTUnwrap(workspace.workbench.activePane.selectedDocumentID)
        workspace.selectTab(id)
        XCTAssertFalse(workspace.agent.isPanelVisible, "clicking a tab shows the editor, as it does over Settings")

        workspace.toggleAgentPanel()
        await workspace.openDocument(from: file)
        XCTAssertFalse(workspace.agent.isPanelVisible, "so does opening a file")
    }

    func testTheChatNeedsAnOpenProject() {
        let empty = IDEWorkspace()
        defer { empty.teardown() }
        empty.toggleAgentPanel()
        XCTAssertFalse(empty.agent.isPanelVisible)
    }

    func testComposeFillsTheDraftAndFocusesTheComposerWithoutSending() {
        let (agent, client) = controller()
        agent.draft = "my own note"
        let before = agent.composerFocusRequest
        agent.compose("About `A.java`:\n\n", send: false)
        XCTAssertTrue(agent.isPanelVisible)
        XCTAssertEqual(agent.draft, "my own note\n\nAbout `A.java`:\n\n")
        XCTAssertEqual(agent.composerFocusRequest, before + 1)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testComposeAndSendStartsARunAndKeepsTheUsersDraft() async {
        let (agent, client) = controller()
        agent.draft = "half-typed thought"
        agent.compose("Fix this error", send: true)
        await waitIdle(agent)
        XCTAssertEqual(client.requests.count, 1)
        guard case .user(let sent)? = client.requests.first?.items.first else { return XCTFail("no user message") }
        XCTAssertTrue(sent.hasSuffix("Fix this error"))
        XCTAssertEqual(agent.draft, "half-typed thought", "the draft survives")
    }

    func testWithoutConsentOrDuringARunTheTextWaitsInTheComposer() async {
        let (needsConsent, client) = controller(settings: makeSettings(disclosed: false))
        needsConsent.compose("Fix this error", send: true)
        XCTAssertTrue(client.requests.isEmpty, "nothing is sent to a host the user hasn't allowed")
        XCTAssertEqual(needsConsent.draft, "Fix this error")
        XCTAssertTrue(needsConsent.isPanelVisible, "the panel opens, where the consent card is")

        let (busy, busyClient) = controller([MockTurn([.textDelta("a"), .textDelta("b"), .finished(.completed)], delayPerEvent: .milliseconds(80))])
        busy.draft = "first"
        busy.send()
        busy.compose("second", send: true)
        XCTAssertEqual(busy.draft, "second", "a run in progress is not interrupted or queued behind the user's back")
        await waitIdle(busy)
        XCTAssertEqual(busyClient.requests.count, 1)
    }

    func testAskAboutSelectionQuotesTheSelectedLinesFromTheActiveEditor() async throws {
        let file = project.appendingPathComponent("src/A.java")
        try "class A {\n  int a;\n  int b;\n}\n".write(to: file, atomically: true, encoding: .utf8)
        await waitForEditorSupport()
        await workspace.openDocument(from: file)
        let textView = workspace.host(for: workspace.workbench.activePaneID).textView
        let selected = (textView.text ?? "" as String) as NSString
        textView.selectedRange = selected.range(of: "  int a;\n  int b;\n")
        workspace.askAgentAboutActiveSelection()

        XCTAssertTrue(workspace.agent.isPanelVisible)
        XCTAssertEqual(workspace.agent.draft, "About `src/A.java`, lines 2–3:\n\n```java\n  int a;\n  int b;\n```\n\n")
    }

    func testAnEmptySelectionAddsNoMenuItemAndANonEmptyOneDoes() async throws {
        let file = project.appendingPathComponent("src/A.java")
        try "class A {}\n".write(to: file, atomically: true, encoding: .utf8)
        await waitForEditorSupport()
        await workspace.openDocument(from: file)
        let textView = workspace.host(for: workspace.workbench.activePaneID).textView
        XCTAssertTrue(workspace.agentContextMenuItems(context: .init(location: 0, selectedRange: NSRange(location: 0, length: 0)), textView: textView, url: file).isEmpty)
        let items = workspace.agentContextMenuItems(context: .init(location: 0, selectedRange: NSRange(location: 0, length: 5)), textView: textView, url: file)
        XCTAssertEqual(items.last?.title, "Ask Agent About Selection")
    }

    func testCostIsEstimatedPerTurnSavedAndRestoredAndLocalModelsHaveNone() async throws {
        let store = SessionStore(directory: project.appendingPathComponent("store"))
        let settings = makeSettings()
        settings.model = "gpt-5"
        settings.priceTableText = "gpt-5 1 0 2"
        let usage = TokenUsage(inputTokens: 1_000_000, outputTokens: 500_000)
        let client = MockLLMClient(turns: [MockTurn([.textDelta("hi"), .usage(usage), .finished(.completed)])])
        let first = IDEAgentController(settings: settings, store: store, clientFactory: { _ in client })
        first.attach(host: workspace)
        first.draft = "go"
        first.send()
        await waitIdle(first)
        XCTAssertEqual(try XCTUnwrap(first.cost), 1.0 * 1 + 0.5 * 2, accuracy: 1e-9)

        let second = IDEAgentController(settings: settings, store: store, clientFactory: { _ in client })
        second.attach(host: workspace)
        second.restoreLatestIfNeeded()
        XCTAssertEqual(try XCTUnwrap(second.cost), 2.0, accuracy: 1e-9, "the total comes back with the conversation")

        // A turn the table can't price makes the total unknown rather than too low.
        settings.model = "mystery-model"
        second.handle(.usage(TokenUsage(inputTokens: 10, outputTokens: 10)))
        XCTAssertNil(second.cost)

        settings.provider = .ollama
        settings.model = "qwen"
        XCTAssertNil(settings.cost(of: usage), "a local model costs nothing to show")
    }

    func testAnOldTranscriptWithoutACostReadsAsUnknownNotZero() throws {
        let rows = [IDEAgentEntry(kind: .user, text: "q")]
        let legacy = IDEAgentPersistedEntry.encode(rows)
        let decoded = IDEAgentSavedTranscript.decode(legacy)
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertNil(decoded.cost)
        XCTAssertEqual(IDEAgentSavedTranscript.decode(nil).cost, 0)
        let current = IDEAgentSavedTranscript.decode(IDEAgentSavedTranscript.encode(entries: rows, cost: 1.5))
        XCTAssertEqual(current.cost, 1.5)
    }
}
