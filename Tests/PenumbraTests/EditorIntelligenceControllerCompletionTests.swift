import XCTest
import AppKit
@testable import Penumbra
import EditorIntelligence

/// Completion UX of ``EditorIntelligenceController`` against a real ``TextView``: auto-popup on
/// typing, instant local re-filtering, Enter vs Tab, caret placement, and closing rules.
@MainActor
final class EditorIntelligenceControllerCompletionTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func makeTextView(_ text: String, caret: Int) -> TextView {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: window.contentView!.bounds)
        textView.theme = DefaultTheme()
        textView.text = text
        window.contentView = textView
        textView.selectedRange = NSRange(location: caret, length: 0)
        self.window = window
        return textView
    }

    private func makeController(_ textView: TextView, adapter: EditorAdapter? = nil, provider: CompletionProvider) async throws -> EditorIntelligenceController {
        let controller = EditorIntelligenceController(
            textView: textView,
            adapter: adapter,
            completionEngine: CompletionEngine(providers: [provider], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [])
        )
        // The default adapter captures its first snapshot asynchronously.
        try await Task.sleep(nanoseconds: 50_000_000)
        return controller
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 1.5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func labels(_ controller: EditorIntelligenceController) -> [String] {
        controller.visibleCompletionItems.map(\.label)
    }

    /// Answers hover for whatever word sits at the caret of the (hypothetical) document.
    private struct WordHoverProvider: HoverProvider {
        let name = "WordHover"
        func provide(context: HoverContext) async -> HoverResult? {
            let text = context.document.text as NSString
            let start = context.cursor.position.utf16Offset
            var end = start
            while end < text.length, let scalar = UnicodeScalar(text.character(at: end)), CharacterSet.alphanumerics.contains(scalar) { end += 1 }
            guard end > start else { return nil }
            return HoverResult(contents: "docs for \(text.substring(with: NSRange(location: start, length: end - start)))", source: name)
        }
    }

    func testSelectedItemShowsDocumentationFromHoverEngine() async throws {
        let textView = makeTextView("", caret: 0)
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [StubProvider { _ in ["apple", "apricot"] }], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: [WordHoverProvider()]),
            diagnosticEngine: DiagnosticEngine(providers: [])
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        textView.insertText("ap")
        try await waitUntil { controller.isShowingCompletion }
        try await waitUntil { controller.completionDocumentation != nil }
        XCTAssertEqual(controller.completionDocumentation, "docs for apple")
        XCTAssertEqual(textView.text, "ap", "resolving documentation must not edit the buffer")

        controller.dismissCompletion()
        XCTAssertNil(controller.completionDocumentation)
    }

    func testTypingDotOpensPopupThroughWorkbenchAdapter() async throws {
        let textView = makeTextView("foo", caret: 3)
        let bench = EditorWorkbench()
        bench.openDocument(WorkbenchDocument(displayName: "A.java", text: "foo"))
        let adapter = PenumbraWorkbenchEditorAdapter(workbench: bench, textView: textView)
        let provider = StubProvider { context in
            context.isMemberAccess ? ["bar", "baz"] : []
        }
        let controller = try await makeController(textView, adapter: adapter, provider: provider)

        textView.insertText(".")
        try await waitUntil { controller.isShowingCompletion }

        XCTAssertEqual(textView.text, "foo.")
        XCTAssertEqual(labels(controller), ["bar", "baz"])
    }

    func testPopupIsVisibleInViewportWhenScrolledFarDown() async throws {
        let lines = (0..<300).map { "line \($0)" }.joined(separator: "\n") + "\nfoo"
        let textView = makeTextView(lines, caret: (lines as NSString).length)
        textView.layoutSubtreeIfNeeded()
        textView.scrollRangeToVisible(textView.selectedRange)
        let provider = StubProvider { context in context.isMemberAccess ? ["bar", "baz"] : [] }
        let controller = try await makeController(textView, provider: provider)
        XCTAssertGreaterThan(textView.contentOffset.y, 1000, "precondition: scrolled far down")

        textView.insertText(".")
        try await waitUntil { controller.isShowingCompletion }

        let frame = try XCTUnwrap(controller.completionPanelFrameInViewport)
        XCTAssertTrue(textView.bounds.contains(frame), "popup \(frame) must be inside the visible text view \(textView.bounds)")
    }

    func testTypingLettersOpensPopupAndRefiltersKeepingSelection() async throws {
        let textView = makeTextView("", caret: 0)
        let provider = StubProvider { _ in ["apple", "apricot", "avocado"] }
        let controller = try await makeController(textView, provider: provider)

        textView.insertText("a")
        try await waitUntil { controller.isShowingCompletion }
        XCTAssertEqual(labels(controller), ["apple", "apricot", "avocado"])

        controller.moveCompletionSelection(by: 1)
        XCTAssertEqual(controller.selectedCompletionItem?.label, "apricot")

        textView.insertText("p")
        // Local re-filtering is synchronous: no wait needed for the list to narrow.
        XCTAssertEqual(labels(controller), ["apple", "apricot"])
        XCTAssertEqual(controller.selectedCompletionItem?.label, "apricot")
    }

    func testCamelHumpFilteringWhileTyping() async throws {
        let textView = makeTextView("", caret: 0)
        let provider = StubProvider { _ in ["getName", "getNumber", "gender"] }
        let controller = try await makeController(textView, provider: provider)

        textView.insertText("g")
        try await waitUntil { controller.isShowingCompletion }
        textView.insertText("N")
        XCTAssertEqual(labels(controller), ["getName", "getNumber"])
    }

    func testEnterInsertsAndTabReplacesIdentifierSuffix() async throws {
        let textView = makeTextView("helXYZ + 1", caret: 3)
        let provider = StubProvider { _ in ["hello", "helium"] }
        let controller = try await makeController(textView, provider: provider)

        controller.triggerCompletion()
        try await waitUntil { controller.isShowingCompletion }
        controller.acceptSelectedCompletion(replacingIdentifier: true)
        XCTAssertEqual(textView.text, "hello + 1")

        textView.text = "helXYZ + 1"
        textView.selectedRange = NSRange(location: 3, length: 0)
        controller.triggerCompletion()
        try await waitUntil { controller.isShowingCompletion }
        controller.acceptSelectedCompletion(replacingIdentifier: false)
        XCTAssertEqual(textView.text, "helloXYZ + 1")
    }

    /// ⇧⏎ in the popup is IntelliJ's Start New Line: the typed prefix stays, the popup closes and
    /// the line is left intact. ⌘⏎ doesn't accept the item either.
    func testModifiedReturnDoesNotAcceptCompletion() async throws {
        let textView = makeTextView("x = hel;", caret: 7)
        textView.keymap = .intelliJ
        window?.makeKeyAndOrderFront(nil)
        textView.layoutIfNeeded()
        XCTAssertTrue(textView.focusTextInput())
        let controller = try await makeController(textView, provider: StubProvider { _ in ["hello", "help"] })

        controller.triggerCompletion()
        try await waitUntil { controller.isShowingCompletion }
        send(keyEvent(keyCode: 0x24, characters: "\r", flags: .shift), to: textView)
        XCTAssertFalse(controller.isShowingCompletion)
        XCTAssertEqual(textView.text, "x = hel;\n")

        textView.text = "x = hel;"
        textView.selectedRange = NSRange(location: 7, length: 0)
        controller.triggerCompletion()
        try await waitUntil { controller.isShowingCompletion }
        send(keyEvent(keyCode: 0x24, characters: "\r", flags: .command), to: textView)
        XCTAssertFalse(textView.text.contains("hello") || textView.text.contains("help;"))
    }

    func testLoneExplicitSuggestionIsInsertedWithCaretInsideParentheses() async throws {
        let textView = makeTextView("tak", caret: 3)
        let provider = StubProvider(items: { range in
            [CompletionItem(label: "take", insertText: "take()", kind: .method, range: range, source: "Stub", labelDetail: "(int n)", caretOffset: 5)]
        })
        let controller = try await makeController(textView, provider: provider)

        controller.triggerCompletion()
        try await waitUntil { textView.text == "take()" }

        XCTAssertEqual(textView.text, "take()")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 0))
        XCTAssertFalse(controller.isShowingCompletion)
    }

    func testAcceptingMethodBeforeExistingParenthesisDoesNotDuplicateIt() async throws {
        let textView = makeTextView("ta(1)", caret: 2)
        let provider = StubProvider(items: { range in
            ["take", "tail"].map { CompletionItem(label: $0, insertText: "\($0)()", kind: .method, range: range, source: "Stub", caretOffset: 5) }
        })
        let controller = try await makeController(textView, provider: provider)

        controller.triggerCompletion()
        try await waitUntil { controller.isShowingCompletion }
        XCTAssertEqual(controller.selectedCompletionItem?.label, "tail")
        controller.acceptSelectedCompletion()

        XCTAssertEqual(textView.text, "tail(1)")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 5, length: 0))
    }

    func testAdditionalEditsAreApplied() async throws {
        let textView = makeTextView("class A {}\nArr", caret: 14)
        let provider = StubProvider(items: { range in
            let start = TextPosition(line: 0, column: 0, utf16Offset: 0)
            let importEdit = EditorIntelligence.TextEdit(range: EditorIntelligence.TextRange(start: start, end: start), replacement: "import java.util.ArrayList;\n")
            return [
                CompletionItem(label: "ArrayList", insertText: "ArrayList", kind: .class, range: range, source: "Stub", additionalEdits: [importEdit]),
                CompletionItem(label: "ArrayDeque", insertText: "ArrayDeque", kind: .class, range: range, source: "Stub")
            ]
        })
        let controller = try await makeController(textView, provider: provider)

        controller.triggerCompletion()
        try await waitUntil { controller.isShowingCompletion }
        controller.moveCompletionSelection(by: labels(controller).firstIndex(of: "ArrayList") ?? 0)
        controller.acceptSelectedCompletion()

        XCTAssertEqual(textView.text, "import java.util.ArrayList;\nclass A {}\nArrayList")
        XCTAssertEqual(textView.selectedRange.location, (textView.text as NSString).length)
    }

    func testTypingNonIdentifierCharacterClosesPopup() async throws {
        let textView = makeTextView("", caret: 0)
        let provider = StubProvider { _ in ["alpha", "alps"] }
        let controller = try await makeController(textView, provider: provider)

        textView.insertText("a")
        try await waitUntil { controller.isShowingCompletion }
        textView.insertText(" ")
        XCTAssertFalse(controller.isShowingCompletion)
    }

    func testBackspacePastIdentifierStartClosesPopup() async throws {
        let textView = makeTextView("x ", caret: 2)
        let provider = StubProvider { _ in ["alpha", "alps"] }
        let controller = try await makeController(textView, provider: provider)

        textView.insertText("a")
        try await waitUntil { controller.isShowingCompletion }
        textView.deleteBackward()
        XCTAssertFalse(controller.isShowingCompletion)
    }

    func testUnfinishedCompletionWaitsBeforePainting() async throws {
        let textView = makeTextView("", caret: 0)
        let controller = try await makeController(textView, provider: HoldingProvider())
        textView.insertText("a")
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(controller.isShowingCompletion)
        try await waitUntil { controller.isShowingCompletion }
        XCTAssertEqual(labels(controller), ["alpha"])
    }

    func testLaterBatchDoesNotReorderFrozenRows() async throws {
        let textView = makeTextView("", caret: 0)
        let controller = try await makeController(textView, provider: HoldingProvider(second: "alpine"))
        textView.insertText("a")
        try await waitUntil { labels(controller) == ["alpha"] }
        try await waitUntil { labels(controller).count == 2 }
        XCTAssertEqual(labels(controller), ["alpha", "alpine"])
    }

    func testClickUserScrollAndResizeDismissThePopup() async throws {
        let lines = (0..<80).map { _ in "padding" }.joined(separator: "\n") + "\na"
        let caret = (lines as NSString).length
        let textView = makeTextView(lines, caret: caret)
        textView.layoutSubtreeIfNeeded()
        let provider = StubProvider(items: { range in
            [CompletionItem(label: "alpha", insertText: "alpha", kind: .function, range: range, source: "Stub", allowsAutoInsert: false)]
        })
        let controller = try await makeController(textView, provider: provider)
        controller.triggerCompletion()
        try await waitUntil { controller.isShowingCompletion }
        XCTAssertTrue(controller.isShowingCompletion)

        textView.onCaretRepositioningClick?()
        XCTAssertFalse(controller.isShowingCompletion)

        controller.triggerCompletion()
        try await waitUntil { controller.isShowingCompletion }
        let offset = textView.contentOffset
        textView.isUserInitiatedScroll = true
        textView.contentOffset = CGPoint(x: offset.x, y: max(0, offset.y - 40))
        textView.isUserInitiatedScroll = false
        XCTAssertFalse(controller.isShowingCompletion)

        controller.triggerCompletion()
        try await waitUntil { controller.isShowingCompletion }
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        XCTAssertTrue(controller.isShowingCompletion, "programmatic scrolling keeps the popup")
        try await Task.sleep(nanoseconds: 50_000_000)

        let frame = try XCTUnwrap(textView.window).frame
        textView.window?.setFrame(frame.insetBy(dx: 20, dy: 20), display: true)
        XCTAssertFalse(controller.isShowingCompletion)
    }

    func testClassNameIsNotAutoInserted() async throws {
        let textView = makeTextView("Arr", caret: 3)
        let provider = StubProvider(items: { range in
            [CompletionItem(label: "ArrayList", insertText: "ArrayList", kind: .class, range: range, source: "Stub", allowsAutoInsert: false)]
        })
        let controller = try await makeController(textView, provider: provider)
        controller.triggerCompletion()
        try await waitUntil { controller.isShowingCompletion }
        XCTAssertEqual(textView.text, "Arr")
        XCTAssertEqual(labels(controller), ["ArrayList"])
    }

    func testDigitsDoNotAutoOpenPopup() async throws {
        let textView = makeTextView("", caret: 0)
        let provider = StubProvider { _ in ["one"] }
        let controller = try await makeController(textView, provider: provider)

        textView.insertText("1")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(controller.isShowingCompletion)
    }

    func testShowingCompletionDoesNotBumpMetalPaintGeneration() async throws {
        guard MetalContext.isAvailable else {
            throw XCTSkip("Metal is not available")
        }
        let defaults = UserDefaults.standard.object(forKey: MetalActivation.defaultsKey) as? Bool
        guard MetalActivation.resolved(property: true, deviceAvailable: true, defaults: defaults) else {
            throw XCTSkip("Metal is disabled via UserDefaults kill switch")
        }
        let textView = makeTextView("hel", caret: 3)
        textView.isMetalRenderingEnabled = true
        textView.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        let beforeGeneration = textView.metalPaintGeneration
        let controller = try await makeController(
            textView,
            provider: StubProvider { _ in ["hello", "help", "helm"] }
        )
        textView.insertText("l")
        try await waitUntil { controller.isShowingCompletion }
        XCTAssertEqual(textView.metalPaintGeneration, beforeGeneration, "completion popup must not trigger a Metal present")
    }
}

