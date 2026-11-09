import XCTest
@testable import EditorIntelligence

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
        // The first request after a pause starts at once; one that follows within the interval waits for the
        // burst to end, and that is the request a cancel finds still waiting.
        _ = await engine.completeUpdates(context: makeContext(prefix: "f"))
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

    // MARK: - Debounce

    func testDebounceDecisions() {
        let interval = 0.05
        let ms: UInt64 = 1_000_000
        func delay(previous: UInt64?, arrival: UInt64, explicit: Bool = false, interval: TimeInterval = interval) -> TimeInterval {
            CompletionEngine.debounce(interval: interval, isExplicit: explicit, previousArrival: previous, arrival: arrival)
        }
        XCTAssertEqual(delay(previous: nil, arrival: 1_000 * ms), 0, "the first request ever")
        XCTAssertEqual(delay(previous: 1_000 * ms, arrival: 1_049 * ms), interval, "49 ms after the previous: part of a burst")
        XCTAssertEqual(delay(previous: 1_000 * ms, arrival: 1_001 * ms), interval, "the next keystroke of a fast burst")
        XCTAssertEqual(delay(previous: 1_000 * ms, arrival: 1_050 * ms), 0, "exactly one interval after: a pause")
        XCTAssertEqual(delay(previous: 1_000 * ms, arrival: 1_400 * ms), 0, "a long pause")
        XCTAssertEqual(delay(previous: 1_000 * ms, arrival: 1_001 * ms, explicit: true), 0, "an explicit request never waits")
        XCTAssertEqual(delay(previous: 1_000 * ms, arrival: 1_001 * ms, interval: 0), 0, "no debounce configured")
    }

    func testTheFirstRequestAfterAPauseStartsWithoutWaiting() async throws {
        let log = CallLog()
        let engine = CompletionEngine(providers: [RecordingProvider(log: log)], debounceInterval: 5)
        // With a five second debounce, the only way the provider runs within a second is by not waiting.
        _ = try await withTimeout(seconds: 2) { try await engine.complete(context: makeContext(prefix: "f")) }
        let calls = await log.count
        XCTAssertEqual(calls, 1)
    }

    func testAFollowUpWithinTheIntervalWaitsForTheBurstToEnd() async throws {
        let log = CallLog()
        let engine = CompletionEngine(providers: [RecordingProvider(log: log)], debounceInterval: 0.4)
        _ = try await engine.complete(context: makeContext(prefix: "f"))
        let started = DispatchTime.now().uptimeNanoseconds
        _ = try await engine.complete(context: makeContext(prefix: "fo"))
        let waited = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        // A lower bound only: running late cannot fail this, running early can.
        XCTAssertGreaterThanOrEqual(waited, 0.35, "the second keystroke ran after \(waited) s; it should wait out the burst")
        let calls = await log.count
        XCTAssertEqual(calls, 2)
    }

    func testAnExplicitRequestInsideABurstStillStartsAtOnce() async throws {
        let log = CallLog()
        let engine = CompletionEngine(providers: [RecordingProvider(log: log)], debounceInterval: 5)
        _ = try await withTimeout(seconds: 2) { try await engine.complete(context: makeContext(prefix: "f")) }
        _ = try await withTimeout(seconds: 2) { try await engine.complete(context: makeContext(prefix: "fo", trigger: .manual)) }
        let calls = await log.count
        XCTAssertEqual(calls, 2)
    }
}

private actor CallLog {
    private(set) var count = 0
    func note() { count += 1 }
}

private struct RecordingProvider: CompletionProvider {
    let name = "Recording"
    let log: CallLog

    func provide(context: CompletionContext) async -> [CompletionItem] {
        await log.note()
        return []
    }
}

private struct TimedOut: Error, CustomStringConvertible {
    let seconds: TimeInterval
    var description: String { "the request did not start within \(seconds) s" }
}

/// Fails with a timeout instead of hanging, so a request that should have started at once fails the test.
private func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimedOut(seconds: seconds)
        }
        defer { group.cancelAll() }
        return try await group.next()!
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

private func makeContext(prefix: String, trigger: RequestTrigger? = nil) -> CompletionContext {
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
        trigger: trigger ?? .keystroke(prefix),
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