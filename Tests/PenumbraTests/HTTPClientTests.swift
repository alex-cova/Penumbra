import Foundation
import XCTest
@testable import Umbra

final class HTTPRequestParserTests: XCTestCase {
    func testParsesAbsoluteFormGETWithHeaders() throws {
        let text = """
        GET https://example.com/api HTTP/1.1
        Accept: application/json

        """
        let request = try HTTPRequestParser.parse(text: text, caretUTF16Offset: 0, fileURL: nil)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://example.com/api")
        XCTAssertEqual(request.headers["Accept"], "application/json")
        XCTAssertNil(request.body)
    }

    func testParsesOriginFormWithHostHeader() throws {
        let text = """
        GET /api/items HTTP/1.1
        Host: example.com

        """
        let request = try HTTPRequestParser.parse(text: text, caretUTF16Offset: 0, fileURL: nil)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "http://example.com/api/items")
    }

    func testParsesPOSTWithJSONBody() throws {
        let text = """
        POST https://example.com/api HTTP/1.1
        Content-Type: application/json

        {
          "ok": true
        }
        """
        let request = try HTTPRequestParser.parse(text: text, caretUTF16Offset: 0, fileURL: nil)
        XCTAssertEqual(request.method, "POST")
        XCTAssertTrue(String(data: request.body ?? Data(), encoding: .utf8)?.contains("\"ok\": true") ?? false)
    }

    func testParsesExternalBodyFromRelativePath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bodyURL = directory.appendingPathComponent("body.json")
        try Data("{\"fromFile\":true}".utf8).write(to: bodyURL)
        let requestFile = directory.appendingPathComponent("request.http")
        let text = """
        POST https://example.com/api HTTP/1.1
        Content-Type: application/json

        < ./body.json
        """
        try Data(text.utf8).write(to: requestFile)

        let request = try HTTPRequestParser.parse(
            text: text,
            caretUTF16Offset: 0,
            fileURL: requestFile
        )
        XCTAssertEqual(String(data: request.body ?? Data(), encoding: .utf8), "{\"fromFile\":true}")
    }

    func testCaretSelectsRequestAmongSeparators() throws {
        let text = """
        ###
        GET https://example.com/first HTTP/1.1

        ###
        POST https://example.com/second HTTP/1.1
        Content-Type: application/json

        {"n": 2}
        """
        let secondRequestOffset = (text as NSString).range(of: "POST").location
        let request = try HTTPRequestParser.parse(
            text: text,
            caretUTF16Offset: secondRequestOffset,
            fileURL: nil
        )
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://example.com/second")
    }

    func testRejectsVariables() {
        let text = """
        GET https://{{host}}/api HTTP/1.1

        """
        XCTAssertThrowsError(try HTTPRequestParser.parse(text: text, caretUTF16Offset: 0, fileURL: nil)) { error in
            XCTAssertEqual(error as? HTTPRequestParserError, .unsupportedVariable)
        }
    }

    func testOriginFormRequiresHostHeader() {
        let text = """
        GET /api HTTP/1.1

        """
        XCTAssertThrowsError(try HTTPRequestParser.parse(text: text, caretUTF16Offset: 0, fileURL: nil)) { error in
            XCTAssertEqual(error as? HTTPRequestParserError, .missingHostHeader)
        }
    }
}

final class HTTPClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTPURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubHTTPURLProtocol.reset()
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        StubHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testSendReturnsFormattedResponse() async throws {
        StubHTTPURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"ok\":true}".utf8))
        }

        let prepared = HTTPPreparedRequest(
            method: "GET",
            url: URL(string: "https://example.com/test")!,
            headers: ["Accept": "application/json"],
            body: nil
        )
        let (response, data) = try await HTTPClient.send(prepared, session: session)
        XCTAssertEqual(response.statusCode, 200)
        let formatted = HTTPClient.formatResponse(response, data: data)
        XCTAssertTrue(formatted.contains("HTTP/1.1 200"))
        XCTAssertTrue(formatted.contains("\"ok\""))
    }

    func testSendSurfacesTransportErrors() async {
        StubHTTPURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let prepared = HTTPPreparedRequest(
            method: "GET",
            url: URL(string: "https://example.com/fail")!,
            headers: [:],
            body: nil
        )

        do {
            _ = try await HTTPClient.send(prepared, session: session)
            XCTFail("Expected transport error")
        } catch let error as HTTPClientError {
            if case .transport = error {
                // expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class StubHTTPURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset() {
        handler = nil
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        Self.lastRequest = request
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
