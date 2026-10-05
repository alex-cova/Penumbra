import Foundation

public struct LLMHTTPResponse: Sendable {
    public let status: Int
    /// Header names lowercased.
    public let headers: [String: String]
    public let lines: AsyncThrowingStream<String, Error>

    public init(status: Int, headers: [String: String] = [:], lines: AsyncThrowingStream<String, Error>) {
        self.status = status
        self.headers = headers
        self.lines = lines
    }
}

/// The network seam, so clients are tested without a network.
public protocol LLMTransport: Sendable {
    /// A streamed response, line by line.
    func open(_ request: URLRequest) async throws -> LLMHTTPResponse
    /// A whole response body, for JSON endpoints such as a model list.
    func fetch(_ request: URLRequest) async throws -> (status: Int, data: Data)
    /// Like `fetch`, plus response headers (lowercased names). A client that retries on `Retry-After` uses this.
    func fetchResponse(_ request: URLRequest) async throws -> (status: Int, headers: [String: String], data: Data)
}

extension LLMTransport {
    public func fetch(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        let response = try await open(request)
        var text = ""
        for try await line in response.lines { text += line + "\n" }
        return (response.status, Data(text.utf8))
    }

    public func fetchResponse(_ request: URLRequest) async throws -> (status: Int, headers: [String: String], data: Data) {
        let (status, data) = try await fetch(request)
        return (status, [:], data)
    }
}

public struct URLSessionTransport: LLMTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.malformedEvent("The response was not HTTP.") }
        return (http.statusCode, data)
    }

    public func open(_ request: URLRequest) async throws -> LLMHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.malformedEvent("The response was not HTTP.")
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        // `AsyncLineSequence` drops empty lines, which is fine: each `data:` line is one event.
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancelling the task ends the byte loop, which closes the connection.
            continuation.onTermination = { _ in task.cancel() }
        }
        return LLMHTTPResponse(status: http.statusCode, headers: headers, lines: lines)
    }
}
