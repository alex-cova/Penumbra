import Foundation
import WebKit
import XCTest

@testable import Umbra

/// The Browser tab's picker and notes, against a real `WebPage` loading fixture HTML.
@MainActor
final class IDEAIBrowserInspectorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    static let fixture = """
    <!doctype html><html><head><title>Dashboard</title></head><body>
    <main><section id="cards" class="cards">
      <button id="save" class="btn primary" data-testid="save-btn">Save</button>
      <div id="box"><input id="user" value="secret-token-abc" placeholder="Name"><textarea id="bio">private text</textarea></div>
      <input id="pw" type="password" value="hunter2">
    </section></main></body></html>
    """
    static let base = URL(string: "http://localhost:8765/dashboard")!

    private func loadedModel(_ html: String = fixture) async -> IDEAIBrowserModel {
        let model = IDEAIBrowserModel()
        await model.load(html: html, baseURL: Self.base)
        await ready(model)
        return model
    }

    /// The scripts run at document start; the overlay says `ready` once the document is parsed.
    private func ready(_ model: IDEAIBrowserModel) async {
        await eventually("the inspector is there") { await model.inspector("return window.__umbra ? 'yes' : 'no'") == "yes" }
    }

    private func eventually(_ message: String, timeout: Double = 4, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let ok = await condition()
        XCTAssertTrue(ok, message)
    }

    private func pageWorld(_ model: IDEAIBrowserModel, _ body: String) async -> String? {
        try? await model.page.callJavaScript(body, contentWorld: .page) as? String
    }

    private func state(_ model: IDEAIBrowserModel) async -> [String: Any] {
        guard let text = await model.inspector("return window.__umbra.state()"),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return [:] }
        return object
    }

    private func dispatch(_ model: IDEAIBrowserModel, on selector: String, _ type: String) async {
        await model.inspector(
            "var e = document.querySelector(sel); e.dispatchEvent(new MouseEvent(type, {bubbles: true, cancelable: true, composed: true})); return 'ok'",
            ["sel": selector, "type": type])
    }

    // MARK: - Isolation

    func testThePageCannotReachTheInspectorOrItsMessageHandler() async {
        let model = await loadedModel()
        defer { model.teardown() }
        let inPage = await pageWorld(model, "return typeof window.__umbra")
        XCTAssertEqual(inPage, "undefined", "the inspector's object lives in its own world")
        let handler = await pageWorld(model, "return String(!!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.umbraInspector))")
        XCTAssertEqual(handler, "false", "the page cannot post to the app")
        let mine = await model.inspector("return typeof window.__umbra")
        XCTAssertEqual(mine, "object")
    }

    // MARK: - Picking

    func testHoverThenClickPicksTheElementAndTheClickNeverReachesThePage() async throws {
        let model = await loadedModel()
        defer { model.teardown() }
        _ = await pageWorld(model, "window.__clicked = false; document.getElementById('save').addEventListener('click', function () { window.__clicked = true; }); return 'ok'")

        model.setPicking(true)
        await eventually("pick mode is on in the page") { await self.state(model)["picking"] as? Bool == true }

        await dispatch(model, on: "#save", "mousemove")
        let hovered = await state(model)["hovered"] as? String
        XCTAssertEqual(hovered, "#save", "hover is tracked")

        await dispatch(model, on: "#save", "click")
        await eventually("the pick reaches the app") { model.pendingPick != nil }
        let pick = try XCTUnwrap(model.pendingPick)
        XCTAssertEqual(pick.element.tag, "button")
        XCTAssertEqual(pick.element.id, "save")
        XCTAssertEqual(pick.element.selector, "#save")
        XCTAssertEqual(pick.element.role, "button")
        XCTAssertEqual(pick.element.label, "Save")
        XCTAssertEqual(pick.element.text, "Save")
        XCTAssertTrue(pick.element.classes.contains("primary"))
        XCTAssertEqual(pick.element.ancestors.first, "section#cards")

        let clicked = await pageWorld(model, "return String(window.__clicked)")
        XCTAssertEqual(clicked, "false", "select mode swallows the click")
    }

    func testWithoutSelectModeAClickReachesThePage() async {
        let model = await loadedModel()
        defer { model.teardown() }
        _ = await pageWorld(model, "window.__clicked = false; document.getElementById('save').addEventListener('click', function () { window.__clicked = true; }); return 'ok'")
        await dispatch(model, on: "#save", "click")
        let clicked = await pageWorld(model, "return String(window.__clicked)")
        XCTAssertEqual(clicked, "true")
        XCTAssertNil(model.pendingPick)
    }

    func testClimbingSelectsTheParentAndTheChildBack() async {
        let model = await loadedModel()
        defer { model.teardown() }
        model.setPicking(true)
        await eventually("pick mode") { await self.state(model)["picking"] as? Bool == true }
        await dispatch(model, on: "#save", "mousemove")
        _ = await model.inspector("return window.__umbra.climb(-1)")
        let parent = await state(model)["hovered"] as? String
        XCTAssertEqual(parent, "#cards")
        _ = await model.inspector("return window.__umbra.climb(1)")
        let child = await state(model)["hovered"] as? String
        XCTAssertNotEqual(child, "#cards")
        XCTAssertTrue(child?.contains("save") == true || child == "#save", "back on the button: \(child ?? "nil")")
    }

    func testPickModeEndsWhenTheUserTurnsItOff() async {
        let model = await loadedModel()
        defer { model.teardown() }
        model.setPicking(true)
        await eventually("on") { await self.state(model)["picking"] as? Bool == true }
        model.setPicking(false)
        await eventually("off") { await self.state(model)["picking"] as? Bool == false }
        XCTAssertFalse(model.isPicking)
    }

    // MARK: - What leaves the page

    func testInputValuesAndPasswordsAreNeverCaptured() async throws {
        let model = await loadedModel()
        defer { model.teardown() }
        func describe(_ selector: String) async throws -> IDEAIElementInfo {
            let described = await model.inspector("return window.__umbra.describe(sel)", ["sel": selector])
            let text = try XCTUnwrap(described)
            return try JSONDecoder().decode(IDEAIElementInfo.self, from: Data(text.utf8))
        }
        let box = try await describe("#box")
        XCTAssertFalse(box.html.contains("secret-token-abc"), "an input's value attribute is removed")
        XCTAssertFalse(box.html.contains("private text"), "a textarea's text is removed")
        XCTAssertGreaterThanOrEqual(box.redactions, 1)

        let password = try await describe("#pw")
        XCTAssertFalse(password.html.contains("hunter2"))
        XCTAssertEqual(password.text, "")
        XCTAssertNil(password.label)
        XCTAssertGreaterThanOrEqual(password.redactions, 1)

        let user = try await describe("#user")
        XCTAssertEqual(user.text, "", "the value of a field is not its text")
        XCTAssertEqual(user.label, "Name", "its placeholder names it")
    }

    func testAnElementInsideAnOpenShadowRootGetsAPathThroughIt() async throws {
        let html = """
        <!doctype html><body><my-card id="card"></my-card><script>
        var host = document.getElementById('card'); var root = host.attachShadow({mode: 'open'});
        root.innerHTML = '<div class="inner"><button class="go">Go</button></div>';
        </script></body>
        """
        let model = await loadedModel(html)
        defer { model.teardown() }
        let computed = await model.inspector(
            "var b = document.getElementById('card').shadowRoot.querySelector('button'); return window.__umbra._selectorFor(b)")
        let selector = try XCTUnwrap(computed)
        XCTAssertTrue(selector.contains(" >>> "), selector)
        let found = await model.inspector("var e = window.__umbra._resolve(sel); return e ? e.localName : 'none'", ["sel": selector])
        XCTAssertEqual(found, "button")
    }

    // MARK: - Notes on the page

    func testANoteIsPinnedAndComesBackAfterTheDocumentReloads() async throws {
        let model = await loadedModel()
        defer { model.teardown() }
        model.setPicking(true)
        await eventually("on") { await self.state(model)["picking"] as? Bool == true }
        await dispatch(model, on: "#save", "mousemove")
        await dispatch(model, on: "#save", "click")
        await eventually("picked") { model.pendingPick != nil }

        model.commitPick(note: "Make this the primary button")
        let note = try XCTUnwrap(model.annotations.items.first)
        XCTAssertEqual(note.note, "Make this the primary button")
        XCTAssertEqual(note.number, 1)
        XCTAssertEqual(note.pageTitle, "Dashboard")
        XCTAssertNil(model.pendingPick)
        await eventually("the pin is on the page") { (await self.state(model)["pins"] as? [String])?.contains(note.id.uuidString) == true }

        await model.load(html: Self.fixture, baseURL: Self.base)
        await eventually("the pin is back after a reload") { (await self.state(model)["pins"] as? [String])?.contains(note.id.uuidString) == true }
    }

    func testANoteWhoseElementIsGoneIsReportedMissingAndOneOnAnotherPageIsNotShown() async throws {
        let model = await loadedModel()
        defer { model.teardown() }
        let element = IDEAIElementInfo(
            selector: "#nope", tag: "p", id: nil, classes: [], role: nil, label: nil, text: "Gone", html: "<p>",
            rect: .init(x: 0, y: 0, w: 0, h: 0), styles: [:], ancestors: [], redactions: 0, component: nil)
        let gone = try XCTUnwrap(model.annotations.add(note: "was here", pageURL: Self.base, pageTitle: "Dashboard", element: element))
        let elsewhere = try XCTUnwrap(model.annotations.add(
            note: "other page", pageURL: URL(string: "http://localhost:8765/settings")!, pageTitle: "Settings", element: element))

        await eventually("the overlay reports the missing element") { model.annotations.missing.contains(gone.id) }
        let pins = (await state(model)["pins"] as? [String]) ?? []
        XCTAssertFalse(pins.contains(elsewhere.id.uuidString), "a note from another route is not pinned here")
    }

    func testTheFrameworkComponentBehindAnElementIsReadFromThePageWorld() async throws {
        let model = await loadedModel()
        defer { model.teardown() }
        _ = await pageWorld(model, "document.getElementById('save').__vueParentComponent = { type: { __name: 'SaveButton', __file: 'src/SaveButton.vue' } }; return 'ok'")
        model.setPicking(true)
        await eventually("on") { await self.state(model)["picking"] as? Bool == true }
        await dispatch(model, on: "#save", "mousemove")
        await dispatch(model, on: "#save", "click")
        await eventually("picked") { model.pendingPick != nil }
        model.commitPick(note: "")
        let id = try XCTUnwrap(model.annotations.items.first?.id)
        await eventually("the component is found") { model.annotations.item(id)?.element.component != nil }
        XCTAssertEqual(model.annotations.item(id)?.element.component, "Vue: SaveButton (src/SaveButton.vue)")
    }

    // MARK: - The window

    func testTheBridgeDoesNotKeepTheModelAliveAfterTeardown() async {
        weak var weakModel: IDEAIBrowserModel?
        do {
            let model = await loadedModel()
            weakModel = model
            model.teardown()
        }
        for _ in 0..<500 where weakModel != nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(weakModel, "WebKit holds message handlers strongly; the bridge must not hold the model")
    }

    func testMessagesFromThePageAreCheckedBeforeTheyAreUsed() {
        XCTAssertNil(IDEAIBrowserMessage.decode(42))
        XCTAssertNil(IDEAIBrowserMessage.decode("not json"))
        XCTAssertNil(IDEAIBrowserMessage.decode(String(repeating: "a", count: IDEAIBrowserMessage.maximumBytes + 1)))
        XCTAssertEqual(IDEAIBrowserMessage.decode(#"{"t":"ready","url":"http://x"}"#)?.t, "ready")

        let model = IDEAIBrowserModel()
        defer { model.teardown() }
        // A pin for a note that does not exist, or a pick with no element, changes nothing.
        model.handle(IDEAIBrowserMessage(t: "pin", element: nil, vr: .init(x: 0, y: 0, w: 1, h: 1), id: UUID().uuidString, ids: nil, url: nil))
        model.handle(IDEAIBrowserMessage(t: "picked", element: nil, vr: nil, id: nil, ids: nil, url: nil))
        model.handle(IDEAIBrowserMessage(t: "unknown", element: nil, vr: nil, id: nil, ids: nil, url: nil))
        XCTAssertNil(model.editingPin)
        XCTAssertNil(model.pendingPick)
    }
}

/// The notes store and what is sent to the page: pure.
@MainActor
final class IDEAIBrowserAnnotationsTests: XCTestCase {
    private func element(_ selector: String = "#a", text: String = "Hello") -> IDEAIElementInfo {
        IDEAIElementInfo(
            selector: selector, tag: "button", id: "a", classes: ["btn"], role: "button", label: "Hello", text: text,
            html: "<button id=\"a\">Hello</button>", rect: .init(x: 1, y: 2, w: 3, h: 4), styles: ["color": "red"],
            ancestors: ["div"], redactions: 0, component: nil)
    }

    private let page = URL(string: "http://localhost:3000/dashboard?tab=1#top")!

    func testNotesAreNumberedInOrderAndRestartAfterClear() {
        let store = IDEAIBrowserAnnotations()
        let first = store.add(note: "one", pageURL: page, pageTitle: "D", element: element())
        let second = store.add(note: "two", pageURL: page, pageTitle: "D", element: element("#b"))
        XCTAssertEqual([first?.number, second?.number], [1, 2])
        store.remove(first!.id)
        XCTAssertEqual(store.add(note: "three", pageURL: page, pageTitle: "D", element: element())?.number, 3, "numbers are not reused while others stay")
        store.clear()
        XCTAssertEqual(store.add(note: "again", pageURL: page, pageTitle: "D", element: element())?.number, 1)
    }

    func testAnEditedNoteThatWasSentIsOpenAgainAndTheAgentCanAddressIt() {
        let store = IDEAIBrowserAnnotations()
        let note = store.add(note: "make it blue", pageURL: page, pageTitle: "D", element: element())!
        store.markSent([note.id])
        XCTAssertEqual(store.item(note.id)?.status, .sent)
        XCTAssertTrue(store.openItems.isEmpty)
        store.update(note.id, note: "make it green")
        XCTAssertEqual(store.item(note.id)?.status, .open, "changed after it was sent: news again")

        XCTAssertEqual(store.resolve([note.id, UUID()], reply: "Done in Button.swift"), 1)
        XCTAssertEqual(store.item(note.id)?.status, .addressed)
        XCTAssertEqual(store.item(note.id)?.reply, "Done in Button.swift")
    }

    func testThePageKeyIgnoresQueryAndFragmentButNotTheRoute() {
        func key(_ text: String) -> String { IDEAIBrowserPageKey.key(for: URL(string: text)!) }
        XCTAssertEqual(key("http://localhost:3000/dashboard?tab=1#top"), "http://localhost:3000/dashboard")
        XCTAssertEqual(key("http://LOCALHOST:3000/dashboard/"), "http://localhost:3000/dashboard")
        XCTAssertEqual(key("http://localhost:3000"), "http://localhost:3000/")
        XCTAssertNotEqual(key("http://localhost:3000/a"), key("http://localhost:3000/b"))
        XCTAssertNotEqual(key("http://localhost:3000/a"), key("http://localhost:3001/a"))
    }

    func testTheOverlayOnlyGetsTheNotesOfItsOwnPage() throws {
        let store = IDEAIBrowserAnnotations()
        store.add(note: "here", pageURL: page, pageTitle: "D", element: element())
        store.add(note: "there", pageURL: URL(string: "http://localhost:3000/settings")!, pageTitle: "S", element: element("#s"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(store.overlayPayload(forPageKey: IDEAIBrowserPageKey.key(for: page)).utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["note"] as? String, "here")
        XCTAssertEqual(rows.first?["selector"] as? String, "#a")
    }

    func testEverythingFromThePageIsCappedAndScrubbed() {
        var long = element(text: String(repeating: "x", count: 5_000))
        long.html = "<div data-key=\"sk-abcdefghijklmnopqrstuvwxyz0123456789\">" + String(repeating: "y", count: 5_000)
        long.classes = (0..<100).map { "c\($0)" }
        long.label = "token AKIAABCDEFGHIJKLMNOP"
        let clean = long.sanitized()
        XCTAssertLessThanOrEqual(clean.text.count, 300)
        XCTAssertLessThanOrEqual(clean.html.count, 2_000)
        XCTAssertFalse(clean.html.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertFalse(clean.label?.contains("AKIAABCDEFGHIJKLMNOP") ?? true)
        XCTAssertEqual(clean.classes.count, 20)
    }

    func testTheStoreHoldsABoundedNumberOfNotes() {
        let store = IDEAIBrowserAnnotations()
        for index in 0..<IDEAIBrowserAnnotations.maximumCount {
            XCTAssertNotNil(store.add(note: "n\(index)", pageURL: page, pageTitle: "D", element: element()))
        }
        XCTAssertNil(store.add(note: "one too many", pageURL: page, pageTitle: "D", element: element()))
        XCTAssertEqual(store.items.count, IDEAIBrowserAnnotations.maximumCount)
    }

    func testAChipSaysWhatTheNoteSaysElseWhatTheElementIs() {
        let store = IDEAIBrowserAnnotations()
        let worded = store.add(note: "  Make it bigger\nand bold ", pageURL: page, pageTitle: "D", element: element())!
        XCTAssertEqual(worded.summary, "Make it bigger")
        let silent = store.add(note: " ", pageURL: page, pageTitle: "D", element: element())!
        XCTAssertEqual(silent.summary, "Hello", "the element's own name when there is no note")
    }
}
