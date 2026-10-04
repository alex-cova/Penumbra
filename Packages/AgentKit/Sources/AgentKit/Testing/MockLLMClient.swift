import Foundation

/// One scripted model turn for `MockLLMClient`.
public struct MockTurn: Sendable {
    public var events: [LLMEvent]
    /// Thrown after the events, as a stream that fails mid-turn.
    public var failure: LLMError?
    /// Pause before each event, so a test can cancel mid-stream.
    public var delayPerEvent: Duration?

    public init(_ events: [LLMEvent], failure: LLMError? = nil, delayPerEvent: Duration? = nil) {
        self.events = events
        self.failure = failure
        self.delayPerEvent = delayPerEvent
    }

    public static func text(_ text: String) -> MockTurn {
        MockTurn([.textDelta(text), .finished(.completed)])
    }

    public static func toolCalls(_ calls: (id: String, name: String, arguments: String)...) -> MockTurn {
        var events: [LLMEvent] = []
        for call in calls {
            events.append(.toolCallStarted(id: call.id, name: call.name))
            events.append(.toolCallFinished(id: call.id, name: call.name, arguments: call.arguments))
        }
        events.append(.finished(.toolCalls))
        return MockTurn(events)
    }
}

/// Replays scripted turns, one per `stream` call, and records the requests it received.
public final class MockLLMClient: LLMClient, @unchecked Sendable {
    public let providerID: String
    private let lock = NSLock()
    private var turns: [MockTurn]
    private var received: [LLMRequest] = []

    public init(providerID: String = "mock", turns: [MockTurn]) {
        self.providerID = providerID
        self.turns = turns
    }

    public var requests: [LLMRequest] {
        lock.withLock { received }
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let turn: MockTurn? = lock.withLock {
            received.append(request)
            return turns.isEmpty ? nil : turns.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let turn else {
                    continuation.finish(throwing: LLMError.api(message: "MockLLMClient has no scripted turn left.", code: nil))
                    return
                }
                for event in turn.events {
                    if let delay = turn.delayPerEvent {
                        do { try await Task.sleep(for: delay) } catch {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                    }
                    continuation.yield(event)
                }
                continuation.finish(throwing: turn.failure)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