/// Yields one row immediately, unfinished, then a second row after the popup has had time to paint.
private struct HoldingProvider: CompletionProvider {
    let name = "Holding"
    var second: String?

    func provide(context: CompletionContext) async -> [CompletionItem] { [] }

    func provideUpdates(context: CompletionContext) -> AsyncStream<CompletionUpdate> {
        let range = context.range
        let second = second
        return AsyncStream { continuation in
            let task = Task {
                let first = CompletionItem(label: "alpha", insertText: "alpha", kind: .method, range: range, source: "Holding", priority: 1)
                continuation.yield(CompletionUpdate(items: [first], isFinished: false))
                try? await Task.sleep(nanoseconds: 500_000_000)
                var items = [first]
                if let second {
                    items.append(CompletionItem(
                        label: second, insertText: second, kind: .method, range: range, source: "Holding", priority: 50
                    ))
                }
                continuation.yield(CompletionUpdate(items: items, isFinished: true))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Returns fixed labels (or items) with the request's replacement range.
private struct StubProvider: CompletionProvider {
    let name = "Stub"
    private let makeItems: @Sendable (CompletionContext) -> [CompletionItem]

    init(_ labels: @escaping @Sendable (CompletionContext) -> [String]) {
        makeItems = { context in
            labels(context).map { CompletionItem(label: $0, insertText: $0, kind: .function, range: context.range, source: "Stub") }
        }
    }

    init(items: @escaping @Sendable (EditorIntelligence.TextRange) -> [CompletionItem]) {
        makeItems = { context in items(context.range) }
    }

    func provide(context: CompletionContext) async -> [CompletionItem] {
        makeItems(context)
    }
}
