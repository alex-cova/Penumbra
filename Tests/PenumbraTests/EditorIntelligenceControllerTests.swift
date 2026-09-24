import XCTest
import AppKit
import Penumbra
import EditorIntelligence

@MainActor
final class EditorIntelligenceControllerTests: XCTestCase {
    func testControllerPresentsCompletions() async throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        let textView = TextView(frame: window.contentView!.bounds)
        textView.theme = DefaultTheme()
        textView.text = "hel"
        window.contentView = textView

        let provider = MockCompletionProvider(items: [
            CompletionItem(
                label: "hello",
                insertText: "hello",
                kind: .function,
                range: makeRange(start: 0, end: 3),
                source: "Test"
            )
        ])
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [provider], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [])
        )

        controller.triggerCompletion()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(controller.adapter.currentDocument?.text.isEmpty ?? true)
    }

    func testAcceptSelectedCompletionAppliesAtEveryCaret() async throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        let textView = TextView(frame: window.contentView!.bounds)
        textView.theme = DefaultTheme()
        textView.text = "hel hel hel"
        window.contentView = textView
        textView.selectedRange = NSRange(location: 3, length: 0)

        // Two candidates, so the explicit request shows the popup instead of inserting a lone
        // suggestion straight away.
        let provider = MockCompletionProvider(items: ["hello", "helium"].map {
            CompletionItem(
                label: $0,
                insertText: $0,
                kind: .function,
                range: makeRange(start: 0, end: 3),
                source: "Test"
            )
        })
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [provider], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [])
        )

        // `PenumbraEditorAdapter` captures its initial document snapshot asynchronously on
        // init; wait for that to land before triggering, or `adapter.currentDocument` is still
        // nil and `requestCompletion` bails out having never started a completion task at all.
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.triggerCompletion()
        try await Task.sleep(nanoseconds: 100_000_000)

        // A caret after each "hel", simulating multi-cursor at trigger time having grown into
        // this set before the user accepted the completion.
        textView.selectedRanges = [
            NSRange(location: 3, length: 0),
            NSRange(location: 7, length: 0),
            NSRange(location: 11, length: 0)
        ]

        controller.acceptSelectedCompletion()

        XCTAssertEqual(textView.text as String, "hello hello hello")
    }

    func testOrganizeImportsAppliesTheProvidersOrganizeAction() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "unused keep"
        let remove = CodeAction(
            title: "Remove unused", kind: CodeAction.organizeImportsKind,
            edits: [TextEdit(range: makeRange(start: 0, end: 7), replacement: "")]
        )
        let other = CodeAction(title: "Other", kind: "quickfix", edits: [TextEdit(range: makeRange(start: 0, end: 1), replacement: "X")])
        let controller = makeController(textView: textView, actions: [other, remove])
        try await Task.sleep(nanoseconds: 100_000_000)

        let applied = await controller.organizeImports()

        XCTAssertTrue(applied)
        XCTAssertEqual(textView.text as String, "keep")
    }

    func testOrganizeImportsIsFalseWithoutAnOrganizeAction() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "unchanged"
        let other = CodeAction(title: "Other", kind: "quickfix", edits: [TextEdit(range: makeRange(start: 0, end: 1), replacement: "X")])
        let controller = makeController(textView: textView, actions: [other])
        try await Task.sleep(nanoseconds: 100_000_000)

        let applied = await controller.organizeImports()

        XCTAssertFalse(applied)
        XCTAssertEqual(textView.text as String, "unchanged")
    }

    func testOptimizeImportsEditorActionOrganizesImports() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "unused keep"
        let remove = CodeAction(
            title: "Remove unused", kind: CodeAction.organizeImportsKind,
            edits: [TextEdit(range: makeRange(start: 0, end: 7), replacement: "")]
        )
        let controller = makeController(textView: textView, actions: [remove])
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(textView.perform(.optimizeImports))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(textView.text as String, "keep")
        withExtendedLifetime(controller) {}
    }

    func testBreadcrumbProviderOverridesTheGenericBreadcrumbs() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "class A {}"
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: []),
            services: EditorIntelligenceServices(breadcrumbProvider: MockBreadcrumbProvider(titles: ["A", "m(int)"]))
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        var received: [String] = []
        controller.onBreadcrumbsUpdated = { received = $0.map(\.title) }

        controller.refreshBreadcrumbs()
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(received, ["A", "m(int)"])
    }

    func testReformatFormatsTheSelectedLinesThroughTheFormattingProvider() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "a\nb\nc\n"
        let provider = MockFormattingProvider()
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: []),
            services: EditorIntelligenceServices(formattingProvider: provider)
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        textView.selectedRange = NSRange(location: 2, length: 1) // "b"

        XCTAssertTrue(textView.perform(.reformatCode))
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(textView.text as String, "a\n>b\nc\n")
        let seen = await provider.lastSelection
        XCTAssertEqual(seen?.start.line, 1, "the provider is given the live selection with real line numbers")
        withExtendedLifetime(controller) {}
    }

    func testReformatWithNothingSelectedFormatsTheWholeDocument() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "a\nb\n"
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: []),
            services: EditorIntelligenceServices(formattingProvider: MockFormattingProvider())
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        textView.selectedRange = NSRange(location: 0, length: 0)

        XCTAssertTrue(textView.perform(.reformatCode))
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(textView.text as String, "<a\nb\n")
        withExtendedLifetime(controller) {}
    }

    func testReformatFallsThroughWhenTheProviderDoesNotHandleTheDocument() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "a\n"
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: []),
            services: EditorIntelligenceServices(formattingProvider: MockFormattingProvider(supports: false))
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        // The controller does not claim it, so the text view's own re-indent runs instead.
        XCTAssertTrue(textView.perform(.reformatCode))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(textView.text as String, "a\n")
        withExtendedLifetime(controller) {}
    }

    private func makeController(textView: TextView, actions: [CodeAction]) -> EditorIntelligenceController {
        EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: []),
            services: EditorIntelligenceServices(codeActionProvider: MockCodeActionProvider(actions: actions))
        )
    }

    func testControllerAppliesDiagnostics() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "error"

        let provider = MockDiagnosticProvider(diagnostics: [
            Diagnostic(
                severity: .error,
                message: "Expected semicolon",
                range: makeRange(start: 0, end: 5),
                source: "Test"
            )
        ])
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [provider])
        )

        try await Task.sleep(nanoseconds: 100_000_000)
        controller.refreshDiagnostics()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(textView.diagnostics.count, 1)
        XCTAssertEqual(textView.diagnostics.first?.severity, .error)
    }

    func testControllerReportsDiagnosticsToHost() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "error"

        let provider = MockDiagnosticProvider(diagnostics: [
            Diagnostic(severity: .warning, message: "Careful", range: makeRange(start: 0, end: 5), source: "Test")
        ])
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [provider])
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        var reports: [DiagnosticReport] = []
        controller.onDiagnosticsUpdated = { reports.append($0) }
        controller.refreshDiagnostics()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.diagnostics.map(\.message), ["Careful"])
    }

    func testSupersededDiagnosticsRefreshIsNeverReported() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = "error"

        let provider = ScriptedDiagnosticProvider()
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [provider])
        )
        try await Task.sleep(nanoseconds: 100_000_000)

        var messages: [String] = []
        controller.onDiagnosticsUpdated = { messages.append(contentsOf: $0.diagnostics.map(\.message)) }
        await provider.enqueue([(delayMilliseconds: 300, message: "old"), (delayMilliseconds: 0, message: "new")])
        controller.refreshDiagnostics()
        try await Task.sleep(nanoseconds: 50_000_000)
        controller.refreshDiagnostics()
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(messages, ["new"])
        XCTAssertEqual(textView.diagnostics.count, 1)
    }
}

