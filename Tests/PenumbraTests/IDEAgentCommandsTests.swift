import AgentKit
import Foundation
import XCTest

@testable import Umbra

final class IDEAgentSlashInvocationTests: XCTestCase {
    func testACommandIsANameAtTheStartFollowedBySpaceOrNothing() {
        XCTAssertEqual(IDEAgentSlashInvocation.parse("/new"), .init(name: "new", arguments: ""))
        XCTAssertEqual(IDEAgentSlashInvocation.parse("  /resume parser fix  "), .init(name: "resume", arguments: "parser fix"))
        XCTAssertEqual(IDEAgentSlashInvocation.parse("/frontend:lint src/ --fix"), .init(name: "frontend:lint", arguments: "src/ --fix"))
        XCTAssertEqual(IDEAgentSlashInvocation.parse("/plan\nsecond line"), .init(name: "plan", arguments: "second line"))
    }

    func testPathsAndOrdinarySentencesAreNotCommands() {
        XCTAssertNil(IDEAgentSlashInvocation.parse("/usr/bin is missing"))
        XCTAssertNil(IDEAgentSlashInvocation.parse("/"))
        XCTAssertNil(IDEAgentSlashInvocation.parse("/ new"))
        XCTAssertNil(IDEAgentSlashInvocation.parse("look at /new"))
        XCTAssertNil(IDEAgentSlashInvocation.parse("//comment"))
        XCTAssertNil(IDEAgentSlashInvocation.parse(""))
    }

    func testModesAreUnderstoodAsPeopleWriteThem() {
        XCTAssertEqual(PermissionMode(spoken: "Accept Edits"), .acceptEdits)
        XCTAssertEqual(PermissionMode(spoken: "accept-edits"), .acceptEdits)
        XCTAssertEqual(PermissionMode(spoken: "accept"), .acceptEdits)
        XCTAssertEqual(PermissionMode(spoken: "AUTO"), .auto)
        XCTAssertEqual(PermissionMode(spoken: "manual"), .manual)
        XCTAssertEqual(PermissionMode(spoken: "plan"), .plan)
        XCTAssertNil(PermissionMode(spoken: "yolo"))
        XCTAssertNil(PermissionMode(spoken: ""))
    }

