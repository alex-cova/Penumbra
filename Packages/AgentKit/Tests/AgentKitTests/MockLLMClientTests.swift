import Foundation
import Testing
@testable import AgentKit

@Suite struct MockLLMClientTests {
    private let request = LLMRequest(model: "m", items: [.user("hi")])

    @Test func replaysScriptedTurnsInOrderAndRecordsRequests() async throws {
        let mock = MockLLMClient(turns: [
            .toolCalls((id: "c1", name: "read_file", arguments: "{}")),
            .text("done"),
        ])
        let first = try await collect(mock.stream(request))
        #expect(first == [
            .toolCallStarted(id: "c1", name: "read_file"),
            .toolCallFinished(id: "c1", name: "read_file", arguments: "{}"),
            .finished(.toolCalls),
        ])
        let second = try await collect(mock.stream(LLMRequest(model: "m2", items: [])))
        #expect(second == [.textDelta("done"), .finished(.completed)])
        #expect(mock.requests.map(\.model) == ["m", "m2"])
    }

    @Test func aFailingTurnEmitsItsEventsThenThrows() async {
        let mock = MockLLMClient(turns: [MockTurn([.textDelta("par")], failure: .connectionLost("x"))])
        var received: [LLMEvent] = []
        do {
            for try await event in mock.stream(request) { received.append(event) }
            Issue.record("expected a failure")
        } catch {
            #expect(error as? LLMError == .connectionLost("x"))
        }
        #expect(received == [.textDelta("par")])
    }

    @Test func runningOutOfTurnsIsAnError() async {
        let mock = MockLLMClient(turns: [])
        await #expect(throws: LLMError.self) { _ = try await collect(mock.stream(request)) }
    }

    @Test func cancellingMidStreamStopsTheScript() async throws {
        let events = (0..<50).map { LLMEvent.textDelta("\($0)") }
        let mock = MockLLMClient(turns: [MockTurn(events, delayPerEvent: .milliseconds(20))])
        let task = Task { () -> Int in
            var count = 0
            do { for try await _ in mock.stream(request) { count += 1 } } catch {}
            return count
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(await task.value < 50)
    }
}
