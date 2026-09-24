import AppKit
import EditorIntelligence
import XCTest
@testable import Penumbra

/// Keystrokes commit on the text view while a provider is still blocked, and a superseded
/// intelligence result cannot change the document or the presented completion or diagnostics.
@MainActor
final class InteractivePathTests: XCTestCase {
    func testKeystrokeUpdatesDocumentBeforeBlockingProviderFinishes() async throws {
        let gate = AsyncGate()
        let provider = GatedCompletionProvider(gate: gate, itemsForCall: { _ in [] })
        let textView = makeTextView("hello")
        let controller = makeController(textView: textView, completion: provider, diagnostics: nil)
        defer { gate.releaseAll() }
        try await waitForDocument(controller)

        let end = (textView.text as NSString).length
        textView.selectedRange = NSRange(location: end, length: 0)
        textView.insertText("q")

        try await waitUntil(timeout: 2) { gate.enteredCount >= 1 }
        XCTAssertEqual(gate.finishedCount, 0)
        XCTAssertEqual(textView.text as String, "helloq")
        XCTAssertEqual(textView.selectedRange, NSRange(location: end + 1, length: 0))

        textView.undoManager?.undo()
        XCTAssertEqual(textView.text as String, "hello")
        textView.undoManager?.redo()
        XCTAssertEqual(textView.text as String, "helloq")
        XCTAssertEqual(textView.selectedRange, NSRange(location: end + 1, length: 0))
        XCTAssertEqual(gate.finishedCount, 0)
        withExtendedLifetime(controller) {}
    }

    func testStaleCompletionDoesNotChangeDocumentOrPopup() async throws {
        let gate = AsyncGate()
        let provider = GatedCompletionProvider(gate: gate, itemsForCall: { call in
            let label = call == 1 ? "STALE_TOKEN" : "FRESH_TOKEN"
            return [completionItem(label)]
        })
        let textView = makeTextView("hel")
        let controller = makeController(textView: textView, completion: provider, diagnostics: nil)
        defer { gate.releaseAll() }
        try await waitForDocument(controller)
        textView.selectedRange = NSRange(location: 3, length: 0)

        controller.triggerCompletion()
        try await waitUntil(timeout: 2) { gate.enteredCount >= 1 }
        XCTAssertEqual(gate.finishedCount, 0)
        XCTAssertEqual(textView.text as String, "hel")

        textView.insertText("z")
        XCTAssertEqual(textView.text as String, "helz")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertEqual(gate.finishedCount, 0)

        gate.releaseAll()
        try await waitUntil(timeout: 2) { gate.finishedCount >= 1 }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(textView.text as String, "helz")
        XCTAssertFalse(textView.text.contains("STALE_TOKEN"))
        XCTAssertFalse(controller.visibleCompletionItems.contains { $0.label == "STALE_TOKEN" })
        withExtendedLifetime(controller) {}
    }