    func testTheExportIsReadableMarkdownAndTheFileNameIsSafe() {
        var tool = IDEAgentEntry(kind: .toolCall(name: "read_file"), text: #"{"path":"A.java"}"#, callID: "c")
        tool.approvalOutcome = "Approved"
        var changes = IDEAgentEntry(kind: .changes, text: "")
        changes.fileChanges = [IDEAgentFileChange(path: "A.java", original: "x")]
        let markdown = IDEAgentTranscriptExport.markdown(
            title: "Fix the parser", entries: [
                IDEAgentEntry(kind: .user, text: "Please fix it"), tool, IDEAgentEntry(kind: .assistant, text: "Done."), changes,
                IDEAgentEntry(kind: .notice, text: "Stopped."), IDEAgentEntry(kind: .error, text: "Boom"),
            ], exportedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(markdown.hasPrefix("# Fix the parser\n"))
        for expected in ["## You\n\nPlease fix it", "## Agent\n\nDone.", "Ran `read_file`", "(approved)", "Changed 1 file: `A.java`", "_Stopped._", "> **Error:** Boom"] {
            XCTAssertTrue(markdown.contains(expected), "missing \(expected)")
        }
        XCTAssertEqual(IDEAgentTranscriptExport.fileName(for: "Fix the parser / now!"), "fix-the-parser-now.md")
        XCTAssertEqual(IDEAgentTranscriptExport.fileName(for: "???"), "chat.md")
        XCTAssertEqual(IDEAgentTranscriptExport.fileName(for: String(repeating: "a", count: 200)).count, 63)
    }
}

@MainActor
final class IDEAgentCommandCatalogTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var home: URL!
    private var appSupport: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-catalog-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project")
        home = base.appendingPathComponent("home")
        appSupport = base.appendingPathComponent("support")
        for url in [project!, home!, appSupport!] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func write(_ text: String, _ root: URL, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func catalog(userFolders: Bool = true, now: @escaping () -> Date = Date.init) -> IDEAgentCommandCatalog {
        IDEAgentCommandCatalog(
            root: { [project] in project }, loadsUserFolders: { userFolders }, home: home, appSupport: appSupport, now: now)
    }

    func testBuiltInsComeFirstThenCommandsThenSkills() throws {
        try write("Lint $ARGUMENTS", project, ".claude/commands/lint.md")
        try write("---\ndescription: Reviews\n---\nDo it", project, ".claude/skills/review/SKILL.md")
        let names = catalog().descriptors.map(\.name)
        XCTAssertEqual(Array(names.prefix(IDEAgentBuiltInCommand.allCases.count)), IDEAgentBuiltInCommand.allCases.map(\.rawValue))
        XCTAssertEqual(Array(names.suffix(2)), ["lint", "review"])
    }

    func testFoldersWinInOrderProjectThenUserThenUmbra() throws {
        try write("project one", project, ".claude/commands/go.md")
        try write("user one", home, ".claude/commands/go.md")
        try write("umbra one", appSupport, "commands/go.md")
        try write("umbra only", appSupport, "commands/extra.md")
        try write("umbra dir", project, ".umbra/commands/go.md")

        let catalog = catalog()
        let go = try XCTUnwrap(catalog.descriptor(named: "go"))
        guard case .custom(let template) = go.kind else { return XCTFail("expected a custom command") }
        XCTAssertEqual(template.body, "umbra dir", ".umbra in the project is first")
        XCTAssertEqual(template.source, ".umbra/commands")
        XCTAssertNotNil(catalog.descriptor(named: "extra"))
    }

    func testTheUserFoldersCanBeTurnedOff() throws {
        try write("from home", home, ".claude/commands/homey.md")
        try write("from support", appSupport, "commands/supporty.md")
        let off = catalog(userFolders: false)
        XCTAssertNil(off.descriptor(named: "homey"))
        XCTAssertNotNil(off.descriptor(named: "supporty"), "Umbra's own folder stays")
        XCTAssertNotNil(catalog(userFolders: true).descriptor(named: "homey"))
    }

    func testABuiltInKeepsItsNameAndACommandBeatsASkill() throws {
        try write("shadow", project, ".claude/commands/new.md")
        try write("---\ndescription: s\n---\nskill body", project, ".claude/skills/clash/SKILL.md")
        try write("command body", project, ".claude/commands/clash.md")
        let catalog = catalog()
        guard case .builtIn = try XCTUnwrap(catalog.descriptor(named: "new")).kind else { return XCTFail("the built-in keeps /new") }
        guard case .custom = try XCTUnwrap(catalog.descriptor(named: "clash")).kind else { return XCTFail("the command wins") }
        XCTAssertEqual(catalog.descriptors.filter { $0.name == "clash" }.count, 1)
    }

    func testTheReadIsKeptBrieflyAndCanBeForgotten() throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let catalog = catalog(now: { clock })
        XCTAssertNil(catalog.descriptor(named: "later"))
        try write("hi", project, ".claude/commands/later.md")
        XCTAssertNil(catalog.descriptor(named: "later"), "still the read from a moment ago")

        clock = clock.addingTimeInterval(IDEAgentCommandCatalog.lifetime + 0.1)
        XCTAssertNotNil(catalog.descriptor(named: "later"), "read again once it is stale")

        try write("hi", project, ".claude/commands/sooner.md")
        catalog.invalidate()
        XCTAssertNotNil(catalog.descriptor(named: "sooner"))
    }

    func testWhichCommandsRunAtOnceWhenAccepted() throws {
        try write("---\nargument-hint: <dir>\n---\nLint $ARGUMENTS", project, ".claude/commands/lint.md")
        try write("Run the formatter.", project, ".claude/commands/fmt.md")
        try write("---\ndescription: x\n---\nbody", project, ".claude/skills/review/SKILL.md")
        let catalog = catalog()
        let byName = { (name: String) in catalog.descriptor(named: name)!.takesNoArguments }
        XCTAssertTrue(byName("new") && byName("clear") && byName("help") && byName("init") && byName("cost"))
        XCTAssertFalse(byName("resume") || byName("plan") || byName("mode") || byName("rename"))
        XCTAssertFalse(byName("lint"), "it has an argument hint")
        XCTAssertTrue(byName("fmt"), "nothing to add after its name")
        XCTAssertFalse(byName("review"), "a skill may be given arguments")
    }
}

@MainActor
final class IDEAgentCommandRunTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var home: URL!
    private var storeDirectory: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-commands-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project")
        home = base.appendingPathComponent("home")
        storeDirectory = base.appendingPathComponent("store")
        for url in [project!, home!] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
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

