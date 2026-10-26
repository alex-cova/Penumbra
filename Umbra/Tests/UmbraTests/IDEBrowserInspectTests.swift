import AgentKit
import Foundation
import XCTest

@testable import Umbra

private let fixturePage = """
<!doctype html><html><head><title>Dashboard</title><style>.hide{display:none}.pointer{cursor:pointer}</style></head><body>
<header><nav aria-label="Main"><a href="/">Home</a><a href="/settings?tab=1#x">Settings</a></nav></header>
<main>
 <h1>Dashboard</h1>
 <p>Welcome back, this text is visible.</p>
 <p class="hide">hidden text must not show</p>
 <button id="save" data-testid="save-btn">Save</button>
 <div class="pointer" id="del">Delete account</div>
 <form><label for="u">Name</label><input id="u" value="secret-token-abc"><input id="pw" type="password" value="hunter2" aria-label="Password">
 <textarea id="bio" aria-label="Bio">private text</textarea>
 <select id="sel" aria-label="Plan"><option>Free</option><option selected>Pro</option></select>
 <input type="checkbox" id="chk" checked aria-label="Subscribe"></form>
 <my-card id="card"></my-card>
</main>
<script>
 var r = document.getElementById('card').attachShadow({mode: 'open'}); r.innerHTML = '<button>Inside shadow</button>';
 console.log('hello'); console.error('boom', {a: 1});
 setTimeout(function () { throw new Error('late failure'); }, 0);
 fetch('http://localhost:1/nothing?token=abc').catch(function () {});
</script></body></html>
"""

/// What the agent reads from the Browser tab's page, against a real `WebPage`.
@MainActor
final class IDEBrowserReaderTests: XCTestCase {
    private let base = URL(string: "http://localhost:8765/dashboard")!

