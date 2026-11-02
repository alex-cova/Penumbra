import Foundation

/// An `ACPTransport` over streamable HTTP, for hosted MCP servers that take a Bearer [REDACTED] or other
/// headers. One JSON-RPC message (or batch) is POSTed; the reply is a single JSON message, a batch
/// array, or a `text/event-stream` body whose `data:` payloads are the messages. A 202 with an empty
/// body acknowledges a notification and yields nothing.
///
/// The endpoint's host is fixed by the configuration: a redirect to another host is refused rather
/// than followed, so an `Authorization` header never leaks to a host the user did not name. Same-host
/// redirects (and an http-to-https upgrade) are followed, at most `maxRedirects`.
///
/// Failures throw `ACPError.agentError`, which `MCPClient` carries as `MCPError.server`, so the
/// reason reaches the host instead of a bare "the server has stopped".
public final class MCPHTTPTransport: ACPTransport, @unchecked Sendable {
    /// Where an OAuth token comes from, when the host has one (Umbra: the Keychain, after the
    /// `ASWebAuthenticationSession` flow). Fills `Authorization` only when the configured headers do
    /// not already set it, and a 401 is retried once with a fresh token.
    public typealias TokenProvider = @Sendable () async -> String?

    /// A response header is kept lowercased by `URLSession`; `mcp-session-id` is read that way.
    static let sessionIDHeader = "mcp-session-id"
    /// A body larger than this is a protocol failure, not a message (10 MiB, like `ACPConnection`).
    static let maxBodyBytes = 10 * 1024 * 1024
    static let maxRedirects = 5

    private let endpoint: URL
    private let headers: [String: String]
    private let tokenProvider: TokenProvider?
    private let session: URLSession
    private let ownsSession: Bool

    private let lock = NSLock()
    private var sessionID: String?
    private var continuation: AsyncStream<Data>.Continuation?
    private var closedFlag = false

    public let incoming: AsyncStream<Data>