    private func write(_ text: String, _ path: String) throws {
        let url = project.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeController(
        _ turns: [MockTurn] = [.text("ok")], disclosed: Bool = true, client: MockLLMClient? = nil
    ) -> (IDEAgentController, MockLLMClient) {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        if disclosed { settings.acceptDisclosure() }
        let client = client ?? MockLLMClient(turns: turns)
        let controller = IDEAgentController(
            settings: settings, store: SessionStore(directory: storeDirectory), commandsHome: home, clientFactory: { _ in client })
        controller.attach(host: workspace)
        controller.newConversation()  // no restoring of an earlier chat
        return (controller, client)
    }

    private func waitFor(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<800 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func type(_ controller: IDEAgentController, _ text: String) {
        controller.draft = text
        controller.submit()
    }

    private func lastNotice(_ controller: IDEAgentController) -> String? { controller.entries.last { $0.kind == .notice }?.text }

    // MARK: - Built-ins

    func testHelpListsEveryCommandIncludingYours() throws {
        try write("Lint it", ".claude/commands/lint.md")
        let (controller, _) = makeController()
        type(controller, "/help")
        let help = try XCTUnwrap(lastNotice(controller))
        for command in IDEAgentBuiltInCommand.allCases { XCTAssertTrue(help.contains("/\(command.rawValue)"), "/\(command.rawValue)") }
        XCTAssertTrue(help.contains("/lint"))
        XCTAssertEqual(controller.draft, "", "the command left the field")
    }

    func testBuiltInsWorkBeforeTheUserHasAcceptedTheDisclosure() {
        let (controller, _) = makeController(disclosed: false)
        type(controller, "/help")
        XCTAssertNotNil(lastNotice(controller))
    }

    func testNewOpensATabAndClearEmptiesTheChat() async {
        let (controller, _) = makeController([.text("hi")])
        type(controller, "hello")
        await waitFor("done") { !controller.isRunning }
        type(controller, "/new")
        XCTAssertEqual(controller.conversations.count, 2)
        XCTAssertTrue(controller.selected.isEmpty)

        controller.select(controller.conversations[0].id)
        type(controller, "/clear")
        XCTAssertEqual(controller.conversations.count, 2)
        XCTAssertTrue(controller.selected.isEmpty)
    }

    func testModeAndPlanChangeTheChatsMode() async throws {
        let (controller, client) = makeController([.text("Here is the plan.")])
        type(controller, "/mode auto")
        XCTAssertEqual(controller.mode, .auto)
        type(controller, "/mode Accept Edits")
        XCTAssertEqual(controller.mode, .acceptEdits)
        type(controller, "/mode nonsense")
        XCTAssertEqual(controller.mode, .acceptEdits)
        XCTAssertTrue(try XCTUnwrap(lastNotice(controller)).contains("is not a mode"))

        type(controller, "/plan restructure the parser")
        XCTAssertEqual(controller.mode, .plan)
        await waitFor("the plan request ran") { !controller.isRunning && !client.requests.isEmpty }
        XCTAssertEqual(controller.entries.first { $0.kind == .user }?.text, "restructure the parser")
        XCTAssertFalse(try XCTUnwrap(client.requests.first).tools.map(\.name).contains("edit_file"))
    }

    func testModeWithNoArgumentOpensTheArgumentList() {
        let (controller, _) = makeController()
        type(controller, "/mode")
        XCTAssertEqual(controller.draft, "/mode ")
        let rows = controller.suggestions(for: .detect(in: controller.draft, caret: 6))
        XCTAssertEqual(rows.compactMap(\.payload), PermissionMode.allCases.map { .mode($0) })
    }

    func testRenameCostAndAnUnknownNameBehaveSensibly() async throws {
        let (controller, _) = makeController([.text("ok")])
        type(controller, "/rename")
        XCTAssertTrue(try XCTUnwrap(lastNotice(controller)).contains("/rename <name>"))
        type(controller, "/rename Parser work")
        XCTAssertEqual(controller.selected.title, "Parser work")

        type(controller, "/cost")
        XCTAssertEqual(lastNotice(controller), "Nothing has been sent in this chat yet.")

        type(controller, "/etc is the folder with configs")
        await waitFor("sent as an ordinary message") { !controller.isRunning && controller.entries.contains { $0.text == "/etc is the folder with configs" } }
        type(controller, "/nosuchcommand please")
        await waitFor("an unknown command is an ordinary message") { !controller.isRunning && controller.entries.contains { $0.text == "/nosuchcommand please" } }
    }

    func testCostReportsTokensAndPrice() {
        XCTAssertEqual(
            IDEAgentController.costNotice(usage: TokenUsage(inputTokens: 1_500, outputTokens: 200, cachedInputTokens: 1_000), cost: 0.0123),
            "1.5K tokens in (1.0K cached), 200 out. About $0.01.")
        XCTAssertTrue(IDEAgentController.costNotice(usage: TokenUsage(inputTokens: 5, outputTokens: 5), cost: nil).contains("no cost estimate"))
    }

    func testInitSendsTheCannedPromptButShowsTheCommand() async throws {
        let (controller, client) = makeController([.text("written")])
        type(controller, "/init")
        await waitFor("sent") { !controller.isRunning && !client.requests.isEmpty }
        let user = try XCTUnwrap(controller.entries.first { $0.kind == .user })
        XCTAssertEqual(user.text, "/init")
        XCTAssertEqual(user.detail, IDEAgentController.initPrompt)
        guard case .user(let sent) = try XCTUnwrap(client.requests.first).items.first else { return XCTFail("no user item") }
        XCTAssertTrue(sent.hasSuffix(IDEAgentController.initPrompt))
    }

    func testExportHandsMarkdownAndAFileNameToTheSavePanel() async throws {
        let (controller, _) = makeController([.text("answer")])
        type(controller, "Explain the build")
        await waitFor("done") { !controller.isRunning }
        var saved: (name: String, text: String)?
        controller.exportHandler = { saved = ($0, $1) }
        type(controller, "/export")
        let result = try XCTUnwrap(saved)
        XCTAssertEqual(result.name, "explain-the-build.md")
        XCTAssertTrue(result.text.contains("## You\n\nExplain the build") && result.text.contains("## Agent\n\nanswer"))
    }

    func testModelAndPermissionsAskTheWindow() {
        let (controller, _) = makeController()
        var opened = 0
        controller.onOpenSettings = { opened += 1 }
        let before = controller.settingsRequest
        type(controller, "/permissions")
        type(controller, "/model")
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(controller.settingsRequest, before + 1)
    }

    // MARK: - Resume

    func testResumeWithASearchOpensTheBestMatchAndWithoutOneShowsTheList() async throws {
        let (first, _) = makeController([.text("a")])
        type(first, "parser refactor")
        await waitFor("saved") { !first.isRunning && first.history.count == 1 }
        type(first, "/new")
        type(first, "database migration")
        await waitFor("saved") { !first.isRunning && first.history.count == 2 }

        type(first, "/resume")
        XCTAssertEqual(first.draft, "/resume ", "the list of chats is the argument picker")
        let rows = first.suggestions(for: .detect(in: first.draft, caret: 8))
        XCTAssertEqual(Set(rows.map(\.title)), ["parser refactor", "database migration"])
        XCTAssertTrue(rows.allSatisfy { if case .resume = $0.payload { true } else { false } })
        XCTAssertTrue(rows.allSatisfy { $0.detail?.contains("open") == true }, "both are open in tabs")
        let narrowed = first.suggestions(for: .detect(in: "/resume migr", caret: 12))
        XCTAssertEqual(narrowed.map(\.title), ["database migration"])

        first.draft = ""
        type(first, "/resume parser")
        XCTAssertEqual(first.selected.entries.first?.text, "parser refactor")
        type(first, "/resume zzzz")
        XCTAssertTrue(try XCTUnwrap(lastNotice(first)).contains("No saved chat matches"))
    }

    // MARK: - Commands and skills you wrote

    func testACustomCommandSendsItsExpansionAndShowsWhatWasTyped() async throws {
        try write("---\ndescription: Fix something\nallowed-tools: Bash(echo:*)\n---\nPlease fix $1 in the $2 module.", ".claude/commands/fix.md")
        let (controller, client) = makeController([.text("on it")])
        type(controller, "/fix parser core")
        await waitFor("sent") { !controller.isRunning && !client.requests.isEmpty }

        let user = try XCTUnwrap(controller.entries.first { $0.kind == .user })
        XCTAssertEqual(user.text, "/fix parser core")
        XCTAssertEqual(user.detail, "Please fix parser in the core module.")
        guard case .user(let sent) = try XCTUnwrap(client.requests.first).items.first else { return XCTFail("no user item") }
        XCTAssertTrue(sent.hasSuffix("Please fix parser in the core module."))
    }

    func testACommandsAllowedToolsAreRulesForThatRunOnly() async throws {
        try write("---\nallowed-tools: Bash(echo:*)\n---\nSay hi with echo.", ".claude/commands/hi.md")
        let (controller, _) = makeController([
            .toolCalls((id: "c1", name: "run_command", arguments: #"{"command":"echo hi"}"#)), .text("done"),
            .toolCalls((id: "c2", name: "run_command", arguments: #"{"command":"echo again"}"#)), .text("done"),
        ])
        type(controller, "/hi")
        await waitFor("the first run ends") { !controller.isRunning }
        XCTAssertNil(controller.entries.first { $0.approvalOutcome != nil || $0.approval != nil }, "the command's tool did not ask")
        XCTAssertTrue(controller.entries.first { $0.callID == "c1" }?.output?.text.contains("hi") == true)

        type(controller, "now echo something else")
        await waitFor("the second run asks") { controller.entries.contains { $0.callID == "c2" && $0.approval != nil } }
        controller.decide(callID: "c2", .deny(note: nil))
        await waitFor("the second run ends") { !controller.isRunning }
    }

    func testASkillRunByHandCarriesItsInstructionsAndTheModelCanLoadItToo() async throws {
        try write("---\nname: review\ndescription: Review a diff\n---\nRead the diff and list risks.", ".claude/skills/review/SKILL.md")
        try write("extra notes", ".claude/skills/review/notes.md")
        let (controller, client) = makeController([.text("reviewed")])
        type(controller, "/review the last commit")
        await waitFor("sent") { !controller.isRunning && !client.requests.isEmpty }

        let user = try XCTUnwrap(controller.entries.first { $0.kind == .user })
        XCTAssertEqual(user.text, "/review the last commit")
        XCTAssertTrue(user.detail?.hasPrefix("[Skill: review]\nRead the diff and list risks.") == true)
        XCTAssertTrue(user.detail?.hasSuffix("Arguments: the last commit") == true)
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertTrue(request.tools.map(\.name).contains("skill"), "the model is offered the skill tool")
        XCTAssertTrue(try XCTUnwrap(request.tools.first { $0.name == "skill" }).description.contains("- review: Review a diff"))
    }

    func testNoSkillsMeansNoSkillToolAndAChangedSkillStartsANewSessionThatKeepsTheConversation() async throws {
        let (controller, client) = makeController([.text("one"), .text("two"), .text("three"), .text("four")])
        type(controller, "first")
        await waitFor("first done") { !controller.isRunning }
        XCTAssertFalse(try XCTUnwrap(client.requests.first).tools.map(\.name).contains("skill"))
        let session = try XCTUnwrap(controller.currentSessionForTesting)

        try write("---\ndescription: New skill\n---\nbody", ".claude/skills/fresh/SKILL.md")
        type(controller, "second")
        await waitFor("second done") { !controller.isRunning }
        XCTAssertTrue(try XCTUnwrap(client.requests.last).tools.map(\.name).contains("skill"))
        XCTAssertFalse(controller.currentSessionForTesting === session, "a new tool list is a new session")
        XCTAssertEqual(try XCTUnwrap(client.requests.last).items.count, 3, "with the earlier exchange carried over")

        type(controller, "third")
        await waitFor("third done") { !controller.isRunning }
        let kept = controller.currentSessionForTesting
        type(controller, "fourth")
        await waitFor("fourth done") { !controller.isRunning }
        XCTAssertEqual(client.requests.count, 4)
        XCTAssertTrue(controller.currentSessionForTesting === kept, "an unchanged catalog keeps the session")
    }

    func testACommandIsNotRunWhileAnotherRunIsGoingAndKeepsTheDraft() async throws {
        try write("Say $ARGUMENTS", ".claude/commands/say.md")
        let (controller, _) = makeController([MockTurn([.textDelta("slow"), .finished(.completed)], delayPerEvent: .milliseconds(400))])
        type(controller, "start")
        await waitFor("running") { controller.isRunning }
        type(controller, "/say hello")
        XCTAssertEqual(controller.draft, "/say hello", "the draft is kept for when the run ends")
        XCTAssertEqual(controller.entries.filter { $0.kind == .user }.count, 1)
        await waitFor("done") { !controller.isRunning }
    }

    func testShellLinesInACommandAreSentAsTextWithANotice() async throws {
        try write("Status is !`git status`", ".claude/commands/status.md")
        let (controller, client) = makeController([.text("ok")])
        type(controller, "/status")
        await waitFor("sent") { !controller.isRunning && !client.requests.isEmpty }
        XCTAssertTrue(controller.entries.contains { $0.kind == .notice && $0.text.contains("Umbra does not run them") })
    }

    // MARK: - Suggestions

    func testTheCommandListFiltersByName() throws {
        try write("x", ".claude/commands/deploy.md")
        let (controller, _) = makeController()
        let all = controller.suggestions(for: .slash(query: "", range: NSRange(location: 0, length: 1)))
        XCTAssertEqual(all.first?.title, "/new")
        XCTAssertTrue(all.contains { $0.title == "/deploy" })

        let rows = controller.suggestions(for: .slash(query: "dep", range: NSRange(location: 0, length: 4)))
        XCTAssertEqual(rows.first?.title, "/deploy")
        XCTAssertTrue(controller.suggestions(for: .slash(query: "zzzq", range: NSRange(location: 0, length: 5))).isEmpty)

        let new = try XCTUnwrap(all.first { $0.title == "/new" })
        XCTAssertEqual(new.payload, .run("new"), "a command with nothing to add runs when accepted")
        XCTAssertEqual(new.insertion, "/new ")
        let resume = try XCTUnwrap(all.first { $0.title == "/resume" })
        XCTAssertNil(resume.payload, "one that takes arguments is inserted")
        XCTAssertTrue(resume.detail?.contains("[search]") == true)
    }

    func testAcceptingARunPayloadRunsTheCommand() async {
        let (controller, _) = makeController([.text("x")])
        type(controller, "hello")
        await waitFor("done") { !controller.isRunning }
        controller.perform(.run("new"))
        XCTAssertEqual(controller.conversations.count, 2)
        controller.perform(.mode(.auto))
        XCTAssertEqual(controller.mode, .auto)
    }
}

@MainActor
final class IDEAgentPromptHistoryFlowTests: XCTestCase {
    private var base: URL!
    private var project: URL!
    private var storeDirectory: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        base = FileManager.default.temporaryDirectory.appendingPathComponent("agent-prompts-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        project = base.appendingPathComponent("project")
        storeDirectory = base.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: base)
    }

    private func makeController(_ turns: [MockTurn] = [.text("ok"), .text("ok"), .text("ok")], store: Bool = true) -> IDEAgentController {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        let client = MockLLMClient(turns: turns)
        let controller = IDEAgentController(
            settings: settings, store: store ? SessionStore(directory: storeDirectory) : nil, clientFactory: { _ in client })
        controller.attach(host: workspace)
        controller.newConversation()
        return controller
    }

    private func say(_ controller: IDEAgentController, _ text: String) async {
        controller.draft = text
        controller.submit()
        for _ in 0..<500 where controller.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testWhatWasSentIsRememberedAndComesBackWithTheNextWindow() async throws {
        let controller = makeController()
        await say(controller, "first question")
        await say(controller, "second question")
        await say(controller, "/help")
        XCTAssertEqual(controller.promptHistory()?.prompts, ["first question", "second question", "/help"], "commands are remembered too")

        let reopened = makeController()
        XCTAssertEqual(reopened.promptHistory()?.prompts, ["first question", "second question", "/help"])
    }

    func testAMessageThatWasNotSentIsNotRemembered() async throws {
        let controller = makeController(store: false)
        controller.draft = "   "
        controller.submit()
        XCTAssertTrue(controller.promptHistory()?.prompts.isEmpty == true)

        controller.draft = "a slow one"
        controller.submit()
        controller.draft = "typed while running"
        controller.submit()  // the first is still running: this one is refused and stays in the field
        XCTAssertEqual(controller.promptHistory()?.prompts, ["a slow one"])
        XCTAssertEqual(controller.draft, "typed while running")
        for _ in 0..<500 where controller.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testUpAndDownRecallThroughTheController() async throws {
        let controller = makeController()
        await say(controller, "one")
        await say(controller, "two")
        controller.draft = "half typed"
        XCTAssertEqual(controller.recallPrompt(-1), "two")
        XCTAssertEqual(controller.recallPrompt(-1), "one")
        XCTAssertNil(controller.recallPrompt(-1))
        XCTAssertEqual(controller.recallPrompt(1), "two")
        XCTAssertEqual(controller.recallPrompt(1), "half typed")
        XCTAssertNil(controller.recallPrompt(1))
    }

    func testSendingEndsTheRecall() async throws {
        let controller = makeController()
        await say(controller, "one")
        XCTAssertEqual(controller.recallPrompt(-1), "one")
        XCTAssertTrue(controller.selected.promptRecall.isRecalling)
        await say(controller, "one")
        XCTAssertFalse(controller.selected.promptRecall.isRecalling)
        controller.selected.promptRecall.reset()
    }

    func testEachChatKeepsItsOwnPlaceButTheyShareTheHistory() async throws {
        let controller = makeController()
        await say(controller, "in the first chat")
        controller.addConversation()
        controller.draft = "second chat draft"
        XCTAssertEqual(controller.recallPrompt(-1), "in the first chat", "the history is the project's")
        XCTAssertTrue(controller.selected.promptRecall.isRecalling)
        controller.select(controller.conversations[0].id)
        XCTAssertFalse(controller.selected.promptRecall.isRecalling, "the other chat's place is not shared")
    }

    func testTheSearchListIsNewestFirstAndFuzzy() async throws {
        let controller = makeController()
        await say(controller, "fix the parser")
        await say(controller, "write the docs")
        await say(controller, "refactor the parser")
        let all = controller.suggestions(for: .history(query: "", range: NSRange(location: 0, length: 0)))
        XCTAssertEqual(all.map(\.insertion), ["refactor the parser", "write the docs", "fix the parser"])
        let narrowed = controller.suggestions(for: .history(query: "parser", range: NSRange(location: 0, length: 6)))
        XCTAssertEqual(Set(narrowed.map(\.insertion)), ["refactor the parser", "fix the parser"])
        XCTAssertTrue(narrowed.allSatisfy { $0.payload == nil }, "accepting replaces the text; nothing is run")
    }

    func testAMultilinePromptShowsItsFirstLineButInsertsAllOfIt() async throws {
        let controller = makeController()
        await say(controller, "line one\nline two")
        let rows = controller.suggestions(for: .history(query: "", range: NSRange(location: 0, length: 0)))
        XCTAssertEqual(rows.first?.title, "line one …")
        XCTAssertEqual(rows.first?.insertion, "line one\nline two")
    }

    func testClearHistoryForgetsThePromptsToo() async throws {
        let controller = makeController()
        await say(controller, "remember me")
        controller.clearHistory()
        XCTAssertTrue(controller.promptHistory()?.prompts.isEmpty == true)
        XCTAssertTrue(makeController().promptHistory()?.prompts.isEmpty == true, "and from disk")
    }
}
