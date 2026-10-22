import Foundation
import Testing
@testable import AgentKit

/// Answers requests from a table keyed by URL, so the client's own logic runs without a network.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var failure: URLError?
    }

    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()

    static func reset(_ table: [String: Reply]) {
        lock.withLock {
            replies = table
            seen = []
        }
    }

    static var requests: [URLRequest] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply: Reply? = Self.lock.withLock {
            Self.seen.append(request)
            return Self.replies[request.url?.absoluteString ?? ""]
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func client(limit: Int = URLSessionWebFetchClient.maxBytes, resolves: [String] = ["93.184.216.34"]) -> URLSessionWebFetchClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSessionWebFetchClient(resolver: { _ in resolves }, configuration: configuration, limit: limit)
}

private func url(_ text: String) -> URL { URL(string: text)! }

@Suite(.serialized) struct WebFetchClientTests {
    @Test func aPageIsReadWithItsTypeAndStatus() async throws {
        StubURLProtocol.reset(["https://a.test/x": .init(headers: ["Content-Type": "text/html; charset=utf-8"], body: Data("<p>hi</p>".utf8))])
        let response = try await client().fetch(url("https://a.test/x"), timeout: 5)
        #expect(response.status == 200)
        #expect(response.contentType == "text/html; charset=utf-8")
        #expect(String(decoding: response.body, as: UTF8.self) == "<p>hi</p>")
        #expect(!response.truncated)
        let sent = try #require(StubURLProtocol.requests.first)
        #expect(sent.httpMethod == "GET")
        #expect(sent.value(forHTTPHeaderField: "User-Agent")?.contains("UmbraAgent") == true)
        #expect(sent.httpShouldHandleCookies == false)
    }

    @Test func theBodyIsCutAtTheLimit() async throws {
        StubURLProtocol.reset(["https://a.test/big": .init(headers: ["Content-Type": "text/plain"], body: Data(repeating: 0x61, count: 5_000))])
        let response = try await client(limit: 1_000).fetch(url("https://a.test/big"), timeout: 5)
        #expect(response.body.count == 1_000)
        #expect(response.truncated)
    }

    @Test func aRedirectOnTheSameHostIsFollowedIncludingHttpToHttps() async throws {
        StubURLProtocol.reset([
            "http://a.test/old": .init(status: 301, headers: ["Location": "https://a.test/new"]),
            "https://a.test/new": .init(status: 302, headers: ["Location": "/final"]),
            "https://a.test/final": .init(headers: ["Content-Type": "text/plain"], body: Data("done".utf8)),
        ])
        let response = try await client().fetch(url("http://a.test/old"), timeout: 5)
        #expect(response.url == url("https://a.test/final"))
        #expect(String(decoding: response.body, as: UTF8.self) == "done")
        #expect(response.redirectedTo == nil)
    }

    @Test func aRedirectToAnotherHostIsReportedNotFollowed() async throws {
        StubURLProtocol.reset([
            "https://a.test/go": .init(status: 302, headers: ["Location": "https://b.test/there"]),
            "https://b.test/there": .init(body: Data("secret".utf8)),
        ])
        let response = try await client().fetch(url("https://a.test/go"), timeout: 5)
        #expect(response.redirectedTo == url("https://b.test/there"))
        #expect(response.body.isEmpty)
        #expect(StubURLProtocol.requests.count == 1, "b.test was never contacted")
    }

    @Test func aDowngradeToHttpIsNotTheSameSiteAndLoopsStop() async throws {
        StubURLProtocol.reset(["https://a.test/x": .init(status: 302, headers: ["Location": "http://a.test/x"])])
        let downgraded = try await client().fetch(url("https://a.test/x"), timeout: 5)
        #expect(downgraded.redirectedTo == url("http://a.test/x"))

        StubURLProtocol.reset(["https://a.test/loop": .init(status: 302, headers: ["Location": "https://a.test/loop"])])
        await #expect(throws: WebFetchError.tooManyRedirects) {
            _ = try await client().fetch(url("https://a.test/loop"), timeout: 5)
        }
    }

    @Test func aPrivateAddressIsRefusedBeforeAnyRequestAndOnEveryHop() async throws {
        StubURLProtocol.reset(["https://a.test/x": .init(body: Data("x".utf8))])
        await #expect(throws: WebFetchError.self) {
            _ = try await client(resolves: ["192.168.0.10"]).fetch(url("https://a.test/x"), timeout: 5)
        }
        #expect(StubURLProtocol.requests.isEmpty)

        // A hop to the same name that now points somewhere private is refused too.
        StubURLProtocol.reset(["https://a.test/start": .init(status: 302, headers: ["Location": "https://a.test/next"])])
        final class Flip: @unchecked Sendable { var calls = 0 }
        let flip = Flip()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let flipping = URLSessionWebFetchClient(
            resolver: { _ in flip.calls += 1; return flip.calls == 1 ? ["93.184.216.34"] : ["10.0.0.1"] },
            configuration: configuration, limit: 1_000)
        await #expect(throws: WebFetchError.self) {
            _ = try await flipping.fetch(url("https://a.test/start"), timeout: 5)
        }
    }

    @Test func networkFailuresBecomeFetchErrors() async {
        StubURLProtocol.reset([
            "https://a.test/slow": .init(failure: URLError(.timedOut)),
            "https://a.test/down": .init(failure: URLError(.cannotConnectToHost)),
            "https://a.test/tls": .init(failure: URLError(.serverCertificateUntrusted)),
        ])
        await #expect(throws: WebFetchError.timedOut) { _ = try await client().fetch(url("https://a.test/slow"), timeout: 5) }
        await #expect(throws: WebFetchError.unreachable("a.test")) { _ = try await client().fetch(url("https://a.test/down"), timeout: 5) }
        do {
            _ = try await client().fetch(url("https://a.test/tls"), timeout: 5)
            Issue.record("expected an error")
        } catch let error as WebFetchError {
            guard case .failed(let detail) = error else { Issue.record("\(error)"); return }
            #expect(detail.contains("could not be verified"))
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func errorStatusesComeBackAsResponses() async throws {
        StubURLProtocol.reset(["https://a.test/missing": .init(status: 404, headers: ["Content-Type": "text/html"], body: Data("nope".utf8))])
        let response = try await client().fetch(url("https://a.test/missing"), timeout: 5)
        #expect(response.status == 404)
    }

    @Test func sameSiteRules() {
        #expect(URLSessionWebFetchClient.sameSite(url("https://a.test/x"), url("https://A.TEST/y")))
        #expect(URLSessionWebFetchClient.sameSite(url("https://a.test/x"), url("http://a.test/y")), "an upgrade to https")
        #expect(!URLSessionWebFetchClient.sameSite(url("http://a.test/x"), url("https://a.test/y")), "a downgrade")
        #expect(!URLSessionWebFetchClient.sameSite(url("https://a.test/x"), url("https://www.a.test/x")))
        #expect(!URLSessionWebFetchClient.sameSite(url("https://a.test/x"), url("https://a.test:8443/x")))
    }
}