    public init(url: URL, headers: [String: String] = [:], tokenProvider: TokenProvider? = nil, session: URLSession? = nil) {
        self.endpoint = url
        self.headers = headers
        self.tokenProvider = tokenProvider
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration, delegate: MCPNoRedirects(), delegateQueue: nil)
            self.ownsSession = true
        }
        var captured: AsyncStream<Data>.Continuation?
        incoming = AsyncStream<Data> { captured = $0 }
        continuation = captured
    }

    public func send(_ line: Data) async throws {
        let closed: Bool = lock.withLock { closedFlag }
        if closed { throw ACPError.transportClosed }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = line
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if let id: String = lock.withLock({ sessionID }) { request.setValue(id, forHTTPHeaderField: "Mcp-Session-Id") }
        if request.value(forHTTPHeaderField: "Authorization") == nil, let token = await tokenProvider?() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (status, responseHeaders, body) = try await post(request, retriesLeft: Self.maxRedirects, tokenRetriesLeft: 1)
        if let id = responseHeaders[Self.sessionIDHeader], !id.isEmpty { lock.withLock { sessionID = id } }
        guard (200..<300).contains(status) else {
            throw ACPError.agentError(JSONRPCError(
                code: status, message: "The MCP server answered \(status): \(String(decoding: body.prefix(300), as: UTF8.self))"))
        }
        for message in Self.messages(from: body, contentType: responseHeaders["content-type"]) {
            var frame = message
            if !frame.isEmpty, frame.last != UInt8(ascii: "\n") { frame.append(UInt8(ascii: "\n")) }
            lock.withLock { continuation }?.yield(frame)
        }
    }

    public func close() async {
        let (continuation, sessionID, endpoint, session, ownsSession): (
            AsyncStream<Data>.Continuation?, String?, URL, URLSession, Bool
        ) = lock.withLock {
            let captured = continuation
            continuation = nil
            let wasClosed = closedFlag
            closedFlag = true
            return (captured, sessionID, endpoint, session, ownsSession && !wasClosed)
        }
        // Best effort: tell a stateful server the session is over. A 404 (no such session) is fine.
        if let sessionID {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "DELETE"
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            _ = try? await session.data(for: request)
        }
        continuation?.finish()
        if ownsSession { session.finishTasksAndInvalidate() }
    }

    // MARK: - POST with redirect and auth handling

    private func post(_ request: URLRequest, retriesLeft: Int, tokenRetriesLeft: Int) async throws -> (
        status: Int, headers: [String: String], body: Data
    ) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ACPError.agentError(JSONRPCError(code: error.errorCode, message: "Could not reach the MCP server: \(error.localizedDescription)"))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ACPError.agentError(JSONRPCError(code: -32000, message: "The MCP server's response was not HTTP."))
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        if data.count > Self.maxBodyBytes {
            throw ACPError.agentError(JSONRPCError(code: -32000, message: "The MCP server sent more than \(Self.maxBodyBytes) bytes."))
        }
        switch http.statusCode {
        case 300..<400:
            guard retriesLeft > 0 else {
                throw ACPError.agentError(JSONRPCError(code: -32000, message: "The MCP server redirected too many times."))
            }
            guard let location = headers["location"], let target = URL(string: location, relativeTo: request.url)?.absoluteURL else {
                throw ACPError.agentError(JSONRPCError(code: http.statusCode, message: "The MCP server redirected without a location."))
            }
            guard Self.isSameHost(target, request.url) && Self.isUpgrade(request.url, target) else {
                throw ACPError.agentError(JSONRPCError(
                    code: -32000,
                    message: "The MCP server redirected to \(target.host ?? "?"), which is outside its configured address, so the request was not followed."))
            }
            var next = request
            next.url = target
            return try await post(next, retriesLeft: retriesLeft - 1, tokenRetriesLeft: tokenRetriesLeft)
        case 401 where tokenRetriesLeft > 0 && tokenProvider != nil:
            var next = request
            if let token = await tokenProvider?() { next.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            return try await post(next, retriesLeft: retriesLeft, tokenRetriesLeft: 0)
        default:
            return (http.statusCode, headers, data)
        }
    }

    static func isSameHost(_ a: URL?, _ b: URL?) -> Bool {
        a?.host?.lowercased() == b?.host?.lowercased()
    }

    /// Same scheme, or an http-to-https upgrade. A downgrade is never followed with credentials.
    static func isUpgrade(_ from: URL?, _ to: URL) -> Bool {
        let old = from?.scheme?.lowercased(), new = to.scheme?.lowercased()
        return old == new || (old == "http" && new == "https")
    }

    // MARK: - Framing

    /// Splits one response body into JSON-RPC message frames: a single message, a batch array, or
    /// the `data:` payloads of a server-sent-events body.
    static func messages(from body: Data, contentType: String?) -> [Data] {
        let trimmed = body.drop(while: { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") })
        guard !trimmed.isEmpty else { return [] }
        if trimmed.first == UInt8(ascii: "[") {
            guard let array = try? JSONDecoder().decode([JSONValue].self, from: body) else { return [] }
            return array.compactMap { (try? $0.serialized()).map { Data($0.utf8) } }
        }
        if trimmed.first == UInt8(ascii: "{") {
            return [Data(trimmed)]
        }
        // Anything else is treated as SSE: one JSON message per `data:` payload, `data:` lines of one
        // event joined with newlines, comments and other fields ignored.
        return ssePayloads(body)
    }

    static func ssePayloads(_ body: Data) -> [Data] {
        var payloads: [Data] = []
        var current = Data()
        var hasData = false
        let text = String(decoding: body, as: UTF8.self)
        text.enumerateLines { line, _ in
            if line.isEmpty {
                if hasData { payloads.append(current) }
                current = Data()
                hasData = false
            } else if line.hasPrefix(":") {
                return // comment or SSE `id:`/`event:`/`retry:` line
            } else if line.hasPrefix("data:") {
                var payload = line.dropFirst("data:".count)
                if payload.first == " " { payload = payload.dropFirst() }
                if hasData { current.append(UInt8(ascii: "\n")) }
                current += Data(payload.utf8)
                hasData = true
            }
        }
        if hasData { payloads.append(current) }
        return payloads
    }
}

/// Answers every redirect with "do not follow", so the 3xx response comes back and the transport
/// itself decides whether the target is safe.
private final class MCPNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
