import XCTest
import EditorIntelligence

final class CompletionEngineTests: XCTestCase {
    func testWordAtUTF16OffsetInsideEmojiDoesNotTrap() {
        let text = String(repeating: "👨‍👩‍👧‍👦", count: 10)
        let extracted = word(at: 50, in: text)
        XCTAssertTrue(extracted.isEmpty || extracted == "👨‍👩‍👧‍👦")
    }

    func testRunsProvidersAndRanks() async throws {
        let provider = MockCompletionProvider(
            name: "Test",
            items: [
                makeItem(label: "foo", kind: .function, source: "Test"),
                makeItem(label: "bar", kind: .text, source: "Test")
            ]
        )
        let engine = CompletionEngine(providers: [provider], debounceInterval: 0)
        let context = makeContext(prefix: "fo")
        let results = try await engine.complete(context: context)
        XCTAssertEqual(results.map(\.label), ["foo"])
    }

    func testDeduplicatesByLabelAndInsertText() async throws {
        let first = MockCompletionProvider(
            name: "First",
            items: [makeItem(label: "foo", kind: .function, source: "First")]
        )
        let second = MockCompletionProvider(
            name: "Second",
            items: [makeItem(label: "foo", kind: .variable, source: "Second")]
        )
        let engine = CompletionEngine(providers: [first, second], debounceInterval: 0)
        let context = makeContext(prefix: "fo")
        let results = try await engine.complete(context: context)
        XCTAssertEqual(results.count, 1)
    }

    func testCancellation() async throws {
        let provider = MockCompletionProvider(name: "Test", items: [])
        let engine = CompletionEngine(providers: [provider], debounceInterval: 0.1)
        let context = makeContext(prefix: "fo")
        let task = Task {
            try await engine.complete(context: context)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        await engine.cancel()
        do {
            _ = try await task.value
            XCTFail("Should have been cancelled")
        } catch is CancellationError {
            // expected
        }
    }
}

private struct MockCompletionProvider: CompletionProvider {
    let name: String
    let items: [CompletionItem]

    func provide(context: CompletionContext) async -> [CompletionItem] {
        items
    }
}

private func makeContext(prefix: String) -> CompletionContext {
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

private func makeItem(label: String, kind: CompletionItemKind, source: String) -> CompletionItem {
    let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
    return CompletionItem(
        label: label,
        insertText: label,
        kind: kind,
        range: TextRange(start: position, end: position),
        source: source
    )
}