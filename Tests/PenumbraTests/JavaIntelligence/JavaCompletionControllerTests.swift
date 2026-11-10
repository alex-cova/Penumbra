import XCTest
import AppKit
import TestTreeSitterLanguages
import EditorIntelligence
@testable import Penumbra
@testable import JavaIntelligence

/// The completion popup of a Java file, end to end through the real pieces: a `TextView`, the
/// `EditorIntelligenceController`, the `CompletionEngine` with the providers Umbra registers, and the
/// real `JavaCompletionProvider` over the JDK index of the corpus. Nothing here waits a fixed time: each
/// step polls the state it needs (`waitForCondition`), and the one test that must hold the provider still
/// does so with a latch the test opens.
@MainActor
final class JavaCompletionControllerTests: XCTestCase {
    nonisolated(unsafe) private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private struct Session {
        let textView: TextView
        let controller: EditorIntelligenceController
        let provider: JavaCompletionProvider
        var workbench: EditorWorkbench?
        var adapter: PenumbraWorkbenchEditorAdapter?
        var documents: [WorkbenchDocument] = []
    }

    /// A Java file whose caret sits where `marker` ends.
    private func openSession(
        _ text: String, caretAfter marker: String, otherDocumentText: String? = nil,
        configure: ((JavaCompletionProvider) async -> Void)? = nil
    ) async throws -> Session {
        let corpus = try await JavaCompletionCorpusTests.sharedIndex()
        await corpus.index.setOverlay([:])
        let provider = JavaCompletionProvider(index: corpus.index)
        await configure?(provider)
        let url = URL(fileURLWithPath: "/virtual/Controller\(UUID().uuidString.prefix(6)).java")

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: window.contentView!.bounds)
        textView.theme = DefaultTheme()
        textView.languageIdentifier = "java"
        textView.documentURL = url
        textView.text = text
        window.contentView = textView
        self.window = window
        let caret = (text as NSString).range(of: marker).upperBound
        textView.selectedRange = NSRange(location: caret, length: 0)

