import Foundation

/// What a fetch brought back.
public struct WebFetchResponse: Sendable, Equatable {
    /// The address that answered, after same-host redirects.
    public var url: URL
    public var status: Int
    public var contentType: String?
    public var body: Data
    /// The body was cut at the client's size limit.
    public var truncated: Bool
    /// Set instead of following a redirect to another host, which the user has not been asked about.
    public var redirectedTo: URL?

    public init(url: URL, status: Int, contentType: String?, body: Data, truncated: Bool = false, redirectedTo: URL? = nil) {
        self.url = url
        self.status = status
        self.contentType = contentType
        self.body = body
        self.truncated = truncated
        self.redirectedTo = redirectedTo
    }
}

public enum WebFetchError: Error, Equatable, LocalizedError {
    /// The address is not one the agent may fetch; the reason is for the model and the user.
    case refused(String)
    case unreachable(String)
    case timedOut
    case tooManyRedirects
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .refused(let reason): reason
        case .unreachable(let host): "Could not connect to \(host)."
        case .timedOut: "The request timed out."
        case .tooManyRedirects: "The address redirected too many times."
        case .failed(let detail): "The request failed: \(detail)"
        }
    }
}

/// Reads one page. A host can supply its own (tests do); `URLSessionWebFetchClient` is the real one.
public protocol WebFetchClient: Sendable {
    func fetch(_ url: URL, timeout: TimeInterval) async throws -> WebFetchResponse
}

/// Turns a host name into the numeric addresses it points at.
public typealias WebHostResolver = @Sendable (String) async -> [String]

/// Which addresses the agent may reach. The agent runs on the user's Mac, so a page request must not
/// become a request to something only that Mac can see: its own services, the home network, a cloud
/// metadata address.
public enum WebAddressPolicy {
    /// Checks the scheme, the userinfo and the host, and resolves the host: every address it points
    /// at must be public. Known limit: the connection resolves the name again, so a host that answers
    /// differently the second time (DNS rebinding) is not caught.
    public static func validate(_ url: URL, resolver: WebHostResolver) async throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw WebFetchError.refused("Only http and https addresses can be fetched.")
        }
        guard url.user == nil, url.password == nil else {
            throw WebFetchError.refused("Addresses with a username or password are not fetched.")
        }
        guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            throw WebFetchError.refused("The address has no host.")
        }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        let privateSuffixes = [".localhost", ".local", ".internal", ".localdomain", ".home.arpa", ".lan"]
        if host == "localhost" || privateSuffixes.contains(where: host.hasSuffix) {
            throw WebFetchError.refused("\(host) is a name for this machine or a local network, which is not fetched.")
        }
        let addresses = await resolver(host)
        guard !addresses.isEmpty else { throw WebFetchError.unreachable(host) }
        if let blocked = addresses.first(where: { !isPublic($0) }) {
            throw WebFetchError.refused(blocked == host
                ? "\(host) is an address on this machine or a private network, which is not fetched."
                : "\(host) points at \(blocked), an address on this machine or a private network, which is not fetched.")
        }
    }

    /// Whether a numeric address is on the public internet.
    public static func isPublic(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            return isPublic(v4: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        // ::, ::1, and everything else with 12 leading zero bytes (IPv4-compatible) or ::ffff:a.b.c.d (mapped).
        if bytes[0..<10].allSatisfy({ $0 == 0 }) {
            if bytes[10] == 0xFF, bytes[11] == 0xFF { return isPublic(v4: Array(bytes[12..<16])) }
            if bytes[10] == 0, bytes[11] == 0 { return false }
        }
        // 64:ff9b::/96 translates to the IPv4 address in its last four bytes.
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xFF, bytes[3] == 0x9B, bytes[4..<12].allSatisfy({ $0 == 0 }) {
            return isPublic(v4: Array(bytes[12..<16]))
        }
        if bytes[0] & 0xFE == 0xFC { return false }                      // fc00::/7 unique local
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false }    // fe80::/10 link local
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 { return false }    // fec0::/10 site local (deprecated)
        if bytes[0] == 0xFF { return false }                             // multicast
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return false } // documentation
        return true
    }

    private static func isPublic(v4 b: [UInt8]) -> Bool {
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _): return false
        case (100, 64...127): return false          // carrier-grade NAT
        case (169, 254): return false               // link local, including cloud metadata
        case (172, 16...31): return false
        case (192, 168): return false
        case (192, 0) where b[2] == 0: return false // IETF protocol assignments
        case (198, 18...19): return false           // benchmarking
        case (224...255, _): return false           // multicast, reserved, broadcast
        default: return true
        }
    }

    /// The real resolver: `getaddrinfo` on a background queue (it blocks).
    public static let systemResolver: WebHostResolver = { host in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var list: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else {
                    continuation.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(list) }
                var addresses: [String] = []
                var cursor: UnsafeMutablePointer<addrinfo>? = first
                while let entry = cursor {
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    if let sockaddr = entry.pointee.ai_addr {
                        let family = entry.pointee.ai_family
                        let pointer: UnsafeRawPointer? = family == AF_INET
                            ? UnsafeRawPointer(sockaddr).advanced(by: MemoryLayout<sockaddr_in>.offset(of: \.sin_addr)!)
                            : family == AF_INET6
                                ? UnsafeRawPointer(sockaddr).advanced(by: MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr)!)
                                : nil
                        if let pointer, inet_ntop(family, pointer, &buffer, socklen_t(buffer.count)) != nil {
                            addresses.append(String(cString: buffer))
                        }
                    }
                    cursor = entry.pointee.ai_next
                }
                continuation.resume(returning: Array(Set(addresses)).sorted())
            }
        }
    }
}

