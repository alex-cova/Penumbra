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
