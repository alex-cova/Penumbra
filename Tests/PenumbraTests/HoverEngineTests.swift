import XCTest
import EditorIntelligence

final class HoverEngineTests: XCTestCase {
    func testReturnsFirstProviderResult() async {
        let first = MockHoverProvider(name: "First", result: HoverResult(contents: "first", source: "First"))
        let second = MockHoverProvider(name: "Second", result: HoverResult(contents: "second", source: "Second"))
        let engine = HoverEngine(providers: [first, second])
        let context = makeHoverContext(text: "foo", offset: 0)
        let result = await engine.hover(context: context)
        XCTAssertEqual(result?.contents, "first")
    }

    /// Priority is list order: a quick generic answer must not beat a richer provider listed
    /// ahead of it when that provider answers inside the grace period.
    func testHigherPriorityAnswerWinsOverFasterLowerPriorityOne() async {
        let rich = MockHoverProvider(
            name: "Rich",
            result: HoverResult(contents: "rich", source: "Rich"),
            delay: .milliseconds(100)
        )
        let quick = MockHoverProvider(name: "Quick", result: HoverResult(contents: "quick", source: "Quick"))
        let engine = HoverEngine(providers: [rich, quick], priorityGrace: .seconds(10))
        let result = await engine.hover(context: makeHoverContext(text: "foo", offset: 0))
        XCTAssertEqual(result?.contents, "rich")
    }

    func testHigherPriorityNilFallsThroughWithoutWaitingForGrace() async {
        let empty = MockHoverProvider(name: "Empty", result: nil)
        let quick = MockHoverProvider(name: "Quick", result: HoverResult(contents: "quick", source: "Quick"))
        let engine = HoverEngine(providers: [empty, quick], priorityGrace: .seconds(30))
        let started = ContinuousClock.now
        let result = await engine.hover(context: makeHoverContext(text: "foo", offset: 0))
        XCTAssertEqual(result?.contents, "quick")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testStalledHigherPriorityProviderIsNotWaitedForPastTheGracePeriod() async {
        let slow = MockHoverProvider(
            name: "Slow",
            result: HoverResult(contents: "slow", source: "Slow"),
            delay: .seconds(30)
        )
        let fast = MockHoverProvider(name: "Fast", result: HoverResult(contents: "fast", source: "Fast"))
        let engine = HoverEngine(providers: [slow, fast], priorityGrace: .milliseconds(50))
        let started = ContinuousClock.now
        let result = await engine.hover(context: makeHoverContext(text: "foo", offset: 0))
        XCTAssertEqual(result?.contents, "fast")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        // The stalled provider is cancelled once the answer is chosen.
        // Cancellation is delivered as the engine returns; the provider records it a moment later.
        var cancelled = false
        for _ in 0..<50 where !cancelled {
            cancelled = await slow.wasCancelled
            if !cancelled { try? await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertTrue(cancelled)
    }

    func testStalledNilProviderDoesNotBlockResultPastTheGracePeriod() async {
        let slowNil = MockHoverProvider(name: "SlowNil", result: nil, delay: .seconds(30))
        let fast = MockHoverProvider(name: "Fast", result: HoverResult(contents: "fast", source: "Fast"))
        let engine = HoverEngine(providers: [slowNil, fast], priorityGrace: .milliseconds(50))
        let result = await engine.hover(context: makeHoverContext(text: "foo", offset: 0))
        XCTAssertEqual(result?.contents, "fast")
    }

    func testProviderThatIgnoresCancellationDoesNotHoldTheAnswer() async {
        let stuck = UncooperativeHoverProvider(seconds: 3)
        let fast = MockHoverProvider(name: "Fast", result: HoverResult(contents: "fast", source: "Fast"))
        let engine = HoverEngine(providers: [stuck, fast], priorityGrace: .milliseconds(50))
        let started = ContinuousClock.now
        let result = await engine.hover(context: makeHoverContext(text: "foo", offset: 0))
        XCTAssertEqual(result?.contents, "fast")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
    }

    func testReturnsNilWhenAllProvidersReturnNil() async {
        let engine = HoverEngine(providers: [
            MockHoverProvider(name: "A", result: nil),
            MockHoverProvider(name: "B", result: nil),
        ])
        let result = await engine.hover(context: makeHoverContext(text: "foo", offset: 0))
        XCTAssertNil(result)
    }

    func testReturnsNilWhenNoProviderMatches() async {
        let engine = HoverEngine(providers: [])
        let context = makeHoverContext(text: "foo", offset: 0)
        let result = await engine.hover(context: context)
        XCTAssertNil(result)
    }

    func testCachesResult() async {
        let provider = MockHoverProvider(name: "Counted", result: HoverResult(contents: "cached", source: "Counted"))
        let engine = HoverEngine(providers: [provider], cacheMaxSize: 100)
        let context = makeHoverContext(text: "foo", offset: 0)
        _ = await engine.hover(context: context)
        _ = await engine.hover(context: context)
        let count = await provider.callCount
        XCTAssertEqual(count, 1)
    }

    func testCacheEvictsLeastRecentlyUsed() async {
        let provider = MockHoverProvider(name: "Counted", result: HoverResult(contents: "cached", source: "Counted"))
        let engine = HoverEngine(providers: [provider], cacheMaxSize: 2)
        let documentID = DocumentID()
        _ = await engine.hover(context: makeHoverContext(text: "foo", offset: 0, documentID: documentID))
        _ = await engine.hover(context: makeHoverContext(text: "foo", offset: 1, documentID: documentID))
        _ = await engine.hover(context: makeHoverContext(text: "foo", offset: 0, documentID: documentID))
        _ = await engine.hover(context: makeHoverContext(text: "foo", offset: 2, documentID: documentID))
        _ = await engine.hover(context: makeHoverContext(text: "foo", offset: 0, documentID: documentID))
        _ = await engine.hover(context: makeHoverContext(text: "foo", offset: 1, documentID: documentID))
        let count = await provider.callCount
        XCTAssertEqual(count, 4)
    }
}

/// Waits on a dispatch timer, so cancelling its task does not end the wait.
private struct UncooperativeHoverProvider: HoverProvider {
    let seconds: Double
    let name = "Uncooperative"

    func provide(context: HoverContext) async -> HoverResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
        return HoverResult(contents: "stuck", source: "Stuck")
    }
}

private actor MockHoverProvider: HoverProvider {
    let name: String
    let result: HoverResult?
    let delay: Duration?
    var callCount = 0
    var wasCancelled = false

    init(name: String, result: HoverResult?, delay: Duration? = nil) {
        self.name = name
        self.result = result
        self.delay = delay
    }

    func provide(context: HoverContext) async -> HoverResult? {
        callCount += 1
        if let delay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                wasCancelled = true
                return nil
            }
        }
        return result
    }
}

private func makeHoverContext(text: String, offset: Int, documentID: DocumentID = DocumentID()) -> HoverContext {
    let snapshot = TextSnapshot(version: 0, text: text)
    let position = TextPosition(line: 0, column: offset, utf16Offset: offset)
    let document = Document(
        id: documentID,
        url: nil,
        displayName: "test",
        contentSnapshot: snapshot,
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 100, height: 100)
    )
    return HoverContext(
        document: document,
        cursor: Cursor(position: position),
        selection: Selection(range: TextRange(start: position, end: position))
    )
}
