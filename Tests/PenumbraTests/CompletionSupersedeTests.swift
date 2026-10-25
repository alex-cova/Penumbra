import EditorIntelligence
import XCTest

/// A superseded completion request must never deliver its (now stale) items: starting a second
/// request cancels the first, and the first surfaces `CancellationError` instead of results.
/// The fresh request is unaffected.
@MainActor
final class CompletionSupersedeTests: XCTestCase {
    func testSupersededRequestThrowsInsteadOfDeliveringStaleItems() async throws {
        let gate = CompletionGate()
        let provider = GatedCompletionProvider(name: "Gated", gate: gate)
        let engine = CompletionEngine(providers: [provider], debounceInterval: 0)

        let firstTask = Task {
            try await engine.complete(context: Self.makeContext(prefix: "a"))
        }
        // Wait until the first request is actually inside the provider: without this the second
        // request could win the race before any overlap exists and the test would prove nothing.
        await waitForCondition("first request to enter the provider") { await gate.entries >= 1 }

        let secondTask = Task {
            try await engine.complete(context: Self.makeContext(prefix: "ab"))
        }
        // Open the gate only after the second request has entered the provider too, so the first
        // request is guaranteed to still be in flight (and therefore cancelled) when it resumes.
        await waitForCondition("second request to enter the provider") { await gate.entries >= 2 }
        await gate.open()

        do {
            let first = try await firstTask.value
            XCTAssertTrue(
                first.isEmpty,
                "Superseded request must not deliver stale items, got \(first.map(\.label))"
            )
        } catch is CancellationError {
            // Also acceptable: the stale request is dropped by cancellation.
        }
        let second = try await secondTask.value
        XCTAssertEqual(second.map(\.label), ["ab-item"])
        let entries = await gate.entries
        XCTAssertEqual(entries, 2)
    }

    // MARK: - Helpers

    private static func makeContext(prefix: String) -> CompletionContext {
        let snapshot = TextSnapshot(version: 0, text: "\(prefix)")
        let position = TextPosition(line: 0, column: prefix.count, utf16Offset: prefix.count)
        let document = Document(
            id: DocumentID(),
            url: nil,
            displayName: "test",
            contentSnapshot: snapshot,
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100)
        )
        return CompletionContext(
            document: document,
            cursor: Cursor(position: position),
            trigger: .keystroke(prefix),
            prefix: prefix,
            range: TextRange(start: position, end: position)
        )
    }
}

private actor CompletionGate {
    private(set) var entries = 0
    private(set) var isOpen = false

    func recordEntry() { entries += 1 }
    func open() { isOpen = true }
}

private struct GatedCompletionProvider: CompletionProvider {
    let name: String
    let gate: CompletionGate

    func provide(context: CompletionContext) async -> [CompletionItem] {
        await gate.recordEntry()
        while await !gate.isOpen {
            if Task.isCancelled { return [] }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let range = context.range
        return [
            CompletionItem(
                label: "\(context.prefix)-item",
                insertText: "\(context.prefix)-item",
                kind: .method,
                range: range,
                source: name
            )
        ]
    }
}
