import Foundation
import Testing
@testable import AgentKit

/// Retry Now: a wait between attempts that the user can end early.
@Suite struct RetryWakerTests {
    @Test func wakeEndsTheWaitEarly() async throws {
        let waker = RetryWaker()
        #expect(!waker.wake(), "nothing is waiting yet")
        let start = ContinuousClock.now
        let wait = Task { try await waker.sleep(for: 30) }
        while !waker.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        #expect(waker.wake())
        try await wait.value
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(!waker.isWaiting)
    }

    @Test func theWaitEndsOnItsOwnWhenNobodyWakesIt() async throws {
        let waker = RetryWaker()
        let start = ContinuousClock.now
        try await waker.sleep(for: 0.05)
        #expect(ContinuousClock.now - start >= .milliseconds(45))
        #expect(!waker.isWaiting)
    }

    @Test func cancellingTheWaitThrowsAtOnce() async throws {
        let waker = RetryWaker()
        let start = ContinuousClock.now
        let wait = Task { try await waker.sleep(for: 30) }
        while !waker.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        wait.cancel()
        await #expect(throws: CancellationError.self) { try await wait.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func aTaskCancelledBeforeItWaitsDoesNotHang() async throws {
        let waker = RetryWaker()
        let wait = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await waker.sleep(for: 30)
        }
        await #expect(throws: CancellationError.self) { try await wait.value }
    }

    /// The session's `retryNow()` reaches the client's wait: a 30 s Retry-After is cut short and the
    /// resent request completes the run.
    @Test func retryNowSendsTheFailedRequestAgainWithoutWaiting() async throws {
        let done = #"data: {"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":1}}}"#
        let transport = StubTransport([
            .response(status: 429, headers: ["retry-after": "30"], lines: [#"{"error":{"message":"slow down"}}"#]),
            .response(status: 200, lines: [#"data: {"type":"response.output_text.delta","delta":"Hello"}"#, done]),
        ])
        let client = OpenAIResponsesClient.meta(
            transport: transport, retry: RetryPolicy(maxRetries: 2, baseDelay: 30, maxDelay: 30, jitter: false))
        let session = AgentSession(
            client: client, tools: [], workspace: try TempProject().workspace, configuration: AgentConfiguration(model: "m"))

        let start = ContinuousClock.now
        var delay: TimeInterval?
        var ending: RunEnding?
        for await event in await session.send("hi") {
            switch event {
            case .retryScheduled(_, let wait):
                delay = wait
                // The client starts waiting just after it reports the retry.
                var woke = false
                for _ in 0..<200 where !woke {
                    woke = session.retryNow()
                    if !woke { try await Task.sleep(for: .milliseconds(5)) }
                }
                #expect(woke)
            case .runEnded(let end):
                ending = end
            default:
                break
            }
        }
        #expect(delay == 30)
        #expect(ending == .completed)
        #expect(transport.requests.count == 2)
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(!session.retryNow(), "nothing waits once the run is over")
    }
}