private actor ScriptedDiagnosticProvider: DiagnosticProvider {
    let name = "Scripted"
    private var script: [(delayMilliseconds: UInt64, message: String)] = []

    func enqueue(_ steps: [(delayMilliseconds: UInt64, message: String)]) { script = steps }

    func diagnostics(for document: Document) async -> [Diagnostic] {
        guard !script.isEmpty else { return [] }
        let step = script.removeFirst()
        if step.delayMilliseconds > 0 {
            try? await Task.sleep(nanoseconds: step.delayMilliseconds * 1_000_000)
        }
        return [Diagnostic(severity: .error, message: step.message, range: makeRange(start: 0, end: 5), source: "Test")]
    }
}

private actor MockCompletionProvider: CompletionProvider {
    let name = "Mock"
    let items: [CompletionItem]
    init(items: [CompletionItem]) { self.items = items }
    func provide(context: CompletionContext) async -> [CompletionItem] { items }
}

private actor MockDiagnosticProvider: DiagnosticProvider {
    let name = "Mock"
    let diagnostics: [Diagnostic]
    init(diagnostics: [Diagnostic]) { self.diagnostics = diagnostics }
    func diagnostics(for document: Document) async -> [Diagnostic] { diagnostics }
}

private func makeRange(start: Int, end: Int) -> EditorIntelligence.TextRange {
    EditorIntelligence.TextRange(
        start: TextPosition(line: 0, column: start, utf16Offset: start),
        end: TextPosition(line: 0, column: end, utf16Offset: end)
    )
}

private struct MockCodeActionProvider: CodeActionProviding {
    let actions: [CodeAction]

    func codeActions(for document: Document, at position: TextPosition, diagnostics: [Diagnostic]) async -> [CodeAction] {
        actions
    }
}

private struct MockBreadcrumbProvider: BreadcrumbProviding {
    let titles: [String]

    func breadcrumbs(for document: Document) async -> [BreadcrumbSegment]? {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return titles.map { BreadcrumbSegment(title: $0, range: TextRange(start: position, end: position)) }
    }
}

private actor MockFormattingProvider: FormattingProviding {
    private nonisolated let supports: Bool
    private(set) var lastSelection: EditorIntelligence.TextRange?

    init(supports: Bool = true) {
        self.supports = supports
    }

    nonisolated func supportsFormatting(_ document: Document) -> Bool {
        supports
    }

    func formatDocument(_ document: Document) async -> [TextEdit] {
        let start = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return [TextEdit(range: EditorIntelligence.TextRange(start: start, end: start), replacement: "<")]
    }

    func formatSelection(in document: Document, range: EditorIntelligence.TextRange) async -> [TextEdit] {
        lastSelection = range
        let start = range.start
        return [TextEdit(range: EditorIntelligence.TextRange(start: start, end: start), replacement: ">")]
    }
}
