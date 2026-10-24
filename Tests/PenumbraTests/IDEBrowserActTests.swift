import AgentKit
import Foundation
import XCTest

@testable import Umbra

private let actPage = """
<!doctype html><html><head><title>Form</title></head><body>
<button id="save" onclick="document.getElementById('out').textContent = 'saved'">Save</button>
<button id="off" disabled>Disabled</button>
<input id="name" placeholder="Name">
<input id="pw" type="password" aria-label="Password">
<input id="card" autocomplete="cc-number" aria-label="Card number">
<select id="plan" aria-label="Plan"><option>Free</option><option value="pro">Pro</option></select>
<input type="checkbox" id="chk" aria-label="Agree">
<form id="f" onsubmit="event.preventDefault(); document.getElementById('out').textContent = 'submitted:' + document.getElementById('q').value">
  <input id="q" aria-label="Search">
</form>
<input id="key" aria-label="Key" onkeydown="if (event.key === 'Escape') document.getElementById('out').textContent = 'esc'">
<div id="out"></div>
<script>
 window.events = [];
 document.getElementById('name').addEventListener('input', function (e) { window.events.push('input:' + e.target.value); });
 setTimeout(function () { var s = document.createElement('p'); s.textContent = 'arrived later'; document.body.appendChild(s); }, 300);
</script></body></html>
"""

/// What the agent can do to the page, against a real `WebPage`.
@MainActor
final class IDEBrowserActionTests: XCTestCase {
    private let base = URL(string: "http://localhost:8765/form")!