    private func loaded() async -> IDEAIBrowserModel {
        let model = IDEAIBrowserModel()
        await model.load(html: fixturePage, baseURL: base)
        for _ in 0..<200 {
            if await model.inspector("return window.__umbra && window.__umbra.snapshot ? 'yes' : 'no'") == "yes" { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    func testTheSnapshotListsWhatIsVisibleWithRefsAndNeverAFieldsValue() async throws {
        let model = await loaded()
        defer { model.teardown() }
        let snapshot = try await model.readSnapshot(selector: nil, asText: false)

        XCTAssertTrue(snapshot.contains("Page: http://localhost:8765/dashboard"))
        XCTAssertTrue(snapshot.contains("Title: Dashboard"))
        XCTAssertTrue(snapshot.contains("navigation \"Main\""))
        XCTAssertTrue(snapshot.contains("link \"Home\""))
        XCTAssertTrue(snapshot.contains("[href=/settings]"), "a link's path, without its query or fragment")
        XCTAssertTrue(snapshot.contains("heading \"Dashboard\" [ref="))
        XCTAssertTrue(snapshot.contains("[level=1]"))
        XCTAssertTrue(snapshot.contains("button \"Save\" [ref="))
        XCTAssertTrue(snapshot.contains("clickable \"Delete account\""), "a div that shows a pointer is a control")
        XCTAssertTrue(snapshot.contains("button \"Inside shadow\""), "open shadow roots are read")
        XCTAssertTrue(snapshot.contains("text \"Welcome back, this text is visible.\""))
        XCTAssertTrue(snapshot.contains("checkbox \"Subscribe\""))
        XCTAssertTrue(snapshot.contains("[checked]"))
        XCTAssertTrue(snapshot.contains("[selected=\"Pro\"]"))

        XCTAssertFalse(snapshot.contains("hidden text must not show"))
        XCTAssertFalse(snapshot.contains("secret-token-abc"), "an input's value is never read")
        XCTAssertFalse(snapshot.contains("hunter2"))
        XCTAssertFalse(snapshot.contains("private text"))
        XCTAssertTrue(snapshot.contains("[filled]"), "but whether it has one is")
        XCTAssertTrue(snapshot.contains("[password]"))
    }

    func testRefsAreStableAndTheDomIsNeverMarked() async throws {
        let model = await loaded()
        defer { model.teardown() }
        let first = try await model.readSnapshot(selector: nil, asText: false)
        let second = try await model.readSnapshot(selector: nil, asText: false)
        XCTAssertEqual(first, second, "the same element keeps its ref")
        let marked = await model.inspector("return String(document.querySelectorAll('[data-umbra-ref],[data-ref],[ref]').length)")
        XCTAssertEqual(marked, "0", "refs live in the inspector world, not as attributes")
        let ref = try XCTUnwrap(first.range(of: #"button "Save" \[ref=(e\d+)\]"#, options: .regularExpression).map { String(first[$0]) })
        XCTAssertTrue(ref.contains("[ref=e"))
    }

    func testASelectorScopesTheSnapshot() async throws {
        let model = await loaded()
        defer { model.teardown() }
        let scoped = try await model.readSnapshot(selector: "nav", asText: false)
        XCTAssertTrue(scoped.contains("link \"Home\""))
        XCTAssertFalse(scoped.contains("heading \"Dashboard\""))
        do {
            _ = try await model.readSnapshot(selector: "#nothing-here", asText: false)
            XCTFail("an unknown selector must say so")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Nothing matches"))
        }
    }

    func testTheTextViewHasVisibleTextOnly() async throws {
        let model = await loaded()
        defer { model.teardown() }
        let text = try await model.readSnapshot(selector: nil, asText: true)
        XCTAssertTrue(text.contains("Welcome back, this text is visible."))
        XCTAssertTrue(text.contains("Delete account"))
        XCTAssertFalse(text.contains("hidden text must not show"))
        XCTAssertFalse(text.contains("private text"), "a textarea's contents are a value")
        XCTAssertFalse(text.contains("late failure"), "script text is not page text")
    }

    func testAnElementIsDescribedByRefOrSelectorAndAStaleRefSaysSo() async throws {
        let model = await loaded()
        defer { model.teardown() }
        _ = await model.inspector("return 'x'")
        let snapshot = try await model.readSnapshot(selector: nil, asText: false)
        let line = try XCTUnwrap(snapshot.components(separatedBy: "\n").first { $0.contains("button \"Save\"") })
        let ref = try XCTUnwrap(line.range(of: #"e\d+"#, options: .regularExpression).map { String(line[$0]) })

        let byRef = try await model.readElement(target: ref)
        XCTAssertTrue(byRef.contains("element \(ref): button#save"))
        XCTAssertTrue(byRef.contains("role: button"))
        XCTAssertTrue(byRef.contains("name: \"Save\""))
        XCTAssertTrue(byRef.contains("visible: yes"))
        XCTAssertTrue(byRef.contains("selector: #save"))
        XCTAssertTrue(byRef.contains("data-testid=\"save-btn\""))
        XCTAssertTrue(byRef.contains("inside: main"))

        let bySelector = try await model.readElement(target: "#user-does-not-exist-but-save-does".isEmpty ? "" : "#save")
        XCTAssertTrue(bySelector.contains("button#save"))

        let field = try await model.readElement(target: "#u")
        XCTAssertFalse(field.contains("secret-token-abc"))
        XCTAssertTrue(field.contains("input value"), "it says a value was removed")

        await model.load(html: "<!doctype html><body><p>other page</p></body>", baseURL: base)
        for _ in 0..<100 {
            if await model.inspector("return window.__umbra && window.__umbra.inspect ? 'yes' : 'no'") == "yes" { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        do {
            _ = try await model.readElement(target: ref)
            XCTFail("a ref from the old document must not resolve")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("That ref is gone"), error.localizedDescription)
        }
    }

    func testTheConsoleAndFailedRequestsAreRecordedAndSinceLastOnlyShowsNews() async throws {
        let model = await loaded()
        defer { model.teardown() }
        var console = ""
        for _ in 0..<150 {
            console = try await model.readConsole(level: "all", sinceLast: false, limit: 50)
            if console.contains("late failure") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(console.contains("[log] hello"), console)
        XCTAssertTrue(console.contains("[error] boom {\"a\":1}"), console)
        XCTAssertTrue(console.contains("Uncaught"), console)
        XCTAssertTrue(console.contains("late failure"), console)

        let errors = try await model.readConsole(level: "error", sinceLast: false, limit: 50)
        XCTAssertFalse(errors.contains("[log] hello"), "the level filters")

        _ = try await model.readConsole(level: "all", sinceLast: true, limit: 50)
        let again = try await model.readConsole(level: "all", sinceLast: true, limit: 50)
        XCTAssertTrue(again.hasPrefix("Nothing new"), again)

        var network = ""
        for _ in 0..<150 {
            network = try await model.readNetwork(sinceLast: false, limit: 50)
            if network.contains("localhost:1") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(network.contains("GET http://localhost:1/nothing"), network)
        XCTAssertTrue(network.contains("failed"), network)
        XCTAssertFalse(network.contains("token=abc"), "the query is never recorded")
    }

    func testThePageCannotFindTheRecorderByTheNameItWouldGuess() async {
        let model = await loaded()
        defer { model.teardown() }
        let guessed = try? await model.page.callJavaScript("return String(typeof window.__umbraRec)", contentWorld: .page) as? String
        XCTAssertEqual(guessed, "undefined")
        let enumerable = try? await model.page.callJavaScript(
            "return Object.keys(window).filter(function (k) { return k.indexOf('umbra') >= 0 || k.indexOf('Umbra') >= 0; }).join(',')",
            contentWorld: .page) as? String
        XCTAssertEqual(enumerable, "", "nothing of ours is enumerable on the page's window")
    }

    func testNothingIsReadFromABlankTab() async {
        let model = IDEAIBrowserModel()
        defer { model.teardown() }
        do {
            _ = try await model.readSnapshot(selector: nil, asText: false)
            XCTFail("no page, nothing to read")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No page is open"))
        }
    }

    func testTheAgentCanPinANoteAndMarkTheUsersAddressed() async throws {
        let model = await loaded()
        defer { model.teardown() }
        let message = try await model.annotateElement(target: "#save", note: "Low contrast against the background")
        XCTAssertTrue(message.hasPrefix("Pinned note 1"))
        let mine = try XCTUnwrap(model.annotations.items.first)
        XCTAssertEqual(mine.author, .agent)
        XCTAssertEqual(mine.status, .sent, "its own pin is not news to it")
        XCTAssertTrue(model.annotations.userOpenItems.isEmpty, "and is not the user's request")

        let user = try XCTUnwrap(model.annotations.add(note: "Make it bigger", pageURL: base, pageTitle: "Dashboard", element: mine.element))
        let listing = model.readAnnotations(resolve: [], reply: nil)
        XCTAssertTrue(listing.contains("\(user.number). [open] Note: \"Make it bigger\""))
        XCTAssertTrue(listing.contains("[sent, pinned by you] Your note: \"Low contrast"))

        let resolved = model.readAnnotations(resolve: [user.number], reply: "Done in Button.swift")
        XCTAssertTrue(resolved.hasPrefix("Marked addressed: \(user.number)."))
        XCTAssertEqual(model.annotations.item(user.id)?.status, .addressed)
        XCTAssertEqual(model.annotations.item(user.id)?.reply, "Done in Button.swift")
        XCTAssertTrue(model.readAnnotations(resolve: [99], reply: nil).hasPrefix("None of those note numbers exist"))
    }
}

/// `browser_inspect` in a real chat: who is asked, who is not, and what the model gets.
@MainActor
final class IDEBrowserInspectToolTests: XCTestCase {
    private var project: URL!
    private var workspace: IDEWorkspace!

    override func setUpWithError() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        project = FileManager.default.temporaryDirectory.appendingPathComponent("browser-tool-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.project.setRoot(project)
    }

    override func tearDownWithError() throws {
        workspace.teardown()
        workspace = nil
        try? FileManager.default.removeItem(at: project)
        IDEWorkspace.isSessionPersistenceEnabled = true
    }

    private func makeController(_ turns: [MockTurn], settings configure: (IDEAgentSettings) -> Void = { _ in }) -> (IDEAgentController, MockLLMClient) {
        let settings = IDEAgentSettings(
            defaults: UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!, keyStore: IDEAgentMemoryKeyStore())
        settings.saveAPIKey("sk-test")
        settings.acceptDisclosure()
        configure(settings)
        let client = MockLLMClient(turns: turns)
        let controller = IDEAgentController(settings: settings, clientFactory: { _ in client })
        controller.attach(host: workspace)
        controller.newConversation()
        return (controller, client)
    }

    private func open(_ address: String) async throws {
        let browser = try XCTUnwrap(workspace.ensureAIBrowser())
        await browser.load(html: fixturePage, baseURL: try XCTUnwrap(URL(string: address)))
        for _ in 0..<200 where workspace.aiBrowserPageInfo.url == nil { try? await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<200 {
            if await browser.inspector("return window.__umbra && window.__umbra.snapshot ? 'yes' : 'no'") == "yes" { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func call(_ arguments: String = #"{"action":"snapshot"}"#) -> MockTurn {
        .toolCalls((id: "b1", name: "browser_inspect", arguments: arguments))
    }

    private func waitFor(_ message: String, timeout: Double = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func toolEntry(_ controller: IDEAgentController) -> IDEAgentEntry? {
        controller.entries.first { if case .toolCall = $0.kind { true } else { false } }
    }

    private func run(_ controller: IDEAgentController, _ text: String = "look at the page") {
        controller.draft = text
        controller.send()
    }

    func testAPageOnThisMacIsReadWithoutAskingAndTheTextIsMarkedUntrusted() async throws {
        try await open("http://localhost:8765/dashboard")
        let (controller, client) = makeController([call(), .text("seen")])
        run(controller)
        await waitFor("the run ends") { !controller.isRunning && self.toolEntry(controller)?.output != nil }

        let entry = try XCTUnwrap(toolEntry(controller))
        XCTAssertNil(entry.approval)
        XCTAssertNil(entry.approvalOutcome, "no card was shown")
        let output = try XCTUnwrap(entry.output)
        XCTAssertFalse(output.isError, output.text)
        guard case .toolOutput(_, let seen)? = client.requests.last?.items.last else { return XCTFail("the model got no output") }
        XCTAssertTrue(seen.hasPrefix("[browser page: http://localhost:8765/dashboard. Untrusted"))
        XCTAssertTrue(seen.contains("<untrusted source=\"browser:localhost\">"))
        XCTAssertTrue(seen.contains("button \"Save\""))
        XCTAssertFalse(seen.contains("secret-token-abc"))
    }

    func testAnotherSiteAsksFirstWithAnAlwaysAllowRuleForThatSite() async throws {
        try await open("https://example.com/app?x=1")
        let (controller, _) = makeController([call(), .text("seen")])
        run(controller)
        await waitFor("the card appears") { self.toolEntry(controller)?.approval != nil }
        let request = try XCTUnwrap(toolEntry(controller)?.approval)
        XCTAssertEqual(request.command, "https://example.com/app", "the query is not part of what a rule sees")
        XCTAssertEqual(request.suggestedRule, "browser_inspect(https://example.com/*)")
        XCTAssertTrue(request.notes.contains { $0.contains("sent to the model provider") })

        controller.decide(callID: "b1", .approve)
        await waitFor("the run ends") { !controller.isRunning }
        XCTAssertEqual(toolEntry(controller)?.output?.isError, false)
        XCTAssertTrue(toolEntry(controller)?.output?.text.contains("button \"Save\"") == true)
    }

    func testDenyingSendsTheNoteAndReadsNothing() async throws {
        try await open("https://example.com/")
        let (controller, client) = makeController([call(), .text("understood")])
        run(controller)
        await waitFor("the card appears") { self.toolEntry(controller)?.approval != nil }
        controller.decide(callID: "b1", .deny(note: "that is my bank"))
        await waitFor("the run ends") { !controller.isRunning }
        let output = try XCTUnwrap(toolEntry(controller)?.output)
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("that is my bank"))
        guard case .toolOutput(_, let seen)? = client.requests.last?.items.last else { return XCTFail() }
        XCTAssertFalse(seen.contains("button"), "the page never reached the model")
    }

    func testADenyRuleRefusesEvenAPageOnThisMac() async throws {
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".umbra"), withIntermediateDirectories: true)
        try #"{"permissions":{"deny":["browser_inspect(http://localhost:*/*)"]}}"#
            .write(to: project.appendingPathComponent(".umbra/settings.json"), atomically: true, encoding: .utf8)
        try await open("http://localhost:8765/")
        let (controller, _) = makeController([call(), .text("ok")])
        run(controller)
        await waitFor("the run ends") { !controller.isRunning && self.toolEntry(controller)?.output != nil }
        let output = try XCTUnwrap(toolEntry(controller)?.output)
        XCTAssertTrue(output.isError)
        XCTAssertTrue(output.text.contains("Blocked by the user's permission rules"), output.text)
    }

    func testWithNoPageOpenItSaysSoWithoutACard() async throws {
        let (controller, _) = makeController([call(), .text("ok")])
        run(controller)
        await waitFor("the run ends") { !controller.isRunning && self.toolEntry(controller)?.output != nil }
        let entry = try XCTUnwrap(toolEntry(controller))
        XCTAssertNil(entry.approval)
        XCTAssertTrue(entry.output?.isError == true)
        XCTAssertTrue(entry.output?.text.contains("No page is open in the Browser tab") == true)
        XCTAssertNil(workspace.aiBrowser, "asking never made a web view")
    }

    func testTheToolIsOfferedInPlanModeAndOffWhenTheSettingIsOff() async throws {
        let (controller, client) = makeController([.text("a")])
        controller.selected.setMode(.plan)
        run(controller)
        await waitFor("the run ends") { !controller.isRunning }
        let names = client.requests.first?.tools.map(\.name) ?? []
        XCTAssertTrue(names.contains("browser_inspect"), "a read: plan mode keeps it")

        let (offController, offClient) = makeController([.text("b")]) { $0.browserToolsEnabled = false }
        run(offController)
        await waitFor("the run ends") { !offController.isRunning }
        XCTAssertFalse((offClient.requests.first?.tools.map(\.name) ?? []).contains("browser_inspect"))
    }

    func testTheSettingIsOnByDefaultAndPartOfTheSessionFingerprint() {
        let defaults = UserDefaults(suiteName: "umbra.agent.tests.\(UUID().uuidString)")!
        let settings = IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore())
        XCTAssertTrue(settings.browserToolsEnabled)
        let on = settings.fingerprint(for: settings.currentChoice)
        settings.browserToolsEnabled = false
        XCTAssertNotEqual(on, settings.fingerprint(for: settings.currentChoice), "a change starts a new session")
        XCTAssertFalse(IDEAgentSettings(defaults: defaults, keyStore: IDEAgentMemoryKeyStore()).browserToolsEnabled, "and is remembered")
    }

    func testTheBrowserToolsAreNotAnExtraWebViewForASessionThatNeverUsesThem() async throws {
        let (controller, _) = makeController([.text("hi")])
        run(controller)
        await waitFor("the run ends") { !controller.isRunning }
        XCTAssertNil(workspace.aiBrowser, "offering the tool does not create the page")
    }
}