        let symbols = SymbolIndex()
        let engine = CompletionEngine(providers: [
            SymbolCompletionProvider(index: symbols), WordCompletionProvider(index: symbols), SnippetCompletionProvider(), provider
        ])
        // With a second document the session is a workbench like Umbra's pane host: two tabs, one text view, one
        // controller, and the adapter's active document is what says which file the editor shows.
        var workbench: EditorWorkbench?
        var workbenchAdapter: PenumbraWorkbenchEditorAdapter?
        var documents: [WorkbenchDocument] = []
        if let otherDocumentText {
            let bench = EditorWorkbench()
            let first = WorkbenchDocument(displayName: "A.java", text: text)
            first.url = url
            first.languageIdentifier = "java"
            let second = WorkbenchDocument(displayName: "B.java", text: otherDocumentText)
            second.url = URL(fileURLWithPath: "/virtual/B\(UUID().uuidString.prefix(6)).java")
            second.languageIdentifier = "java"
            bench.openDocument(first)
            bench.openDocument(second)
            bench.activePane.selectDocument(first.id)
            workbench = bench
            workbenchAdapter = PenumbraWorkbenchEditorAdapter(workbench: bench, textView: textView)
            workbenchAdapter?.refreshCachedDocuments(emitEvents: false)
            documents = [first, second]
        }
        let controller = EditorIntelligenceController(
            textView: textView, adapter: workbenchAdapter, completionEngine: engine, hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [])
        )
        await waitForCondition("the adapter's first snapshot") { controller.adapter.currentDocument != nil }
        return Session(textView: textView, controller: controller, provider: provider, workbench: workbench, adapter: workbenchAdapter, documents: documents)
    }

    private let receiverSource = """
    package app;
    class Demo {
        void run(java.util.List<String> names, String text) {
            text
        }
    }
    """

    /// The controller subscribes to the adapter's events from a task it starts itself, and events sent before that
    /// are not delivered to it. A test that depends on an event waits until one has been handled.
    private func waitUntilTheControllerHandlesAdapterEvents(_ session: Session) async {
        let wasEnabled = CompletionLatencyTrace.isEnabled
        CompletionLatencyTrace.setEnabled(true)
        defer { CompletionLatencyTrace.setEnabled(wasEnabled) }
        CompletionLatencyTrace.reset()
        await waitForCondition("the controller to handle an adapter event") {
            session.adapter?.refreshCachedDocuments()
            try? await Task.sleep(nanoseconds: 5_000_000)
            return CompletionLatencyTrace.events().contains { $0.name == "editorEvent" }
        }
    }

    private func labels(_ session: Session) -> [String] {
        session.controller.visibleCompletionItems.map(\.label)
    }

    // MARK: - What accepting an item writes, through the real controller

    private struct InsertionScenario {
        var name: String
        /// Java statements placed in `run(List<String> names, String text)`; the caret sits after `caretAfter`.
        var body: String
        var caretAfter: String
        var pick: String
        /// The statements after acceptance; `|` marks where the caret must be.
        var expected: String
        var imports = "import java.util.*;\n"
        var requiredText: [String] = []
        /// Classes whose static members are offered with an import (opt-in: `JavaImportPolicy.staticMemberClasses`).
        var staticOwners: [String] = []
    }

    private func program(_ scenario: InsertionScenario, body: String) -> String {
        "package app;\n\(scenario.imports)class Demo {\n    void run(List<String> names, String text) {\n        \(body)\n    }\n}\n"
    }

    /// Opens the file with the caret mid-identifier (text after it stays, as when editing existing code), asks for
    /// completion, selects `pick`, accepts it with Enter semantics, and returns the document, the caret and the item.
    private func accept(_ scenario: InsertionScenario) async throws -> (before: String, after: String, caret: Int, item: CompletionItem) {
        let source = program(scenario, body: scenario.body)
        let owners = scenario.staticOwners
        let session = try await openSession(source, caretAfter: scenario.caretAfter) { provider in
            if !owners.isEmpty { await provider.setImportPolicy(JavaImportPolicy(staticMemberClasses: owners)) }
        }
        session.controller.triggerCompletion()
        await waitForCondition("\(scenario.name): `\(scenario.pick)` offered; popup has \(self.labels(session).count) rows, first \(self.labels(session).prefix(12)), showing=\(session.controller.isShowingCompletion), document now: \(session.textView.text.replacingOccurrences(of: "\n", with: " ⏎ "))") { self.labels(session).contains(scenario.pick) }
        var guardCount = 0
        while session.controller.selectedCompletionItem?.label != scenario.pick, guardCount < 3000 {
            session.controller.moveCompletionSelection(by: 1)
            guardCount += 1
        }
        let item = try XCTUnwrap(session.controller.selectedCompletionItem, scenario.name)
        XCTAssertEqual(item.label, scenario.pick, scenario.name)
        session.controller.acceptSelectedCompletion(replacingIdentifier: false)
        return (source, session.textView.text, session.textView.selectedRange.location, item)
    }

    func testAcceptingAnItemWritesWhatTheHarnessPredictsAndPlacesTheCaret() async throws {
        let scenarios: [InsertionScenario] = [
            .init(name: "constructor, existing parentheses", body: "Object o = new Thread(\"x\");", caretAfter: "new Thread", pick: "Thread",
                  expected: "Object o = new Thread(|\"x\");"),
            .init(name: "constructor, existing type arguments", body: "List<String> l = new ArrayList<String>();", caretAfter: "new ArrayList", pick: "ArrayList",
                  expected: "List<String> l = new ArrayList|<String>();"),
            .init(name: "generic constructor, existing parentheses", body: "List<String> l = new ArrayList(16);", caretAfter: "new ArrayList", pick: "ArrayList",
                  expected: "List<String> l = new ArrayList<>(|16);"),
            .init(name: "anonymous class, existing parentheses and body", body: "Runnable r = new Runnable() { public void run() {} };", caretAfter: "new Runnable", pick: "Runnable",
                  expected: "Runnable r = new Runnable(|) { public void run() {} };"),
            .init(name: "cast, closing parenthesis exists", body: "Object o = text; String s = (Stri) o;", caretAfter: "(Stri", pick: "String",
                  expected: "Object o = text; String s = (String|) o;"),
            .init(name: "method, existing parentheses", body: "int n = text.subs(1);", caretAfter: "text.subs", pick: "substring",
                  expected: "int n = text.substring(|1);"),
            .init(name: "method with parameters, none written", body: "int n = text.indexO;", caretAfter: "text.indexO", pick: "indexOf",
                  expected: "int n = text.indexOf(|);"),
            .init(name: "method without parameters, none written", body: "String u = text.to;", caretAfter: "text.to", pick: "toString",
                  expected: "String u = text.toString()|;"),
            .init(name: "method reference", body: "names.forEach(System.out::prin);", caretAfter: "System.out::prin", pick: "println",
                  expected: "names.forEach(System.out::println|);"),
            .init(name: "overloaded static method, existing arguments", body: "int m = Math.ma(1, 2);", caretAfter: "Math.ma", pick: "max",
                  expected: "int m = Math.max(|1, 2);"),
            .init(name: "nested class", body: "java.util.Map.Entr<String, String> f = null;", caretAfter: "Map.Entr", pick: "Entry",
                  expected: "java.util.Map.Entry|<String, String> f = null;"),
            .init(name: "non-ASCII text before the caret", body: "String e = \"😀é ☃\"; String u = e.to();", caretAfter: "e.to", pick: "toString",
                  expected: "String e = \"😀é ☃\"; String u = e.toString(|);"),
            .init(name: "incomplete statement", body: "text.subs", caretAfter: "text.subs", pick: "substring",
                  expected: "text.substring(|)"),
            .init(name: "unclosed call", body: "System.out.println(text.subs", caretAfter: "text.subs", pick: "substring",
                  expected: "System.out.println(text.substring(|)"),
            // A lambda block opened and never closed, inside a call that is still open: the parameter is still a `String`.
            .init(name: "unclosed lambda block", body: "names.forEach(n -> { n.subs", caretAfter: "n.subs", pick: "substring",
                  expected: "names.forEach(n -> { n.substring(|)"),
            .init(name: "unclosed nested lambda blocks", body: "names.forEach(n -> { names.forEach(m -> { m.subs", caretAfter: "m.subs", pick: "substring",
                  expected: "names.forEach(n -> { names.forEach(m -> { m.substring(|)"),
            .init(name: "static import added for a static member", body: "Object o = requireNon(text);", caretAfter: "requireNon", pick: "requireNonNull",
                  expected: "Object o = requireNonNull(|text);", imports: "", requiredText: ["import static java.util.Objects.requireNonNull;"], staticOwners: ["java.util.Objects"]),
            .init(name: "annotation attribute, equals already written", body: "@Deprecated( = \"1\") Object o = text;", caretAfter: "@Deprecated(", pick: "since",
                  expected: "@Deprecated(since| = \"1\") Object o = text;"),
            .init(name: "annotation attribute, nothing written yet", body: "@Deprecated() Object o = text;", caretAfter: "@Deprecated(", pick: "since",
                  expected: "@Deprecated(since = |) Object o = text;"),
            .init(name: "import added for a constructor", body: "Object l = new ArrayLis(16);", caretAfter: "new ArrayLis", pick: "ArrayList",
                  expected: "Object l = new ArrayList<>(|16);", imports: "", requiredText: ["import java.util.ArrayList;"]),
        ]
        let only = ProcessInfo.processInfo.environment["JAVA_INSERTION_ONLY"]
        for scenario in scenarios where only == nil || scenario.name.contains(only!) {
            let result = try await accept(scenario)
            let caretMarker = (scenario.expected as NSString).range(of: "|").location
            let expectedBody = scenario.expected.replacingOccurrences(of: "|", with: "")
            let expectedText = program(scenario, body: expectedBody)
            if scenario.requiredText.isEmpty {
                XCTAssertEqual(result.after, expectedText, "\(scenario.name): document")
                let header = ("package app;\n\(scenario.imports)class Demo {\n    void run(List<String> names, String text) {\n        " as NSString).length
                XCTAssertEqual(result.caret, header + caretMarker, "\(scenario.name): caret")
            } else {
                for needle in scenario.requiredText {
                    XCTAssertTrue(result.after.contains(needle), "\(scenario.name): missing `\(needle)` in\n\(result.after)")
                }
                XCTAssertTrue(result.after.contains(expectedBody), "\(scenario.name): body in\n\(result.after)")
            }
            // The harness's prediction of the same acceptance must be what the editor wrote.
            if !result.item.isSnippet {
                XCTAssertEqual(
                    JavaCompletionQualityHarness.apply(result.item, to: result.before), result.after,
                    "\(scenario.name): the quality harness predicts a different document than the editor wrote"
                )
            }
            // And the result is Java the parser accepts.
            XCTAssertEqual(JavaSyntaxParser().parse(result.after)?.rootNode.hasError, ["incomplete statement", "unclosed call", "unclosed lambda block", "unclosed nested lambda blocks", "annotation attribute, nothing written yet"].contains(scenario.name), "\(scenario.name): syntax of the result (only the scenarios left unfinished on purpose may have errors)")
        }
    }

    func testDotAfterAReceiverOpensThePopupWithItsMembers() async throws {
        let session = try await openSession(receiverSource, caretAfter: "        text")
        session.textView.insertText(".")
        await waitForCondition("String members in the popup") { self.labels(session).contains("substring") }
        XCTAssertTrue(session.controller.isShowingCompletion)
        XCTAssertTrue(labels(session).contains("length"))
        XCTAssertFalse(labels(session).contains("names"), "the locals of the method are not members of a String")
    }

    /// Typing after the dot narrows the list synchronously from what is already there: a row that
    /// does not match the prefix is never on screen, whatever the engine has answered so far.
    func testPrefixNarrowsTheListWithoutWaitingForTheEngine() async throws {
        let session = try await openSession(receiverSource, caretAfter: "        text")
        session.textView.insertText(".")
        await waitForCondition("String members in the popup") { self.labels(session).contains("substring") }

        session.textView.insertText("s")
        session.textView.insertText("u")
        session.textView.insertText("b")
        XCTAssertFalse(labels(session).contains("length"), "stale rows for the shorter prefix are still showing")
        XCTAssertFalse(labels(session).contains("trim"))
        await waitForCondition("substring after the refresh") { self.labels(session).contains("substring") }
        XCTAssertTrue(labels(session).allSatisfy { $0.lowercased().contains("s") }, "\(labels(session))")
    }

    /// A burst typed with no pause in between: the popup that ends up on screen is the last prefix's.
    func testBurstOfKeystrokesEndsOnTheLastPrefix() async throws {
        let session = try await openSession(receiverSource, caretAfter: "        text")
        for character in ".sta" { session.textView.insertText(String(character)) }
        await waitForCondition("startsWith in the popup") { self.labels(session).contains("startsWith") }
        XCTAssertFalse(labels(session).contains("length"))
        XCTAssertFalse(labels(session).contains("substring"), "'sta' does not match substring")
    }

    func testBackspacingTheDotClosesThePopup() async throws {
        let session = try await openSession(receiverSource, caretAfter: "        text")
        session.textView.insertText(".")
        await waitForCondition("popup") { session.controller.isShowingCompletion }
        session.textView.deleteBackward()
        XCTAssertFalse(session.controller.isShowingCompletion)
        XCTAssertEqual(session.textView.text, receiverSource)
    }

    func testAcceptingAMemberInsertsItAtTheDot() async throws {
        let session = try await openSession(receiverSource, caretAfter: "        text")
        for character in ".isEmp" { session.textView.insertText(String(character)) }
        await waitForCondition("isEmpty in the popup") { self.labels(session).contains("isEmpty") }
        session.controller.acceptSelectedCompletion(replacingIdentifier: true)
        XCTAssertTrue(session.textView.text.contains("text.isEmpty()"), session.textView.text)
        XCTAssertFalse(session.controller.isShowingCompletion)
    }

    /// Ctrl+Space at a statement: the locals are offered, and an explicit request is not an automatic one.
    func testExplicitRequestAtAStatementOffersTheLocals() async throws {
        let source = receiverSource.replacingOccurrences(of: "        text\n", with: "        tex\n")
        let session = try await openSession(source, caretAfter: "        tex")
        session.controller.triggerCompletion()
        await waitForCondition("the local `text`") { self.labels(session).contains("text") }
    }

    /// The slow phase of a request is still pending when the popup is dismissed: it is skipped, and
    /// nothing it was going to add reopens the popup.
    func testDismissedPopupIsNotReopenedByALateSlowPhase() async throws {
        let source = receiverSource.replacingOccurrences(of: "        text\n", with: "        te\n")
        let session = try await openSession(source, caretAfter: "        te")
        let latch = TestLatch()
        await session.provider.setSlowPhaseHook { await latch.pass() }

        session.controller.triggerCompletion()
        await waitForCondition("the slow phase to be reached") { await latch.hasWaiter }
        session.controller.dismissCompletion()
        await waitForCondition("the cancellation to reach the provider") { session.provider.terminationCount.withLock { $0 } >= 1 }
        await latch.open()
        await waitForCondition("the request to finish") {
            let finished = await session.provider.slowPhaseRunCount + session.provider.slowPhaseSkipCount
            return finished >= 1
        }
        let ran = await session.provider.slowPhaseRunCount
        XCTAssertEqual(ran, 0, "the slow phase of a dismissed request ran")
        XCTAssertFalse(session.controller.isShowingCompletion)
    }

    // MARK: - Switching documents

    private let otherJavaSource = """
    package app;
    class Other {
        void go(String word) {
            word
        }
    }
    """

    /// What Umbra's pane host does on a tab switch (`applyState`): select the other tab, give the same `TextView` that
    /// document's state, language and URL, then tell the adapter (`refreshCachedDocuments`).
    private func switchDocument(_ session: Session, to text: String, caretAfter marker: String? = nil, language: String? = "java", tab: Int? = nil) {
        if let tab, let bench = session.workbench {
            bench.activePane.selectDocument(session.documents[tab].id)
            session.documents[tab].url.map { session.textView.documentURL = $0 }
        } else {
            session.textView.documentURL = URL(fileURLWithPath: "/virtual/Switched\(UUID().uuidString.prefix(6)).\(language == "java" ? "java" : "txt")")
        }
        session.textView.setState(TextViewState(text: text, theme: DefaultTheme()))
        session.textView.languageIdentifier = language
        let caret = marker.map { (text as NSString).range(of: $0).upperBound } ?? 0
        session.textView.selectedRange = NSRange(location: caret, length: 0)
        session.adapter?.refreshCachedDocuments()
    }

    /// The new file's caret lands in an identifier that starts where the old popup's did: nothing else tells the
    /// controller the document changed, and the old rows must not stay over it.
    func testSwitchToAFileWithTheCaretAtTheSameIdentifierOffsetStillClosesThePopup() async throws {
        let first = receiverSource.replacingOccurrences(of: "        text\n", with: "        te\n")
        // The second file: the same text up to the caret, the identifier carries on after it.
        let second = first.replacingOccurrences(of: "        te\n", with: "        teXYZ\n")
        let session = try await openSession(first, caretAfter: "        te", otherDocumentText: second)
        await waitUntilTheControllerHandlesAdapterEvents(session)
        session.controller.triggerCompletion()
        await waitForCondition("the popup of the first file") { session.controller.isShowingCompletion }
        switchDocument(session, to: second, caretAfter: "        te", tab: 1)
        await waitForCondition("popup closed after the switch") { !session.controller.isShowingCompletion }
    }

    func testSwitchingFilesWithAnOpenPopupClosesIt() async throws {
        let session = try await openSession(receiverSource, caretAfter: "        text", otherDocumentText: otherJavaSource)
        await waitUntilTheControllerHandlesAdapterEvents(session)
        session.textView.insertText(".")
        await waitForCondition("popup") { session.controller.isShowingCompletion }
        switchDocument(session, to: otherJavaSource, caretAfter: "        word", tab: 1)
        await waitForCondition("popup closed after the switch") { !session.controller.isShowingCompletion }
        XCTAssertTrue(labels(session).isEmpty, "rows of the previous file are still listed: \(labels(session))")
    }

    /// The provider is still in its slow phase when the user switches tabs; what it then sends belongs to the
    /// file that was left, and must not open a popup over the new one.
    func testSlowResultArrivingAfterAFileSwitchIsNotShown() async throws {
        CompletionLatencyTrace.setEnabled(true)
        defer { CompletionLatencyTrace.setEnabled(false); CompletionLatencyTrace.reset() }
        let source = receiverSource.replacingOccurrences(of: "        text\n", with: "        te\n")
        let session = try await openSession(source, caretAfter: "        te", otherDocumentText: otherJavaSource)
        await waitUntilTheControllerHandlesAdapterEvents(session)
        CompletionLatencyTrace.setEnabled(true)
        let latch = TestLatch()
        await session.provider.setSlowPhaseHook { await latch.pass() }
        CompletionLatencyTrace.reset()

        session.controller.triggerCompletion()
        await waitForCondition("the slow phase to be reached") { await latch.hasWaiter }
        switchDocument(session, to: otherJavaSource, caretAfter: "        wor", tab: 1)
        // The controller cancels the request when it handles the switch: by the document check, or by the caret
        // rules if their event comes first. Either way the cancellation reaches the provider.
        await waitForCondition("the cancellation to reach the provider") { session.provider.terminationCount.withLock { $0 } >= 1 }
        await latch.open()
        // The request was cancelled: the provider's slow phase is skipped, never run, and nothing more arrives.
        await waitForCondition("the abandoned request to finish") {
            let finished = await session.provider.slowPhaseRunCount + session.provider.slowPhaseSkipCount
            return finished >= 1
        }
        let ran = await session.provider.slowPhaseRunCount
        XCTAssertEqual(ran, 0, "the slow phase of a request for the file that was left ran")
        XCTAssertFalse(session.controller.isShowingCompletion, "rows for the previous file opened a popup: \(labels(session))")
        XCTAssertEqual(session.textView.text, otherJavaSource)
    }

    /// Java to a file that is not Java: no Java rows, and typing there asks nothing of the Java provider.
    func testSwitchingToAnotherLanguageLeavesNoJavaRowsAndAsksNoJavaProvider() async throws {
        let session = try await openSession(receiverSource, caretAfter: "        text")
        session.textView.insertText(".")
        await waitForCondition("popup") { session.controller.isShowingCompletion }
        switchDocument(session, to: "alpha beta alphabet\nalp", caretAfter: "alp", language: nil)
        await waitForCondition("popup closed after the switch") { !session.controller.isShowingCompletion }

        let calls = await session.provider.requestCount
        CompletionLatencyTrace.setEnabled(true)
        defer { CompletionLatencyTrace.setEnabled(false); CompletionLatencyTrace.reset() }
        CompletionLatencyTrace.reset()
        session.textView.insertText("h")
        await waitForCondition("the engine's final answer for the new file") {
            CompletionLatencyTrace.events().contains { $0.name == "snapshot" && $0.detail.contains("finished=true") }
        }
        XCTAssertFalse(labels(session).contains("length"), "\(labels(session))")
        let after = await session.provider.requestCount
        XCTAssertEqual(after, calls, "the Java provider took a request for a non-Java file")
    }

    /// The tab that owns the open popup is closed; the pane shows the neighbour.
    func testClosingTheDocumentDuringCompletionClosesThePopupAndShowsNothingOfIt() async throws {
        let session = try await openSession(receiverSource, caretAfter: "        text", otherDocumentText: otherJavaSource)
        await waitUntilTheControllerHandlesAdapterEvents(session)
        session.textView.insertText(".")
        await waitForCondition("popup") { session.controller.isShowingCompletion }
        session.workbench?.activePane.closeDocument(session.documents[0].id)
        switchDocument(session, to: otherJavaSource, caretAfter: "        wor", tab: 1)
        await waitForCondition("popup closed with its document") { !session.controller.isShowingCompletion }
        XCTAssertTrue(labels(session).isEmpty)
    }

    /// Back to the first file: the popup it had is gone, and typing there starts a fresh, correct request.
    func testReturningToAPreviouslyOpenedDocumentStartsFresh() async throws {
        let session = try await openSession(receiverSource, caretAfter: "        text", otherDocumentText: otherJavaSource)
        await waitUntilTheControllerHandlesAdapterEvents(session)
        session.textView.insertText(".")
        await waitForCondition("popup") { session.controller.isShowingCompletion }
        let firstText = session.textView.text
        switchDocument(session, to: otherJavaSource, caretAfter: "        word", tab: 1)
        await waitForCondition("popup closed after the switch") { !session.controller.isShowingCompletion }

        switchDocument(session, to: firstText, caretAfter: "        text.", tab: 0)
        XCTAssertFalse(session.controller.isShowingCompletion, "the old popup came back with the tab")
        session.textView.insertText("s")
        session.textView.insertText("u")
        await waitForCondition("members of String again") { self.labels(session).contains("substring") }
        XCTAssertFalse(labels(session).contains("word"), "rows of the other file: \(labels(session))")
    }

    // MARK: - Focus

    /// The window loses key status (⌘-Tab, a dialog): the popup closes. Getting it back does not bring it
    /// back; typing asks again.
    func testLosingAndRegainingFocusClosesThePopupAndTypingAsksAgain() async throws {
        let session = try await openSession(receiverSource, caretAfter: "        text")
        session.textView.insertText(".")
        await waitForCondition("popup") { session.controller.isShowingCompletion }
        let window = try XCTUnwrap(self.window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        await waitForCondition("popup closed when the window lost focus") { !session.controller.isShowingCompletion }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(session.controller.isShowingCompletion, "regaining focus reopened the popup")

        session.textView.insertText("s")
        await waitForCondition("a fresh popup after typing") { self.labels(session).contains("substring") }
    }

    /// Another window losing key status must not close this window's popup.
    func testAnotherWindowLosingFocusLeavesThePopupAlone() async throws {
        let session = try await openSession(receiverSource, caretAfter: "        text")
        session.textView.insertText(".")
        await waitForCondition("popup") { session.controller.isShowingCompletion }
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(session.controller.isShowingCompletion)
    }

    // MARK: - Lifetime

    /// The controller, its requests and the provider do not outlive the editor: after the view and controller
    /// are released, an in-flight request does not keep them alive.
    func testControllerIsReleasedEvenWithARequestInFlight() async throws {
        weak var weakController: EditorIntelligenceController?
        weak var weakTextView: TextView?
        do {
            let source = receiverSource.replacingOccurrences(of: "        text\n", with: "        te\n")
            let session = try await openSession(source, caretAfter: "        te")
            let latch = TestLatch()
            await session.provider.setSlowPhaseHook { await latch.pass() }
            session.controller.triggerCompletion()
            await waitForCondition("the slow phase to be reached") { await latch.hasWaiter }
            weakController = session.controller
            weakTextView = session.textView
            self.window = nil
            await latch.open()
        }
        await waitForCondition("the controller and its text view to be released") { weakController == nil && weakTextView == nil }
    }

    /// Replacing the document (switching files) while a popup is open closes it.
    func testReplacingTheTextClosesTheOpenPopup() async throws {
        let session = try await openSession(receiverSource, caretAfter: "        text")
        session.textView.insertText(".")
        await waitForCondition("popup") { session.controller.isShowingCompletion }
        session.textView.text = "class Other {}\n"
        session.textView.selectedRange = NSRange(location: 0, length: 0)
        await waitForCondition("popup closed after the text was replaced") { !session.controller.isShowingCompletion }
    }
}

private actor TestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var hasWaiter: Bool { !waiters.isEmpty }

    func pass() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
