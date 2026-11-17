import XCTest
@_spi(Benchmarks) import EditorIntelligence

/// The completion engine's debounce, driven by a clock the test moves. A request that is followed by another one
/// inside the debounce is cancelled while it waits, so it never reaches a provider (for Java, never parses); only
/// the newest runs, and only when the clock passes the debounce. No wall time is involved.
final class CompletionDebounceDeterminismTests: XCTestCase {
    func testRequestsInsideABurstNeverReachTheProvidersAndTheNewestRunsWhenTheClockMoves() async throws {
        let clock = ManualDebounceTimer()
        let provider = RecordingProvider()
        let engine = CompletionEngine(providers: [provider], debounceInterval: 0.05, timer: clock.timer)

        // The first request after a pause starts at once: nothing to coalesce it with.
        let opening = try await engine.complete(context: Self.context("a"))
        XCTAssertEqual(opening.map(\.label), ["a-item"])
        XCTAssertEqual(provider.prefixes, ["a"])

        // A burst under a frozen clock. Streams are requested in order, so "newest" is well defined.
        var streams: [AsyncThrowingStream<CompletionUpdate, Error>] = []
        for index in 0..<20 { streams.append(await engine.completeUpdates(context: Self.context("b\(index)"))) }
        let outcomes = streams.map { stream in Task { await Self.drain(stream) } }

        // Only the newest request still waits for the clock; the other 19 were cancelled while they slept.
        for _ in 0..<10_000 where clock.pendingSleeperCount != 1 { await Task.yield() }
        XCTAssertEqual(clock.pendingSleeperCount, 1)
        XCTAssertEqual(provider.prefixes, ["a"], "a request inside the burst reached a provider")

        clock.advance(by: 0.05)
        var results: [Drained] = []
        for outcome in outcomes { results.append(await outcome.value) }

        XCTAssertEqual(provider.prefixes, ["a", "b19"], "exactly the newest request ran")
        for stale in results.dropLast() {
            XCTAssertTrue(stale.updates.isEmpty, "a cancelled request published \(stale.updates.count) update(s)")
            XCTAssertTrue(stale.error is CancellationError, "a cancelled request ended with \(String(describing: stale.error))")
        }
        let newest = try XCTUnwrap(results.last)
        XCTAssertNil(newest.error)
        XCTAssertEqual(newest.updates.last?.items.map(\.label), ["b19-item"])
        XCTAssertEqual(clock.pendingSleeperCount, 0)
    }

    /// A pause longer than the debounce makes the next request a first one again: it does not wait.
    func testARequestAfterAPauseStartsWithoutWaiting() async throws {
        let clock = ManualDebounceTimer()
        let provider = RecordingProvider()
        let engine = CompletionEngine(providers: [provider], debounceInterval: 0.05, timer: clock.timer)
        _ = try await engine.complete(context: Self.context("a"))
        clock.advance(by: 0.06)
        let items = try await engine.complete(context: Self.context("b"))
        XCTAssertEqual(items.map(\.label), ["b-item"])
        XCTAssertEqual(provider.prefixes, ["a", "b"])
    }

    // MARK: - Helpers

    private struct Drained {
        var updates: [CompletionUpdate]
        var error: Error?
    }

    private static func drain(_ stream: AsyncThrowingStream<CompletionUpdate, Error>) async -> Drained {
        var drained = Drained(updates: [])
        do {
            for try await update in stream { drained.updates.append(update) }
        } catch {
            drained.error = error
        }
        return drained
    }

    private static func context(_ prefix: String) -> CompletionContext {
        let position = TextPosition(line: 0, column: prefix.count, utf16Offset: prefix.count)
        let document = Document(
            id: DocumentID(), url: nil, displayName: "test",
            contentSnapshot: TextSnapshot(version: 0, text: prefix),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100)
        )
        return CompletionContext(
            document: document, cursor: Cursor(position: position), trigger: .keystroke(prefix),
            prefix: prefix, range: TextRange(start: position, end: position)
        )
    }
}

private final class RecordingProvider: CompletionProvider, @unchecked Sendable {
    let name = "Recording"
    private let lock = NSLock()
    private var seen: [String] = []

    var prefixes: [String] { lock.withLock { seen } }

    func provide(context: CompletionContext) async -> [CompletionItem] {
        lock.withLock { seen.append(context.prefix) }
        return [CompletionItem(
            label: "\(context.prefix)-item", insertText: "\(context.prefix)-item", kind: .method,
            range: context.range, source: name
        )]
    }
}