    func testLargeUntitledKeystrokeDoesNotMaterializeForCompletion() async throws {
        let line = String(repeating: "value ", count: 40) + "\n"
        let text = String(repeating: line, count: 1_200)
        let textView = makeTextView(text)
        XCTAssertFalse(textView.isFileBacked)
        XCTAssertNotNil(textView.pieceTreeContentSnapshot())
        let seen = CompletionTail()
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [seen], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [ImmediateDiagnosticProvider()])
        )
        try await waitForDocument(controller)
        let before = textView.pieceTreeMaterializeCount
        let end = textView.documentLength
        textView.selectedRange = NSRange(location: end, length: 0)
        textView.insertText("z")

        try await waitUntil(timeout: 2) { seen.tail == "z" }
        XCTAssertEqual(textView.text(in: NSRange(location: textView.documentLength - 1, length: 1)), "z")
        XCTAssertEqual(textView.pieceTreeMaterializeCount, before)
        withExtendedLifetime(controller) {}
    }

    func testStaleDiagnosticsDoNotApplyAfterNewerRequest() async throws {
        let gate = AsyncGate()
        let staleID = UUID()
        let provider = GatedDiagnosticProvider(gate: gate) { call in
            let message = call == 1 ? "STALE_DIAG" : "FRESH_DIAG"
            let id = call == 1 ? staleID : UUID()
            return [Diagnostic(
                id: id,
                severity: .error,
                message: message,
                range: TextRange(
                    start: TextPosition(line: 0, column: 0, utf16Offset: 0),
                    end: TextPosition(line: 0, column: 1, utf16Offset: 1)
                ),
                source: "gated"
            )]
        }
        let textView = makeTextView("hel")
        let controller = makeController(textView: textView, completion: nil, diagnostics: provider)
        defer { gate.releaseAll() }
        try await waitForDocument(controller)

        var applied: [Diagnostic] = []
        controller.onDiagnosticsUpdated = { report in
            applied.append(contentsOf: report.diagnostics)
        }

        controller.refreshDiagnostics()
        try await waitUntil(timeout: 2) { gate.enteredCount >= 1 }
        textView.selectedRange = NSRange(location: 3, length: 0)
        textView.insertText("z")
        XCTAssertEqual(textView.text as String, "helz")
        XCTAssertEqual(gate.finishedCount, 0)

        controller.refreshDiagnostics()
        gate.releaseAll()
        try await waitUntil(timeout: 2) { gate.finishedCount >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(textView.text as String, "helz")
        XCTAssertFalse(applied.contains { $0.id == staleID })
        XCTAssertFalse(textView.diagnostics.contains { $0.id == staleID.uuidString })
        withExtendedLifetime(controller) {}
    }

    private func makeTextView(_ text: String) -> TextView {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = text
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        windows.append(window)
        return textView
    }

    private var windows: [NSWindow] = []

    private func makeController(
        textView: TextView,
        completion: GatedCompletionProvider?,
        diagnostics: GatedDiagnosticProvider?
    ) -> EditorIntelligenceController {
        let completionProvider: any CompletionProvider = completion ?? ImmediateCompletionProvider()
        let diagnosticProvider: any DiagnosticProvider = diagnostics ?? ImmediateDiagnosticProvider()
        return EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [completionProvider], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [diagnosticProvider])
        )
    }

    private func waitForDocument(_ controller: EditorIntelligenceController) async throws {
        try await waitUntil(timeout: 2) { controller.adapter.currentDocument != nil }
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(predicate())
    }
}

private func completionItem(_ label: String) -> CompletionItem {
    CompletionItem(
        label: label,
        insertText: label,
        kind: .function,
        range: TextRange(
            start: TextPosition(line: 0, column: 0, utf16Offset: 0),
            end: TextPosition(line: 0, column: 3, utf16Offset: 3)
        ),
        source: "gated"
    )
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = 0
    private var finished = 0
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async -> Int {
        let call: Int = lock.withLock {
            entered += 1
            return entered
        }
        let alreadyReleased: Bool = lock.withLock { isReleased }
        if alreadyReleased {
            return call
        }
        await withCheckedContinuation { continuation in
            lock.lock()
            if isReleased {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
        return call
    }

    func markFinished() {
        lock.withLock { finished += 1 }
    }

    func releaseAll() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            isReleased = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            waiter.resume()
        }
    }

    var enteredCount: Int { lock.withLock { entered } }
    var finishedCount: Int { lock.withLock { finished } }
}

private struct GatedCompletionProvider: CompletionProvider {
    let name = "gated-completion"
    let gate: AsyncGate
    let itemsForCall: @Sendable (Int) -> [CompletionItem]

    func provide(context: CompletionContext) async -> [CompletionItem] {
        let call = await gate.enter()
        let items = itemsForCall(call)
        gate.markFinished()
        return items
    }
}

private final class CompletionTail: CompletionProvider, @unchecked Sendable {
    let name = "completion-tail"
    nonisolated(unsafe) var tail: String?

    func provide(context: CompletionContext) async -> [CompletionItem] {
        let length = context.document.contentSnapshot.utf16Length
        tail = context.document.substring(utf16Offset: max(0, length - 1), length: 1)
        return []
    }
}

private struct ImmediateCompletionProvider: CompletionProvider {
    let name = "immediate-completion"
    func provide(context: CompletionContext) async -> [CompletionItem] { [] }
}

private struct ImmediateDiagnosticProvider: DiagnosticProvider {
    let name = "immediate-diagnostics"
    func diagnostics(for document: Document) async -> [Diagnostic] { [] }
}

private struct GatedDiagnosticProvider: DiagnosticProvider {
    let name = "gated-diagnostics"
    let gate: AsyncGate
    let diagnosticsForCall: @Sendable (Int) -> [Diagnostic]

    func diagnostics(for document: Document) async -> [Diagnostic] {
        let call = await gate.enter()
        let diagnostics = diagnosticsForCall(call)
        gate.markFinished()
        return diagnostics
    }
}
