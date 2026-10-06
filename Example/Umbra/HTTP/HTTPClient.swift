import Foundation

struct HTTPResponseLog: Sendable {
    enum Line: Sendable {
        case note(String)
        /// The request as it is sent, after variables are substituted.
        case request(String)
        case response(String)
        case error(String)
        case savedFile(URL)

        var text: String {
            switch self {
            case .note(let text), .request(let text), .response(let text), .error(let text):
                return text
            case .savedFile(let url):
                return "Saved response to \(url.path)"
            }
        }
    }

    static let maxLines = 10_000

    private(set) var lines: [Line] = []
    private(set) var runID = UUID()
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var statusCode: Int?
    private(set) var duration: TimeInterval?

    init() {}

    var latestLine: String? {
        lines.last?.text
    }

    mutating func reset() {
        lines = []
        runID = UUID()
        startedAt = Date()
        finishedAt = nil
        statusCode = nil
        duration = nil
    }

    mutating func appendNote(_ text: String) {
        append(.note(text))
    }

    mutating func appendRequest(_ text: String) {
        append(.request(text))
    }

    mutating func appendResponse(_ text: String) {
        append(.response(text))
    }

    mutating func appendSavedFile(_ url: URL) {
        append(.savedFile(url))
    }

    mutating func appendError(_ text: String) {
        append(.error(text))
    }

    mutating func markFinished(statusCode: Int?, duration: TimeInterval) {
        self.statusCode = statusCode
        self.duration = duration
        finishedAt = Date()
        appendNote(String(format: "Completed in %.0f ms", duration * 1000))
    }

    private mutating func append(_ line: Line) {
        lines.append(line)
        guard lines.count > Self.maxLines else { return }
        lines.removeFirst(lines.count - Self.maxLines)
    }
}

enum HTTPClientError: Error, LocalizedError {
    case invalidResponse
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an invalid HTTP response."
        case .transport(let error):
            return error.localizedDescription
        }
    }
}

enum HTTPRedirectPolicy {
    static func proposedRequest(followRedirects: Bool, request: URLRequest) -> URLRequest? {
        followRedirects ? request : nil
    }
}

enum HTTPClient {
    static let requestTimeout: TimeInterval = 30

    /// `session` nil builds an ephemeral session for this call. A session passed in (tests) is used as-is.
    /// Digest credentials retry once after a 401 challenge. `cnonce` is injectable for the RFC vector.
    static func send(
        _ request: HTTPPreparedRequest,
        session: URLSession? = nil,
        cookies: HTTPCookieJar? = nil,
        cnonce: String? = nil
    ) async throws -> (HTTPURLResponse, Data) {
        let ownsSession = session == nil
        let active = session ?? makeSession(options: request.options, cookies: cookies)
        defer {
            if ownsSession {
                active.finishTasksAndInvalidate()
            }
        }

        var urlRequest = makeURLRequest(request)
        do {
            let (response, data) = try await perform(urlRequest, session: active)
            guard let login = request.digest,
                  response.statusCode == 401,
                  let header = response.value(forHTTPHeaderField: "WWW-Authenticate"),
                  let challenge = HTTPDigest.parse(header),
                  let authorization = HTTPDigest.authorization(
                    username: login.username,
                    password: login.password,
                    method: request.method,
                    uri: HTTPDigest.uri(for: request.url),
                    challenge: challenge,
                    nc: "00000001",
                    cnonce: cnonce ?? HTTPDigest.randomCnonce()
                  ) else {
                return (response, data)
            }
            urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
            return try await perform(urlRequest, session: active)
        } catch let error as HTTPClientError {
            throw error
        } catch {
            throw HTTPClientError.transport(error)
        }
    }

    static func makeSession(options: HTTPRequestOptions, cookies: HTTPCookieJar?) -> URLSession {
        let configuration = configuration(for: options, cookies: cookies)
        let delegate = HTTPSessionDelegate(followRedirects: options.followRedirects)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    static func configuration(for options: HTTPRequestOptions, cookies: HTTPCookieJar?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.httpShouldSetCookies = options.useCookieJar
        configuration.httpCookieAcceptPolicy = options.useCookieJar ? .always : .never
        configuration.httpCookieStorage = options.useCookieJar ? (cookies?.storage ?? HTTPCookieStorage()) : nil
        return configuration
    }

    private static func makeURLRequest(_ request: HTTPPreparedRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: requestTimeout)
        urlRequest.httpMethod = request.method
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body
        return urlRequest
    }

    private static func perform(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        return (httpResponse, data)
    }

    /// The request the way the log shows it: request line, headers, then the body. Headers are
    /// the ones set on the request; the client adds its own (`User-Agent`, cookies) when sending.
    static func formatRequest(_ request: HTTPPreparedRequest) -> String {
        var lines = ["\(request.method) \(request.url.absoluteString)"]
        for (key, value) in request.headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            lines.append("\(key): \(value)")
        }
        if let body = request.body, !body.isEmpty {
            lines.append("")
            lines.append(String(data: body, encoding: .utf8) ?? "<\(body.count) bytes of binary data>")
        }
        // The trailing blank line separates the request from the response that follows.
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func formatResponse(_ response: HTTPURLResponse, data: Data) -> String {
        var lines: [String] = []
        let version = "HTTP/1.1"
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        lines.append("\(version) \(response.statusCode) \(reason)")

        for (key, value) in response.allHeaderFields.sorted(by: { String(describing: $0.key) < String(describing: $1.key) }) {
            lines.append("\(key): \(value)")
        }

        lines.append("")

        if data.isEmpty {
            return lines.joined(separator: "\n")
        }

        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        if let contentType,
           contentType.lowercased().contains("json"),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let prettyText = String(data: pretty, encoding: .utf8) {
            lines.append(prettyText)
        } else if HTTPProtobuf.isProtobuf(contentType: contentType),
                  let decoded = HTTPProtobuf.render(
                      data,
                      contentType: contentType,
                      grpcEncoding: response.value(forHTTPHeaderField: "grpc-encoding")
                  ) {
            // Before the UTF-8 branch: a protobuf body can happen to be valid UTF-8.
            lines.append(decoded)
        } else if let text = String(data: data, encoding: .utf8) {
            lines.append(text)
        } else {
            lines.append("<\(data.count) bytes of binary data>")
        }

        return lines.joined(separator: "\n")
    }
}

private final class HTTPSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let followRedirects: Bool

    init(followRedirects: Bool) {
        self.followRedirects = followRedirects
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        HTTPRedirectPolicy.proposedRequest(followRedirects: followRedirects, request: request)
    }
}
