import AppKit
import XCTest
@testable import Penumbra
import EditorIntelligence

/// Formatting computes edits against a buffer snapshot and applies them asynchronously. Typing
/// between the request and the apply must not garble the new text with stale ranges: the apply
/// is dropped (formatting is idempotent; the user re-invokes it) instead of applied.
@MainActor
final class FormatStaleApplyTests: XCTestCase {
    func testTypingDuringFormatDropsStaleEdits() async throws {
        let gate = FormatGate()
        let provider = GatedFormatProvider(gate: gate)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: window.contentView!.bounds)
        textView.theme = DefaultTheme()
        textView.text = "aaa"
        window.contentView = textView
        textView.selectedRange = NSRange(location: 0, length: 0)
        self.window = window

        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: []),
            services: EditorIntelligenceServices(formattingProvider: provider)
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        controller.formatDocument()
        await waitForCondition("provider to start formatting") { await gate.entered }
        // The user types while the provider works: the pending edit (replace 0..<3) is stale now.
        textView.insertText("X")
        await gate.open()
        await waitForCondition("provider to finish") { await gate.finished }

        XCTAssertEqual(textView.text, "Xaaa")
    }

    // MARK: - Helpers

    private var window: NSWindow?
}

private actor FormatGate {
    private(set) var entered = false
    private(set) var finished = false
    private(set) var isOpen = false

    func recordEntry() { entered = true }
    func recordFinished() { finished = true }
    func open() { isOpen = true }
}

private struct GatedFormatProvider: FormattingProviding {
    let gate: FormatGate

    func formatDocument(_ document: Document) async -> [TextEdit] {
        await gate.recordEntry()
        while await !gate.isOpen {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        await gate.recordFinished()
        let start = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let end = TextPosition(line: 0, column: 3, utf16Offset: 3)
        return [TextEdit(range: EditorIntelligence.TextRange(start: start, end: end), replacement: "formatted")]
    }

    func formatSelection(in document: Document, range: EditorIntelligence.TextRange) async -> [TextEdit] {
        []
    }
}