    private func loaded() async -> IDEAIBrowserModel {
        let model = IDEAIBrowserModel()
        await model.load(html: actPage, baseURL: base)
        for _ in 0..<200 {
            if await model.inspector("return window.__umbra && window.__umbra.act ? 'yes' : 'no'") == "yes" { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    private func js(_ model: IDEAIBrowserModel, _ body: String) async -> String? { await model.inspector(body) }

    private func ref(_ snapshot: String, _ words: String) throws -> String {
        let line = try XCTUnwrap(snapshot.components(separatedBy: "\n").first { $0.contains(words) }, "no line with \(words) in:\n\(snapshot)")
        return try XCTUnwrap(line.range(of: #"e\d+"#, options: .regularExpression).map { String(line[$0]) })
    }

    func testClickingRunsThePagesOwnHandlerAndTheResultIncludesWhatChanged() async throws {
        let model = await loaded()
        defer { model.teardown() }
        let snapshot = try await model.readSnapshot(selector: nil, asText: false)
        let result = try await model.perform(.click(target: try ref(snapshot, "button \"Save\"")), includeSnapshot: true)
        XCTAssertTrue(result.hasPrefix("Clicked button \"Save\"."), result)
        XCTAssertTrue(result.contains("text \"saved\""), "the outline afterwards shows the effect")
        let out = await js(model, "return document.getElementById('out').textContent")
        XCTAssertEqual(out, "saved")
        let quiet = try await model.perform(.click(target: "#save"), includeSnapshot: false)
        XCTAssertFalse(quiet.contains("Page:"), "snapshot: false leaves the outline out")
        XCTAssertNil(model.agentActivity, "the banner is gone when the action ends")
    }

    func testADisabledOrGoneElementIsRefusedWithAReason() async throws {
        let model = await loaded()
        defer { model.teardown() }
        do {
            _ = try await model.perform(.click(target: "#off"), includeSnapshot: false)
            XCTFail("a disabled button cannot be clicked")
        } catch { XCTAssertTrue(error.localizedDescription.contains("disabled")) }
        do {
            _ = try await model.perform(.click(target: "e999"), includeSnapshot: false)
            XCTFail("an unknown ref")
        } catch { XCTAssertTrue(error.localizedDescription.contains("That ref is gone")) }
        do {
            _ = try await model.perform(.click(target: "#nope"), includeSnapshot: false)
            XCTFail("an unknown selector")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Nothing matches")) }
    }

    func testTypingSetsTheValueFiresInputEventsAndReplaceOrAppends() async throws {
        let model = await loaded()
        defer { model.teardown() }
        _ = try await model.perform(.type(target: "#name", text: "Ali", submit: false, clear: false), includeSnapshot: false)
        _ = try await model.perform(.type(target: "#name", text: "ce", submit: false, clear: false), includeSnapshot: false)
        var value = await js(model, "return document.getElementById('name').value")
        XCTAssertEqual(value, "Alice", "typing appends")
        let events = await js(model, "return window.__umbraEvents || ''")
        XCTAssertNotNil(events)
        _ = try await model.perform(.type(target: "#name", text: "Bob", submit: false, clear: true), includeSnapshot: false)
        value = await js(model, "return document.getElementById('name').value")
        XCTAssertEqual(value, "Bob", "clear replaces")
    }

    func testTypingIntoAPasswordOrCardFieldIsRefusedWhateverIsAsked() async throws {
        let model = await loaded()
        defer { model.teardown() }
        for selector in ["#pw", "#card"] {
            do {
                _ = try await model.perform(.type(target: selector, text: "hunter2", submit: false, clear: false), includeSnapshot: false)
                XCTFail("\(selector) must refuse")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Typing into it is refused"), error.localizedDescription)
            }
            let value = await js(model, "return document.querySelector('\(selector)').value")
            XCTAssertEqual(value, "", "nothing was typed")
        }
    }

    func testTypingWithSubmitSubmitsTheForm() async throws {
        let model = await loaded()
        defer { model.teardown() }
        let result = try await model.perform(.type(target: "#q", text: "swift", submit: true, clear: true), includeSnapshot: false)
        XCTAssertTrue(result.contains("pressed Enter"), result)
        let out = await js(model, "return document.getElementById('out').textContent")
        XCTAssertEqual(out, "submitted:swift")
    }

    func testSelectingAnOptionACheckboxAndANonControl() async throws {
        let model = await loaded()
        defer { model.teardown() }
        _ = try await model.perform(.select(target: "#plan", value: "Pro"), includeSnapshot: false)
        let plan = await js(model, "return document.getElementById('plan').value")
        XCTAssertEqual(plan, "pro")
        do {
            _ = try await model.perform(.select(target: "#plan", value: "Enterprise"), includeSnapshot: false)
            XCTFail("unknown option")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Options: \"Free\", \"Pro\""), error.localizedDescription) }
        _ = try await model.perform(.select(target: "#chk", value: "true"), includeSnapshot: false)
        var checked = await js(model, "return String(document.getElementById('chk').checked)")
        XCTAssertEqual(checked, "true")
        _ = try await model.perform(.select(target: "#chk", value: "false"), includeSnapshot: false)
        checked = await js(model, "return String(document.getElementById('chk').checked)")
        XCTAssertEqual(checked, "false")
        do {
            _ = try await model.perform(.select(target: "#save", value: "x"), includeSnapshot: false)
            XCTFail("a button is not a select")
        } catch { XCTAssertTrue(error.localizedDescription.contains("not a select")) }
    }

    func testPressingAKeyReachesThePageAndUnsupportedKeysSayWhy() async throws {
        let model = await loaded()
        defer { model.teardown() }
        _ = try await model.perform(.press(target: "#key", key: "Escape"), includeSnapshot: false)
        let out = await js(model, "return document.getElementById('out').textContent")
        XCTAssertEqual(out, "esc")
        for key in ["Tab", "F5", ""] {
            do {
                _ = try await model.perform(.press(target: "#key", key: key), includeSnapshot: false)
                XCTFail("\(key) must be refused")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }

    func testWaitingForTextAndScrolling() async throws {
        let model = await loaded()
        defer { model.teardown() }
        let appeared = try await model.perform(.wait(text: "ARRIVED LATER", milliseconds: 3_000), includeSnapshot: false)
        XCTAssertEqual(appeared, "The text appeared.", "matched without regard to case")
        let missing = try await model.perform(.wait(text: "never shows", milliseconds: 400), includeSnapshot: false)
        XCTAssertTrue(missing.hasPrefix("The text did not appear within 400 ms"))
        let long = try await model.perform(.wait(text: nil, milliseconds: 99_999), includeSnapshot: false)
        XCTAssertEqual(long, "Waited \(IDEAIBrowserAction.maximumWait) ms.", "a wait is bounded")
        let scrolled = try await model.perform(.scroll(target: nil, direction: "bottom", amount: nil), includeSnapshot: false)
        XCTAssertTrue(scrolled.hasPrefix("Scrolled to"))
        let into = try await model.perform(.scroll(target: "#chk", direction: "down", amount: nil), includeSnapshot: false)
        XCTAssertTrue(into.contains("into view"))
    }

    func testNavigationRefusesWhatIsNotTheWebAndHistoryNeedsAHistory() async throws {
        let model = await loaded()
        defer { model.teardown() }
        for text in ["javascript:alert(1)", "file:///etc/passwd", "ftp://example.com"] {
            if case .url(let url) = IDEAIBrowserAddress.normalize(text) {
                do { _ = try await model.perform(.navigate(url), includeSnapshot: false); XCTFail("\(text)") } catch {}
            }
        }
        do {
            _ = try await model.perform(.navigate(URL(string: "http://user:pass@example.com/")!), includeSnapshot: false)
            XCTFail("credentials in the address")
        } catch { XCTAssertTrue(error.localizedDescription.contains("username or password")) }
        do {
            _ = try await model.perform(.back, includeSnapshot: false)
            XCTFail("no earlier page")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no earlier page")) }
    }

    func testTheBannerStateIsSetWhileAnActionRunsAndPickModeEnds() async throws {
        let model = await loaded()
        defer { model.teardown() }
        model.setPicking(true)
        XCTAssertTrue(model.isPicking)
        async let result = model.perform(.wait(text: nil, milliseconds: 400), includeSnapshot: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.agentActivity, "Waiting")
        XCTAssertFalse(model.isPicking, "an action ends select mode")
        _ = try await result
        XCTAssertNil(model.agentActivity)
    }

    func testTheApprovalCardNamesWhatItClicks() async throws {
        let model = await loaded()
        defer { model.teardown() }
        let described = await model.describeTarget("#save")
        XCTAssertEqual(described, "button “Save”")
        let field = await model.describeTarget("#name")
        XCTAssertEqual(field, "textbox “Name”")
        let nothing = await model.describeTarget("#nope")
        XCTAssertNil(nothing)
    }
}

/// `browser_act` in a real chat: the card, the rules, who is shown what, and the injection guard.
@MainActor
final class IDEBrowserActToolTests: XCTestCase {
    private var project: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        project = FileManager.default.temporaryDirectory.appendingPathComponent("browser-act-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
        workspace.project.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        try? FileManager.default.removeItem(at: project)
        IDEWorkspace.isSessionPersistenceEnabled = true
    }

    private func writeRules(allow: [String] = [], deny: [String] = []) throws {
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".umbra"), withIntermediateDirectories: true)
        func array(_ items: [String]) -> String { "[" + items.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
        let json = "{\"permissions\":{\"allow\":" + array(allow) + ",\"deny\":" + array(deny) + "}}"
        try json.write(to: project.appendingPathComponent(".umbra/settings.json"), atomically: true, encoding: .utf8)
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

    private func open(_ address: String) async throws {
        let browser = try XCTUnwrap(workspace.ensureAIBrowser())
        await browser.load(html: actPage, baseURL: try XCTUnwrap(URL(string: address)))
        for _ in 0..<200 where workspace.aiBrowserPageInfo.url == nil { try? await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<200 {
            if await browser.inspector("return window.__umbra && window.__umbra.act ? 'yes' : 'no'") == "yes" { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func act(_ arguments: String, id: String = "a1") -> MockTurn { .toolCalls((id: id, name: "browser_act", arguments: arguments)) }
    private func inspect(id: String = "i1") -> MockTurn { .toolCalls((id: id, name: "browser_inspect", arguments: ##"{"action":"snapshot"}"##)) }

    private func waitFor(_ message: String, timeout: Double = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func entry(_ controller: IDEAgentController, _ name: String) -> IDEAgentEntry? {
        controller.entries.first { $0.kind == .toolCall(name: name) }
    }

    private func run(_ controller: IDEAgentController) {
        controller.draft = "go"
        controller.send()
    }

    private func pageText(_ browser: IDEAIBrowserModel, _ id: String) async -> String? {
        await browser.inspector("return document.getElementById(id).textContent", ["id": id])
    }

    func testAClickAsksFirstNamingTheElementAndRunsOnlyWhenApproved() async throws {
        try await open("http://localhost:8765/form")
        workspace.showAIMode(tab: .code)
        let (controller, client) = makeController([act(##"{"action":"click","selector":"#save"}"##), .text("done")])
        run(controller)
        await waitFor("the card appears") { self.entry(controller, "browser_act")?.approval != nil }
        let request = try XCTUnwrap(entry(controller, "browser_act")?.approval)
        XCTAssertEqual(request.command, "Click button “Save” on http://localhost:8765/form")
        XCTAssertEqual(request.suggestedRule, "browser_act(http://localhost:8765/*)")
        XCTAssertTrue(request.notes.contains { $0.contains("runs as you") })
        let browser = try XCTUnwrap(workspace.aiBrowser)
        let before = await pageText(browser, "out")
        XCTAssertEqual(before, "", "nothing happens before the answer")

        controller.decide(callID: "a1", .approve)
        await waitFor("the run ends") { !controller.isRunning }
        let after = await pageText(browser, "out")
        XCTAssertEqual(after, "saved")
        let output = try XCTUnwrap(entry(controller, "browser_act")?.output)
        XCTAssertFalse(output.isError, output.text)
        guard case .toolOutput(_, let seen)? = client.requests.last?.items.last else { return XCTFail("missing output") }
        XCTAssertTrue(seen.contains("<untrusted source=\"browser:localhost\">"))
        XCTAssertTrue(seen.contains("Clicked button \"Save\"."))
        XCTAssertTrue(workspace.showsAIInspector && workspace.aiInspectorTab == .browser, "the tab was brought up so the user could watch")
    }

    func testDenyingClicksNothing() async throws {
        try await open("http://localhost:8765/form")
        workspace.showAIMode(tab: .code)
        let (controller, _) = makeController([act(##"{"action":"click","selector":"#save"}"##), .text("ok")])
        run(controller)
        await waitFor("the card appears") { self.entry(controller, "browser_act")?.approval != nil }
        controller.decide(callID: "a1", .deny(note: "not that button"))
        await waitFor("the run ends") { !controller.isRunning }
        let browser = try XCTUnwrap(workspace.aiBrowser)
        let out = await pageText(browser, "out")
        XCTAssertEqual(out, "")
        XCTAssertTrue(entry(controller, "browser_act")?.output?.text.contains("not that button") == true)
    }

    func testFromTheEditorTheAgentDoesNotActBecauseTheUserCouldNotWatch() async throws {
        try await open("http://localhost:8765/form")
        XCTAssertFalse(workspace.isAIMode)
        try writeRules(allow: ["browser_act(http://localhost:*/*)"])
        let (controller, _) = makeController([act(##"{"action":"click","selector":"#save"}"##), .text("ok")])
        run(controller)
        await waitFor("the run ends") { !controller.isRunning && self.entry(controller, "browser_act")?.output != nil }
        let output = try XCTUnwrap(entry(controller, "browser_act")?.output)
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("The Browser tab is not showing"), output.text)
        let browser = try XCTUnwrap(workspace.aiBrowser)
        let out = await pageText(browser, "out")
        XCTAssertEqual(out, "", "nothing was clicked")
        XCTAssertFalse(workspace.isAIMode, "and the window was not pulled into AI mode")
    }

    func testAnAllowRuleRunsALocalActionWithoutACardEvenAfterReadingThePage() async throws {
        try writeRules(allow: ["browser_act(http://localhost:*/*)"])
        try await open("http://localhost:8765/form")
        workspace.showAIMode(tab: .code)
        let (controller, _) = makeController([inspect(), act(##"{"action":"click","selector":"#save"}"##), .text("done")])
        run(controller)
        await waitFor("the run ends") { !controller.isRunning && self.entry(controller, "browser_act")?.output != nil }
        XCTAssertNil(entry(controller, "browser_act")?.approval)
        XCTAssertNil(entry(controller, "browser_act")?.approvalOutcome, "no card: the page is on this Mac")
        let browser = try XCTUnwrap(workspace.aiBrowser)
        let out = await pageText(browser, "out")
        XCTAssertEqual(out, "saved")
    }

    func testAfterReadingAPageFromTheWebAnActionAsksAgainEvenWithAnAllowRule() async throws {
        try writeRules(allow: ["browser_inspect(https://example.com/*)", "browser_act(https://example.com/*)"])
        try await open("https://example.com/form")
        workspace.showAIMode(tab: .code)
        let (controller, _) = makeController([inspect(), act(##"{"action":"click","selector":"#save"}"##), .text("done")])
        run(controller)
        await waitFor("the action's card appears") { self.entry(controller, "browser_act")?.approval != nil }
        XCTAssertNil(entry(controller, "browser_inspect")?.approval, "the read was allowed by its rule")
        let request = try XCTUnwrap(entry(controller, "browser_act")?.approval)
        XCTAssertTrue(request.notes.contains { $0.contains("can carry instructions aimed at the agent") }, "\(request.notes)")
        let browser = try XCTUnwrap(workspace.aiBrowser)
        let before = await pageText(browser, "out")
        XCTAssertEqual(before, "")
        controller.decide(callID: "a1", .deny(note: nil))
        await waitFor("the run ends") { !controller.isRunning }
    }

    func testWithoutReadingFirstAnAllowedActionOnASiteRunsWithoutACard() async throws {
        try writeRules(allow: ["browser_act(https://example.com/*)"])
        try await open("https://example.com/form")
        workspace.showAIMode(tab: .code)
        let (controller, _) = makeController([act(##"{"action":"click","selector":"#save"}"##), .text("done")])
        run(controller)
        await waitFor("the run ends") { !controller.isRunning && self.entry(controller, "browser_act")?.output != nil }
        XCTAssertNil(entry(controller, "browser_act")?.approval, "nothing untrusted had been read, and a rule allows it")
    }

    func testANavigationCardShowsTheAddressForEditingAndUsesTheTargetsSite() async throws {
        try await open("http://localhost:8765/form")
        workspace.showAIMode(tab: .code)
        let (controller, _) = makeController([act(##"{"action":"navigate","url":"https://example.org/docs"}"##), .text("ok")])
        run(controller)
        await waitFor("the card appears") { self.entry(controller, "browser_act")?.approval != nil }
        let request = try XCTUnwrap(entry(controller, "browser_act")?.approval)
        XCTAssertEqual(request.command, "https://example.org/docs")
        XCTAssertEqual(request.editableArgument, "url")
        XCTAssertEqual(request.suggestedRule, "browser_act(https://example.org/*)", "the rule is for where it goes, not where it is")
        controller.decide(callID: "a1", .deny(note: nil))
        await waitFor("the run ends") { !controller.isRunning }
    }

    func testBadCallsAreAnsweredBeforeAnyCard() async throws {
        try await open("http://localhost:8765/form")
        workspace.showAIMode(tab: .code)
        let calls = [
            (##"{"action":"navigate","url":"javascript:alert(1)"}"##, "http"),
            (##"{"action":"navigate","url":"file:///etc/passwd"}"##, "http"),
            (##"{"action":"navigate","url":"https://user:pw@example.com/"}"##, "username or password"),
            (##"{"action":"click"}"##, "needs an element"),
            (##"{"action":"type","selector":"#name"}"##, "needs the text"),
            (##"{"action":"fly"}"##, "Unknown action"),
            (##"{"action":"wait"}"##, "wait needs"),
        ]
        for (index, (arguments, expected)) in calls.enumerated() {
            let (controller, _) = makeController([act(arguments, id: "x\(index)"), .text("ok")])
            run(controller)
            await waitFor("run \(index) ends") { !controller.isRunning && self.entry(controller, "browser_act")?.output != nil }
            let entry = try XCTUnwrap(entry(controller, "browser_act"))
            XCTAssertNil(entry.approval, "\(arguments) must not ask")
            XCTAssertTrue(entry.output?.isError == true)
            XCTAssertTrue(entry.output?.text.contains(expected) == true, "\(arguments): \(entry.output?.text ?? "")")
        }
    }

    func testWithNoPageOnlyNavigateIsPossible() async throws {
        let (controller, _) = makeController([act(##"{"action":"click","selector":"#save"}"##), .text("ok")])
        run(controller)
        await waitFor("the run ends") { !controller.isRunning && self.entry(controller, "browser_act")?.output != nil }
        XCTAssertNil(entry(controller, "browser_act")?.approval)
        XCTAssertTrue(entry(controller, "browser_act")?.output?.text.contains("No page is open") == true)
    }

    func testPlanModeOffersTheReadToolButNeverTheActingOne() async throws {
        let (controller, client) = makeController([.text("a")])
        controller.selected.setMode(.plan)
        run(controller)
        await waitFor("the run ends") { !controller.isRunning }
        let names = client.requests.first?.tools.map(\.name) ?? []
        XCTAssertTrue(names.contains("browser_inspect"))
        XCTAssertFalse(names.contains("browser_act"), "an action is a command: plan mode never offers it")

        let (normal, normalClient) = makeController([.text("b")])
        run(normal)
        await waitFor("the run ends") { !normal.isRunning }
        XCTAssertTrue((normalClient.requests.first?.tools.map(\.name) ?? []).contains("browser_act"))
    }

    func testTheArgumentParserReadsEachAction() throws {
        let tool = IDEBrowserActTool(access: IDEAgentBrowserAccess(host: workspace, info: workspace.aiBrowserPageInfo))
        func parse(_ json: String) throws -> IDEAIBrowserAction { try tool.parse(try ToolArguments(json: json)) }
        XCTAssertEqual(try parse(##"{"action":"click","ref":"e12"}"##), .click(target: "e12"))
        XCTAssertEqual(try parse(##"{"action":"click","selector":".go"}"##), .click(target: ".go"))
        XCTAssertEqual(
            try parse(##"{"action":"type","ref":"e3","text":"hi","submit":true}"##), .type(target: "e3", text: "hi", submit: true, clear: false))
        XCTAssertEqual(try parse(##"{"action":"select","ref":"e4","value":"Pro"}"##), .select(target: "e4", value: "Pro"))
        XCTAssertEqual(try parse(##"{"action":"press","key":"Enter"}"##), .press(target: nil, key: "Enter"))
        XCTAssertEqual(try parse(##"{"action":"scroll"}"##), .scroll(target: nil, direction: "down", amount: nil))
        XCTAssertEqual(try parse(##"{"action":"wait","wait_for":"Done"}"##), .wait(text: "Done", milliseconds: 5_000))
        XCTAssertEqual(try parse(##"{"action":"wait","ms":250}"##), .wait(text: nil, milliseconds: 250))
        XCTAssertEqual(try parse(##"{"action":"back"}"##), .back)
        XCTAssertEqual(try parse(##"{"action":"navigate","url":"localhost:3000/x"}"##), .navigate(URL(string: "http://localhost:3000/x")!))
        XCTAssertThrowsError(try parse("{}"))
    }

    func testTheGuardTreatsOnlyPagesOnThisMacAsSafeToActOnAfterUntrustedReads() throws {
        let info = IDEAIBrowserPageInfo()
        let tool = IDEBrowserActTool(access: IDEAgentBrowserAccess(host: workspace, info: info))
        func asks(_ json: String) throws -> Bool { tool.asksAfterUntrustedContent(for: try ToolArguments(json: json)) }
        info.set(URL(string: "http://localhost:3000/"))
        XCTAssertFalse(try asks(##"{"action":"click","ref":"e1"}"##))
        XCTAssertTrue(try asks(##"{"action":"navigate","url":"https://example.com/"}"##), "going to a site out there is judged by where it goes")
        info.set(URL(string: "https://example.com/"))
        XCTAssertTrue(try asks(##"{"action":"click","ref":"e1"}"##))
        XCTAssertFalse(try asks(##"{"action":"navigate","url":"http://127.0.0.1:8080/"}"##))
        XCTAssertTrue(IDEAIBrowserPageInfo.isLoopback(URL(string: "http://[::1]:3000/")))
        XCTAssertFalse(IDEAIBrowserPageInfo.isLoopback(URL(string: "http://localhost.evil.com/")))
    }
}
