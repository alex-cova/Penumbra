import Foundation

/// Turns the payloads of one streamed response into `LLMEvent`s. A decoder is created per attempt
/// and holds the state a stream needs (which call an argument fragment belongs to).
public protocol StreamDecoder: Sendable {
    /// One `data:` payload (SSE) or one line (NDJSON). Throws for an error event.
    mutating func events(forPayload payload: String) throws -> [LLMEvent]
    /// The server said the stream is over (`[DONE]`): emit whatever was held back, ending in `.finished`.
    mutating func finish() throws -> [LLMEvent]
    /// The response is complete even if the server never sent an end marker.
    var isComplete: Bool { get }
}

extension StreamDecoder {
    public mutating func finish() throws -> [LLMEvent] { [] }
    public var isComplete: Bool { false }
}

public enum StreamFraming: Sendable {
    /// `data: {json}` lines, `[DONE]` at the end.
    case sse
    /// One JSON object per line.
    case ndjson
}

/// The part every HTTP-streaming client shares: send, check the status, frame the lines, retry what
/// is worth retrying with backoff (telling the consumer to drop the partial turn), and never end a
/// stream that stopped before the response was complete as if it had finished.
struct HTTPStreamClient: Sendable {
    let transport: any LLMTransport
    let retry: RetryPolicy
    let framing: StreamFraming
    let makeRequest: @Sendable () throws -> URLRequest
    let makeDecoder: @Sendable () -> any StreamDecoder

    func stream() -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                while true {
                    do {
                        try await run(into: continuation)
                        continuation.finish()
                        return
                    } catch {
                        if Task.isCancelled || error is CancellationError {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        let error = Self.normalized(error)
                        guard let delay = retry.delay(for: error, attempt: attempt) else {
                            continuation.finish(throwing: error)
                            return
                        }
                        attempt += 1
                        continuation.yield(.retrying(attempt: attempt, after: delay))
                        do { try await Task.sleep(for: .seconds(delay)) } catch {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
        let response = try await transport.open(try makeRequest())

        guard (200..<300).contains(response.status) else {
            var text = ""
            for try await line in response.lines where text.count < 8_192 { text += line + "\n" }
            throw HTTPErrorClassifier.classify(
                status: response.status, body: text,
                retryAfter: HTTPErrorClassifier.retryAfter(from: response.headers))
        }

        let parser = SSELineParser()
        var decoder = makeDecoder()
        var finished = false

        func emit(_ events: [LLMEvent]) {
            for event in events {
                if case .finished = event { finished = true }
                continuation.yield(event)
            }
        }

        for try await line in response.lines {
            switch framing {
            case .sse:
                switch parser.parse(line: line) {
                case .data(let payload): emit(try decoder.events(forPayload: payload))
                case .done: emit(try decoder.finish())
                case nil: continue
                }
            case .ndjson:
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                emit(try decoder.events(forPayload: trimmed))
            }
            if finished { return }
        }
        // Some servers end the stream after the last chunk without a marker.
        if !finished, decoder.isComplete { emit(try decoder.finish()) }
        if !finished { throw LLMError.connectionLost("The stream ended before the response completed.") }
    }

    /// Callers only deal in `LLMError`. A server that isn't there is not worth retrying; a dropped
    /// connection is.
    static func normalized(_ error: Error) -> Error {
        guard let error = error as? URLError else { return error }
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            let host = error.failingURL?.host() ?? "the server"
            return LLMError.unreachable("Could not connect to \(host).")
        default:
            return LLMError.connectionLost(error.localizedDescription)
        }
    }
}
