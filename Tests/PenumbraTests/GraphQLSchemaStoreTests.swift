import Foundation
import XCTest
@testable import Umbra

/// Answers every request from `handler` and records them. Tests set it before use.
final class GraphQLStubProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((Recorded) -> (status: Int, body: String))?
    nonisolated(unsafe) private static var requests: [Recorded] = []

    static func install(_ handler: @escaping (Recorded) -> (status: Int, body: String)) {
        lock.lock()
        self.handler = handler
        requests = []
        lock.unlock()
    }

    static var recorded: [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GraphQLStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = ""
        if let data = request.httpBody {
            body = String(decoding: data, as: UTF8.self)
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = String(decoding: data, as: UTF8.self)
        }
        let recorded = Recorded(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        Self.lock.lock()
        Self.requests.append(recorded)
        let handler = Self.handler
        Self.lock.unlock()
        let answer: (status: Int, body: String) = handler?(recorded) ?? (404, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class GraphQLSchemaStoreTests: XCTestCase {
    private func request(_ address: String, headers: [String: String] = [:]) -> GraphQLSchemaRequest {
        GraphQLSchemaRequest(url: URL(string: address)!, headers: headers)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("graphql-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func waitForState(
        _ store: GraphQLSchemaStore,
        _ url: URL,
        until predicate: (GraphQLSchemaStore.State?) -> Bool
    ) async throws {
        for _ in 0..<200 {
            if predicate(await store.state(for: url)) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the schema store")
    }

    func testPostsTheIntrospectionQueryWithTheRequestsHeaders() async throws {
        GraphQLStubProtocol.install { _ in (200, GraphQLFixtures.introspection) }
        let store = GraphQLSchemaStore(session: GraphQLStubProtocol.makeSession(), cacheDirectory: nil)
        let schema = try await store.refresh(request(
            "https://api.test/graphql",
            headers: ["Authorization": "Bearer t", "Content-Type": "text/plain", "Content-Length": "9"]
        ))
        XCTAssertNotNil(schema.types["User"])
        let sent = try XCTUnwrap(GraphQLStubProtocol.recorded.first)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer t")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        XCTAssertTrue(sent.body.contains("IntrospectionQuery"))
    }

    func testSDLAddressesAreFetchedWithGet() async throws {
        GraphQLStubProtocol.install { _ in (200, GraphQLFixtures.sdl) }
        let store = GraphQLSchemaStore(session: GraphQLStubProtocol.makeSession(), cacheDirectory: nil)
        let schema = try await store.refresh(request("https://api.test/schema.graphql"))
        XCTAssertNotNil(schema.types["Post"])
        XCTAssertEqual(GraphQLStubProtocol.recorded.map(\.method), ["GET"])
    }

    func testFallsBackToAGetWhenIntrospectionIsRefused() async throws {
        GraphQLStubProtocol.install { recorded in
            recorded.method == "POST" ? (405, "") : (200, GraphQLFixtures.sdl)
        }
        let store = GraphQLSchemaStore(session: GraphQLStubProtocol.makeSession(), cacheDirectory: nil)
        let schema = try await store.refresh(request("https://api.test/schema"))
        XCTAssertNotNil(schema.types["User"])
        XCTAssertEqual(GraphQLStubProtocol.recorded.map(\.method), ["POST", "GET"])
    }

    func testReadsAFileSchema() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("schema.graphql")
        try GraphQLFixtures.sdl.write(to: file, atomically: true, encoding: .utf8)
        let store = GraphQLSchemaStore(session: GraphQLStubProtocol.makeSession(), cacheDirectory: nil)
        let schema = try await store.refresh(GraphQLSchemaRequest(url: file))
        XCTAssertNotNil(schema.types["Query"])
        XCTAssertTrue(GraphQLSchemaRequest(url: file).isAutomaticallyFetchable)
    }

    func testAFailureIsReportedAndNotRetriedForAMinute() async throws {
        GraphQLStubProtocol.install { _ in (500, "boom") }
        let store = GraphQLSchemaStore(session: GraphQLStubProtocol.makeSession(), cacheDirectory: nil)
        let address = request("https://api.test/graphql")
        let schema = await store.schema(for: address)
        XCTAssertNil(schema)
        try await waitForState(store, address.url) {
            if case .failed? = $0 { return true }
            return false
        }
        let attempts = GraphQLStubProtocol.recorded.count
        XCTAssertGreaterThan(attempts, 0)
        let again = await store.schema(for: address)
        XCTAssertNil(again)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(GraphQLStubProtocol.recorded.count, attempts)
    }

    func testRefreshOverridesTheBackoffAndSucceeds() async throws {
        let counter = Counter()
        GraphQLStubProtocol.install { _ in
            counter.increment() < 2 ? (500, "") : (200, GraphQLFixtures.introspection)
        }
        let store = GraphQLSchemaStore(session: GraphQLStubProtocol.makeSession(), cacheDirectory: nil)
        let address = request("https://api.test/graphql")
        _ = await store.schema(for: address)
        try await waitForState(store, address.url) {
            if case .failed? = $0 { return true }
            return false
        }
        let schema = try await store.refresh(address)
        XCTAssertNotNil(schema.types["Query"])
        let loaded = await store.schema(for: address)
        XCTAssertNotNil(loaded)
        if case .loaded(let types, _)? = await store.state(for: address.url) {
            // Query, User and ID from the answer, plus the built-in scalars the schema adds.
            XCTAssertEqual(types, 7)
        } else {
            XCTFail("Expected a loaded state")
        }
    }

    func testDiskCacheServesTheNextLaunchImmediately() async throws {
        let directory = try temporaryDirectory()
        GraphQLStubProtocol.install { _ in (200, GraphQLFixtures.introspection) }
        let first = GraphQLSchemaStore(session: GraphQLStubProtocol.makeSession(), cacheDirectory: directory)
        let address = request("https://api.test/graphql")
        _ = try await first.refresh(address)

        GraphQLStubProtocol.install { _ in (500, "") }
        let second = GraphQLSchemaStore(session: GraphQLStubProtocol.makeSession(), cacheDirectory: directory)
        let cached = await second.schema(for: address)
        XCTAssertNotNil(cached?.types["User"], "The copy on disk answers before any request returns.")
    }

    func testAFailedRefreshKeepsTheSchemaThatWasLoaded() async throws {
        let directory = try temporaryDirectory()
        GraphQLStubProtocol.install { _ in (200, GraphQLFixtures.introspection) }
        let store = GraphQLSchemaStore(session: GraphQLStubProtocol.makeSession(), cacheDirectory: directory)
        let address = request("https://api.test/graphql")
        _ = try await store.refresh(address)
        GraphQLStubProtocol.install { _ in (500, "") }
        do {
            _ = try await store.refresh(address)
            XCTFail("The refresh should have failed")
        } catch {}
        let kept = await store.schema(for: address)
        XCTAssertNotNil(kept)
    }

    func testPlainHTTPToAnotherHostIsOnlyFetchedOnRequest() async throws {
        GraphQLStubProtocol.install { _ in (200, GraphQLFixtures.introspection) }
        let store = GraphQLSchemaStore(session: GraphQLStubProtocol.makeSession(), cacheDirectory: nil)
        let remote = request("http://intranet.test/graphql")
        XCTAssertFalse(remote.isAutomaticallyFetchable)
        let schema = await store.schema(for: remote)
        XCTAssertNil(schema)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(GraphQLStubProtocol.recorded.isEmpty)
        _ = try await store.refresh(remote)
        XCTAssertEqual(GraphQLStubProtocol.recorded.count, 1)
        XCTAssertTrue(request("http://localhost:4000/graphql").isAutomaticallyFetchable)
        XCTAssertTrue(request("https://api.test/graphql").isAutomaticallyFetchable)
    }

    func testServerErrorsInTheBodyAreReported() async throws {
        GraphQLStubProtocol.install { _ in (200, #"{"errors":[{"message":"Introspection is disabled"}]}"#) }
        let store = GraphQLSchemaStore(session: GraphQLStubProtocol.makeSession(), cacheDirectory: nil)
        do {
            _ = try await store.refresh(request("https://api.test/graphql"))
            XCTFail("Expected a failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Introspection is disabled"), "\(error)")
        }
    }

    // MARK: - Resolver

    func testResolverExpandsVariablesAndTakesTheSchemasHeaders() throws {
        let text = """
        @host = https://api.test
        ###@scheme:{{host}}/graphql
        GRAPHQL {{host}}/graphql
        Authorization: Bearer abc

        { me { id } }

        ###
        GET https://other.test/x
        Authorization: Bearer other
        """
        let directive = try XCTUnwrap(HTTPGraphQLDirective.directives(in: text).first)
        let request = try GraphQLSchemaResolver.resolve(directive, in: text, fileURL: nil, globals: [:]).get()
        XCTAssertEqual(request.url.absoluteString, "https://api.test/graphql")
        XCTAssertEqual(request.headers["Authorization"], "Bearer abc")
    }

    func testResolverDoesNotSendCredentialsToAnotherHost() throws {
        let text = """
        ###@scheme:https://schema.test/graphql
        POST https://api.test/graphql
        Authorization: Bearer secret

        { me { id } }
        """
        let directive = try XCTUnwrap(HTTPGraphQLDirective.directives(in: text).first)
        let request = try GraphQLSchemaResolver.resolve(directive, in: text, fileURL: nil, globals: [:]).get()
        XCTAssertTrue(request.headers.isEmpty)
    }

    func testResolverReportsUnknownVariablesAndRelativePaths() throws {
        let unknown = "###@scheme:{{nope}}/graphql\n"
        var directive = try XCTUnwrap(HTTPGraphQLDirective.directives(in: unknown).first)
        XCTAssertEqual(
            GraphQLSchemaResolver.resolve(directive, in: unknown, fileURL: nil, globals: [:]),
            .failure(.unknownVariable("nope"))
        )

        let relative = "###@scheme:schema.graphql\n"
        directive = try XCTUnwrap(HTTPGraphQLDirective.directives(in: relative).first)
        XCTAssertEqual(
            GraphQLSchemaResolver.resolve(directive, in: relative, fileURL: nil, globals: [:]),
            .failure(.needsSavedFile("schema.graphql"))
        )
        let file = URL(fileURLWithPath: "/tmp/project/api.http")
        let resolved = try GraphQLSchemaResolver.resolve(directive, in: relative, fileURL: file, globals: [:]).get()
        XCTAssertEqual(resolved.url.path, "/tmp/project/schema.graphql")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// The count before this call.
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        defer { value += 1 }
        return value
    }
}
