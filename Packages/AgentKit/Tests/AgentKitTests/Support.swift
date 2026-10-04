import Foundation
@testable import AgentKit

/// A transport that replays scripted responses, one per `open` call, and records the requests.
final class StubTransport: LLMTransport, @unchecked Sendable {
    enum Reply {
        case response(status: Int, headers: [String: String] = [:], lines: [String], failure: Error? = nil)
        case failure(Error)
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private var received: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    var requests: [URLRequest] { lock.withLock { received } }

    func open(_ request: URLRequest) async throws -> LLMHTTPResponse {
        let reply: Reply = lock.withLock {
            received.append(request)
            return replies.isEmpty ? .failure(URLError(.badServerResponse)) : replies.removeFirst()
        }
        switch reply {
        case .failure(let error):
            throw error
        case .response(let status, let headers, let lines, let failure):
            let stream = AsyncThrowingStream<String, Error> { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish(throwing: failure)
            }
            return LLMHTTPResponse(status: status, headers: headers, lines: stream)
        }
    }
}

func collect(_ stream: AsyncThrowingStream<LLMEvent, Error>) async throws -> [LLMEvent] {
    var events: [LLMEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

/// Wraps JSON payloads as the `data:` lines `URLSession.bytes(for:).lines` would deliver.
func sse(_ payloads: String...) -> [String] { payloads.map { "data: \($0)" } }

let fastRetry = RetryPolicy(maxRetries: 3, baseDelay: 0.001, maxDelay: 0.01, jitter: false)

/// A response captured from a real server, kept verbatim in `Fixtures/`.
func fixtureLines(_ name: String) throws -> [String] {
    try fixtureText(name).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

func fixtureText(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
    }
    return try String(contentsOf: url, encoding: .utf8)
}

func fixtureData(_ name: String) throws -> Data { Data(try fixtureText(name).utf8) }

/// Answers each request from a closure keyed on its URL, for endpoints that return a whole JSON body.
final class RouteTransport: LLMTransport, @unchecked Sendable {
    typealias Route = @Sendable (URLRequest) throws -> (status: Int, data: Data)
    private let route: Route
    private let lock = NSLock()
    private var received: [URLRequest] = []

    init(_ route: @escaping Route) { self.route = route }

    var requests: [URLRequest] { lock.withLock { received } }

    func open(_ request: URLRequest) async throws -> LLMHTTPResponse {
        let (status, data) = try fetchSync(request)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        return LLMHTTPResponse(status: status, lines: AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }

    func fetch(_ request: URLRequest) async throws -> (status: Int, data: Data) { try fetchSync(request) }

    private func fetchSync(_ request: URLRequest) throws -> (status: Int, data: Data) {
        lock.withLock { received.append(request) }
        return try route(request)
    }
}

/// Feeds captured lines through the framing a client uses and collects the events.
func decode(_ lines: [String], sse: Bool, with decoder: any StreamDecoder) throws -> [LLMEvent] {
    var decoder = decoder
    let parser = SSELineParser()
    var events: [LLMEvent] = []
    for line in lines {
        if sse {
            switch parser.parse(line: line) {
            case .data(let payload): events += try decoder.events(forPayload: payload)
            case .done: events += try decoder.finish()
            case nil: continue
            }
        } else {
            events += try decoder.events(forPayload: line)
        }
    }
    return events
}