/// Reads pages with `URLSession`: GET only, no cookies and no cache, a size limit, and redirects
/// followed by hand so that each hop is checked and a hop to another host is reported instead of
/// followed (the user agreed to the host they were asked about, not to wherever it points).
public struct URLSessionWebFetchClient: WebFetchClient {
    public static let maxBytes = 2 * 1_024 * 1_024
    static let maxRedirects = 5
    static let userAgent = "Mozilla/5.0 (compatible; UmbraAgent/1.0)"

    private let resolver: WebHostResolver
    private let configuration: URLSessionConfiguration
    private let limit: Int

    public init(resolver: @escaping WebHostResolver = WebAddressPolicy.systemResolver) {
        self.init(resolver: resolver, configuration: .ephemeral, limit: Self.maxBytes)
    }

    init(resolver: @escaping WebHostResolver, configuration: URLSessionConfiguration, limit: Int) {
        self.resolver = resolver
        self.configuration = configuration
        self.limit = limit
    }

    public func fetch(_ url: URL, timeout: TimeInterval) async throws -> WebFetchResponse {
        let copied = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        copied.httpCookieStorage = nil
        copied.httpShouldSetCookies = false
        copied.urlCache = nil
        copied.requestCachePolicy = .reloadIgnoringLocalCacheData
        copied.timeoutIntervalForRequest = timeout
        copied.timeoutIntervalForResource = timeout + 10
        let session = URLSession(configuration: copied, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var current = url
        for _ in 0...Self.maxRedirects {
            try await WebAddressPolicy.validate(current, resolver: resolver)
            var request = URLRequest(url: current)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/markdown, text/html;q=0.9, text/plain;q=0.8, application/json;q=0.7, */*;q=0.1", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

            let response: HTTPURLResponse
            var body = Data()
            var truncated = false
            do {
                let (bytes, urlResponse) = try await session.bytes(for: request)
                guard let http = urlResponse as? HTTPURLResponse else { throw WebFetchError.failed("not an HTTP response") }
                response = http
                if !(300..<400).contains(http.statusCode) {
                    for try await byte in bytes {
                        if body.count >= limit {
                            truncated = true
                            break
                        }
                        body.append(byte)
                    }
                }
            } catch let error as WebFetchError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                throw Self.map(error, host: current.host() ?? "the server")
            }

            if (300..<400).contains(response.statusCode),
               let location = response.value(forHTTPHeaderField: "Location"),
               let target = URL(string: location, relativeTo: current)?.absoluteURL {
                if Self.sameSite(target, current) {
                    current = target
                    continue
                }
                return WebFetchResponse(
                    url: current, status: response.statusCode, contentType: nil, body: Data(), redirectedTo: target)
            }
            return WebFetchResponse(
                url: current, status: response.statusCode, contentType: response.value(forHTTPHeaderField: "Content-Type"),
                body: body, truncated: truncated)
        }
        throw WebFetchError.tooManyRedirects
    }

    /// The same host and port. Going from http to https on that host counts as the same site.
    static func sameSite(_ a: URL, _ b: URL) -> Bool {
        guard let hostA = a.host()?.lowercased(), hostA == b.host()?.lowercased() else { return false }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        if a.scheme?.lowercased() != b.scheme?.lowercased() {
            return a.scheme?.lowercased() == "https" && b.scheme?.lowercased() == "http" && a.port == nil
        }
        return port(a) == port(b)
    }

    static func map(_ error: URLError, host: String) -> Error {
        switch error.code {
        case .cancelled: CancellationError()
        case .timedOut: WebFetchError.timedOut
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost:
            WebFetchError.unreachable(host)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            WebFetchError.failed("the secure connection to \(host) could not be verified")
        default:
            WebFetchError.failed(error.localizedDescription)
        }
    }
}

/// Answers every redirect with "do not follow", so the 3xx response comes back and the client decides.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
