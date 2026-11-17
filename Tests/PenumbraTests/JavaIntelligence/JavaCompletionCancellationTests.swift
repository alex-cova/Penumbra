import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// What a Java completion request does when a newer one replaces it before the provider has started on it.
/// Parsing cannot be interrupted, so the provider checks for cancellation at its door: a request cancelled while
/// it waited (for the debounce, for the provider's actor behind the request that was running) must not parse.
/// The test holds the request at that door with a latch; nothing here depends on how long anything takes.
final class JavaCompletionCancellationTests: XCTestCase {
    func testARequestCancelledBeforeTheProviderStartsNeverParsesAndTheNewerOneAnswers() async throws {
        let corpus = try await JavaCompletionCorpusTests.sharedIndex()
        let text = "package com.acme.cases;\nclass ObsoleteProbe {\n    void test(String name) {\n        na\n    }\n}\n"
        let caret = (text as NSString).range(of: "na\n").location + 2
        let corpusCase = CompletionCorpusRunner.Case(
            name: "ObsoleteProbe", url: URL(fileURLWithPath: "/virtual/ObsoleteProbe.java"),
            text: text, caretUTF16Offset: caret, directives: [:]
        )
        await corpus.index.setOverlay([:])
        let provider = JavaCompletionProvider(index: corpus.index)
        let door = Door()
        provider.setRequestStartHook { await door.arrive() }

        // 1. A request is scheduled and held at the provider's door.
        let obsolete = provider.provideUpdates(context: corpusCase.completionContext())
        let published = ObsoleteRequestUpdates()
        let reader = Task { for await update in obsolete { await published.add(update) } }
        await door.waitUntilArrived(1)

        // 2. A newer keystroke makes it obsolete: its consumer goes away, the stream terminates and cancels it.
        reader.cancel()
        await reader.value
        for _ in 0..<10_000 where provider.terminationCount.withLock({ $0 }) < 1 { await Task.yield() }
        XCTAssertEqual(provider.terminationCount.withLock { $0 }, 1, "cancellation did not reach the request")

        // 3. It is let through the door already cancelled.
        await door.open()
        for _ in 0..<100_000 where await provider.obsoleteRequestSkipCount == 0 { await Task.yield() }

        // 4. It did no work: it never counted as a request, so it never parsed or ran a slow phase.
        let skipped = await provider.obsoleteRequestSkipCount
        let requests = await provider.requestCount
        let slowPhases = await provider.slowPhaseRunCount + provider.slowPhaseSkipCount
        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(requests, 0, "an obsolete request reached the parse")
        XCTAssertEqual(slowPhases, 0)
        // 6. Nothing stale was published.
        let stale = await published.updates
        XCTAssertTrue(stale.isEmpty, "an obsolete request published \(stale.count) update(s)")

        // 5. The newer request runs to completion and answers.
        provider.setRequestStartHook(nil)
        let items = await provider.provide(context: corpusCase.completionContext())
        XCTAssertTrue(items.contains { $0.label == "name" }, "the newer request did not answer")
        let requestsAfter = await provider.requestCount
        let skippedAfter = await provider.obsoleteRequestSkipCount
        XCTAssertEqual(requestsAfter, 1)
        XCTAssertEqual(skippedAfter, 1)
    }
}

private actor ObsoleteRequestUpdates {
    private(set) var updates: [CompletionUpdate] = []
    func add(_ update: CompletionUpdate) { updates.append(update) }
}

/// Holds a request at the provider's door until `open()`, and tells the test when one has arrived.
private actor Door {
    private var arrived = 0
    private var isOpen = false
    private var passengers: [CheckedContinuation<Void, Never>] = []
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func arrive() async {
        arrived += 1
        let ready = watchers.filter { $0.count <= arrived }
        watchers.removeAll { $0.count <= arrived }
        for watcher in ready { watcher.continuation.resume() }
        if isOpen { return }
        await withCheckedContinuation { passengers.append($0) }
    }

    func waitUntilArrived(_ count: Int) async {
        if arrived >= count { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    func open() {
        isOpen = true
        let waiting = passengers
        passengers = []
        for passenger in waiting { passenger.resume() }
    }
}
