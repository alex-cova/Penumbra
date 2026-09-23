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

    func testKeepsOverloadsThatDifferInSignature() async throws {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let range = TextRange(start: position, end: position)
        let provider = MockCompletionProvider(name: "Java", items: [
            CompletionItem(label: "println", insertText: "println()", kind: .method, range: range, source: "Java", labelDetail: "()"),
            CompletionItem(label: "println", insertText: "println()", kind: .method, range: range, source: "Java", labelDetail: "(String x)")
        ])
        let engine = CompletionEngine(providers: [provider], debounceInterval: 0)
        let results = try await engine.complete(context: makeContext(prefix: "pr"))
        XCTAssertEqual(results.count, 2)
    }

    func testPrimaryProviderSuppressesFallbackResults() async throws {
        let primary = MockCompletionProvider(name: "Primary", items: [makeItem(label: "format", kind: .method, source: "Primary")], primary: true)
        let fallback = MockCompletionProvider(name: "Word", items: [makeItem(label: "foo", kind: .text, source: "Word")])
        let engine = CompletionEngine(providers: [primary, fallback], debounceInterval: 0)
        let results = try await engine.complete(context: makeContext(prefix: "f"))
        XCTAssertEqual(results.map(\.label), ["format"])
    }

    func testFallbackResultsShowWhenPrimaryHasNothing() async throws {
        let primary = MockCompletionProvider(name: "Primary", items: [], primary: true)
        let fallback = MockCompletionProvider(name: "Word", items: [makeItem(label: "foo", kind: .text, source: "Word")])
        let engine = CompletionEngine(providers: [primary, fallback], debounceInterval: 0)
        let results = try await engine.complete(context: makeContext(prefix: "f"))
        XCTAssertEqual(results.map(\.label), ["foo"])
    }

    func testFallbackResultsNeverFollowMemberAccessDot() async throws {
        let primary = MockCompletionProvider(name: "Primary", items: [], primary: true)
        let fallback = MockCompletionProvider(name: "Word", items: [makeItem(label: "foo", kind: .text, source: "Word")])
        let engine = CompletionEngine(providers: [primary, fallback], debounceInterval: 0)
        let text = "a.f"
        let position = TextPosition(line: 0, column: 3, utf16Offset: 3)
        let document = Document(
            id: DocumentID(), url: nil, displayName: "test", contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100)
        )
        let context = makeCompletionContext(document: document, trigger: .keystroke("f"))
        XCTAssertTrue(context.isMemberAccess)
        let results = try await engine.complete(context: context)
        XCTAssertEqual(results, [])
    }

    func testLaterYieldReplacesTheSnapshot() async throws {
        let provider = TwoStepProvider()
        let engine = CompletionEngine(providers: [provider], debounceInterval: 0)
        var labels: [[String]] = []
        for try await update in await engine.completeUpdates(context: makeContext(prefix: "a")) {
            labels.append(update.items.map(\.label))
        }
        XCTAssertEqual(labels.first, ["alpha"])
        XCTAssertEqual(Set(labels.last ?? []), ["alpha", "able"])
    }

    func testWordStartStaysWhenNothingElseMatches() {
        let ranker = DefaultRanker()
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let range = TextRange(start: position, end: position)
        let items = [
            CompletionItem(label: "getName", insertText: "getName", kind: .method, range: range, source: "Test"),
            CompletionItem(label: "Name", insertText: "Name", kind: .method, range: range, source: "Test")
        ]
        let onlyMiddle = ranker.rankSynchronously(items: [items[0]], prefix: "Name").map(\.item.label)
        XCTAssertEqual(onlyMiddle, ["getName"])
        let withStart = ranker.rankSynchronously(items: items, prefix: "Name").map(\.item.label)
        XCTAssertEqual(withStart, ["Name"])
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

private struct TwoStepProvider: CompletionProvider {
    let name = "TwoStep"

    func provide(context: CompletionContext) async -> [CompletionItem] { [] }

    func provideUpdates(context: CompletionContext) -> AsyncStream<CompletionUpdate> {
        let range = context.range
        return AsyncStream { continuation in
            continuation.yield(CompletionUpdate(items: [
                CompletionItem(label: "alpha", insertText: "alpha", kind: .method, range: range, source: name)
            ], isFinished: false))
            continuation.yield(CompletionUpdate(items: [
                CompletionItem(label: "alpha", insertText: "alpha", kind: .method, range: range, source: name),
                CompletionItem(label: "able", insertText: "able", kind: .method, range: range, source: name)
            ], isFinished: true))
            continuation.finish()
        }
    }
}

private struct MockCompletionProvider: CompletionProvider {
    let name: String
    let items: [CompletionItem]
    var primary = false

    func provide(context: CompletionContext) async -> [CompletionItem] {
        items
    }

    func isPrimary(for context: CompletionContext) -> Bool {
        primary
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