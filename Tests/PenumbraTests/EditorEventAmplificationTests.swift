import AppKit
import EditorIntelligence
import XCTest
@testable import Penumbra

/// F13: what one edit or one caret move costs once it reaches the intelligence controller, counted
/// as events received and as provider calls actually made.
@MainActor
final class EditorEventAmplificationTests: XCTestCase {
    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Int] = [:]
        func bump(_ key: String) { lock.withLock { values[key, default: 0] += 1 } }
        func snapshot() -> [String: Int] { lock.withLock { values } }
        func reset() { lock.withLock { values = [:] } }
    }

    private struct CountingDiagnostics: DiagnosticProvider {
        let name = "Counting"
        let counts: Counts
        func diagnostics(for document: Document) async -> [Diagnostic] { counts.bump("diagnostics"); return [] }
    }

    private struct CountingInlay: InlayHintProviding {
        let counts: Counts
        func inlayHints(for document: Document, in range: EditorIntelligence.TextRange) async -> [InlayHint] {
            counts.bump("inlay"); return []
        }
    }

    private struct CountingCodeVision: CodeVisionProviding {
        let counts: Counts
        func codeVisionAnchors(for document: Document) async -> [Int] { counts.bump("codeVisionAnchors"); return [] }
        func codeVision(for document: Document, anchors: [Int]) async -> [CodeVisionLens] { counts.bump("codeVision"); return [] }
    }

    private struct CountingBreadcrumbs: BreadcrumbProviding {
        let counts: Counts
        func breadcrumbs(for document: Document) async -> [BreadcrumbSegment]? { counts.bump("breadcrumbs"); return [] }
    }

    private struct CountingCodeActions: CodeActionProviding {
        let counts: Counts
        func codeActions(for document: Document, at position: TextPosition, diagnostics: [Diagnostic]) async -> [CodeAction] { [] }
        func bulb(for document: Document, at position: TextPosition, diagnostics: [Diagnostic]) async -> CodeActionBulb {
            counts.bump("bulb"); return .none
        }
    }

    private struct Fixture {
        let controller: EditorIntelligenceController
        let textView: TextView
        let window: NSWindow
        let counts: Counts
        let events: Counts
        let listener: Task<Void, Never>
    }

    private func makeFixture() async throws -> Fixture {
        let counts = Counts()
        let events = Counts()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let textView = TextView(frame: window.contentView!.bounds)
        textView.theme = DefaultTheme()
        textView.text = (0 ..< 40).map { "func f\($0)() { let v = \($0) }" }.joined(separator: "\n")
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.layoutIfNeeded()
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [CountingDiagnostics(counts: counts)]),
            services: EditorIntelligenceServices(
                codeActionProvider: CountingCodeActions(counts: counts),
                breadcrumbProvider: CountingBreadcrumbs(counts: counts),
                inlayHintProvider: CountingInlay(counts: counts),
                codeVisionProvider: CountingCodeVision(counts: counts)
            )
        )
        controller.inlayHintsEnabled = true
        controller.codeVisionEnabled = true
        let stream = controller.adapter.events
        let listener = Task {
            for await event in stream {
                switch event {
                case .documentOpened: events.bump("documentOpened")
                case .documentChanged: events.bump("documentChanged")
                case .documentEdited: events.bump("documentEdited")
                case .selectionChanged: events.bump("selectionChanged")
                case .cursorMoved: events.bump("cursorMoved")
                default: events.bump("other")
                }
            }
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        counts.reset()
        events.reset()
        return Fixture(controller: controller, textView: textView, window: window, counts: counts, events: events, listener: listener)
    }

    private func assertAtMost(_ limits: [String: Int], _ fixture: Fixture, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let counts = fixture.counts.snapshot()
        for (key, limit) in limits {
            XCTAssertLessThanOrEqual(counts[key] ?? 0, limit, "\(label): \(key) ran \(counts[key] ?? 0) times, at most \(limit) expected (\(counts))", file: file, line: line)
        }
    }

    /// Measured 2026-11-04 (debug build, headless): one caret move reaches the controller as two
    /// events (`selectionChanged` and `cursorMoved`, always sent as a pair) but each provider is
    /// asked once; one keystroke adds one coalesced `documentEdited`, and each provider is asked
    /// once (the quick-fix bulb twice, the second time with the new diagnostics); twenty keystrokes
    /// 30 ms apart still produce one `documentEdited` and the same single provider calls. Handling
    /// a caret event costs about 3 µs. A change that makes consumers run per event instead of per
    /// quiet period fails here.
    func testEditsAreCoalescedBeforeTheyReachTheProviders() async throws {
        let f = try await makeFixture()
        defer { f.listener.cancel(); f.window.orderOut(nil); withExtendedLifetime((f.controller, f.textView)) {} }

        f.textView.selectedRange = NSRange(location: 5, length: 0)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        assertAtMost(["breadcrumbs": 1, "bulb": 1, "diagnostics": 0, "inlay": 0, "codeVision": 0], f, "one caret move")
        XCTAssertEqual(f.events.snapshot()["cursorMoved"], 1)
        f.counts.reset(); f.events.reset()

        f.textView.insertText("x")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        assertAtMost(["diagnostics": 1, "inlay": 1, "codeVisionAnchors": 1, "breadcrumbs": 1, "bulb": 2], f, "one keystroke")
        XCTAssertEqual(f.events.snapshot()["documentEdited"], 1)
        XCTAssertEqual(f.counts.snapshot()["diagnostics"], 1, "the edit must still reach diagnostics")
        f.counts.reset(); f.events.reset()

        for _ in 0 ..< 20 {
            f.textView.insertText("y")
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        assertAtMost(["diagnostics": 1, "inlay": 1, "codeVisionAnchors": 1, "breadcrumbs": 1, "bulb": 2], f, "20 keystrokes")
        XCTAssertLessThanOrEqual(f.events.snapshot()["documentEdited"] ?? 0, 2)
        XCTAssertEqual(f.counts.snapshot()["diagnostics"], 1)
    }
}
