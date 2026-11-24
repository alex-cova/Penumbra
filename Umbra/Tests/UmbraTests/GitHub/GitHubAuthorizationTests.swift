import Foundation
import Synchronization
import Testing
@testable import Umbra

@Suite(.serialized)
struct GitHubAuthorizationTests {
    private static let challengeJSON = """
        {"device_code":"synthetic-device","user_code":"TEST-CODE","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
        """
    private static let tokenJSON = """
        {"access_token":"synthetic-access","refresh_token":"synthetic-refresh","token_type":"bearer","expires_in":28800,"refresh_token_expires_in":15897600}
        """

    @Test func signsInAndReadsIdentityWithoutPuttingSecretsInURLs() async throws {
        GitHubStubProtocol.prepare([
            .init(Self.challengeJSON),
            .init(#"{"error":"authorization_pending"}"#),
            .init(#"{"error":"slow_down","interval":12}"#),
            .init(Self.tokenJSON),
            .init(#"{"id":42,"login":"octocat"}"#)
        ])
        let transport = GitHubTransport(protocolClasses: [GitHubStubProtocol.self])
        let clock = GitHubTestClock()
        let date = Date(timeIntervalSince1970: 100)
        let authorization = GitHubDeviceAuthorization(transport: transport, clientID: "test&client", clock: clock, now: { date })
        let challenge = try await authorization.begin()
        #expect(challenge.userCode == "TEST-CODE")
        #expect(challenge.verificationURL.absoluteString == "https://github.com/login/device")
        let pair = try await authorization.complete(challenge)
        #expect(pair.accessExpiresAt == date.addingTimeInterval(28_800))
        #expect(pair.refreshExpiresAt == date.addingTimeInterval(15_897_600))
        #expect(!String(reflecting: pair).contains("synthetic"))
        #expect(!String(reflecting: challenge).contains("synthetic"))
        #expect(try await transport.identity(accessToken: pair.accessToken) == GitHubIdentity(id: 42, login: "octocat"))
        #expect(clock.delays == [.seconds(5), .seconds(5), .seconds(12)])

        let requests = GitHubStubProtocol.requests
        #expect(requests.map(\.url?.path) == ["/login/device/code", "/login/oauth/access_token",
                                            "/login/oauth/access_token", "/login/oauth/access_token", "/user"])
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "POST", "POST", "GET"])
        #expect(requests.allSatisfy { $0.url?.query == nil })
        #expect(requests.first.flatMap(Self.body)?.contains("client_id=test%26client") == true)
        #expect(requests.dropFirst().first.flatMap(Self.body)?.contains("device_code=synthetic-device") == true)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
        #expect(requests.last?.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
    }

    @Test func expiryStopsBeforePolling() async throws {
        GitHubStubProtocol.prepare([.init(Self.challengeJSON.replacingOccurrences(of: "900", with: "4"))])
        let transport = GitHubTransport(protocolClasses: [GitHubStubProtocol.self])
        let authorization = GitHubDeviceAuthorization(transport: transport, clientID: "client", clock: GitHubTestClock())
        let challenge = try await authorization.begin()
        await #expect(throws: GitHubAuthorizationError.expired) { try await authorization.complete(challenge) }
        #expect(GitHubStubProtocol.requests.count == 1)
    }

    @Test func cancelledPollDoesNotStartAnExchange() async throws {
        GitHubStubProtocol.prepare([.init(Self.challengeJSON)])
        let transport = GitHubTransport(protocolClasses: [GitHubStubProtocol.self])
        let authorization = GitHubDeviceAuthorization(transport: transport, clientID: "client", clock: GitHubTestClock())
        let challenge = try await authorization.begin()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await authorization.complete(challenge)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(GitHubStubProtocol.requests.count == 1)
    }

    @Test func rejectsUntrustedVerificationURL() async {
        GitHubStubProtocol.prepare([.init(Self.challengeJSON.replacingOccurrences(of: "github.com", with: "example.test"))])
        let transport = GitHubTransport(protocolClasses: [GitHubStubProtocol.self])
        let authorization = GitHubDeviceAuthorization(transport: transport, clientID: "client", clock: GitHubTestClock())
        await #expect(throws: GitHubAuthorizationError.invalidResponse) { try await authorization.begin() }
    }

    @Test func deniedAuthorizationStopsPolling() async throws {
        GitHubStubProtocol.prepare([.init(Self.challengeJSON), .init(#"{"error":"access_denied"}"#)])
        let transport = GitHubTransport(protocolClasses: [GitHubStubProtocol.self])
        let authorization = GitHubDeviceAuthorization(transport: transport, clientID: "client", clock: GitHubTestClock())
        let challenge = try await authorization.begin()
        await #expect(throws: GitHubAuthorizationError.denied) { try await authorization.complete(challenge) }
        #expect(GitHubStubProtocol.requests.count == 2)
    }

    @Test func refreshRotatesBothCredentialsAndRecognizesRevocation() async throws {
        let response = try JSONDecoder().decode(GitHubTokenResponse.self, from: Data(Self.tokenJSON.utf8))
        let date = Date(timeIntervalSince1970: 100)
        let old = try GitHubTokenPair(response: response, now: date)
        GitHubStubProtocol.prepare([
            .init(Self.tokenJSON.replacingOccurrences(of: "synthetic", with: "rotated")),
            .init(#"{"error":"bad_refresh_token"}"#)
        ])
        let transport = GitHubTransport(protocolClasses: [GitHubStubProtocol.self])
        let authorization = GitHubDeviceAuthorization(transport: transport, clientID: "client", clock: GitHubTestClock(), now: { date })
        let rotated = try await authorization.refresh(old)
        #expect(rotated.accessToken == "rotated-access")
        #expect(rotated.refreshToken == "rotated-refresh")
        let request = try #require(GitHubStubProtocol.requests.first)
        #expect(request.url?.query == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(Self.body(request)?.contains("refresh_token=synthetic-refresh") == true)
        await #expect(throws: GitHubAuthorizationError.reauthorizationRequired) { try await authorization.refresh(rotated) }
    }

    @Test func boundsResponsesAndDiscardsRemoteErrorMessages() async {
        GitHubStubProtocol.prepare([
            .init("synthetic-secret", status: 401),
            .init("", headers: ["Content-Length": "2097153"]),
            .init(String(repeating: "x", count: 2 * 1024 * 1024 + 1)),
            .init(#"{"id":"synthetic-secret"}"#)
        ])
        let transport = GitHubTransport(protocolClasses: [GitHubStubProtocol.self])
        await #expect(throws: GitHubTransportError.httpStatus(401)) { try await transport.identity(accessToken: "synthetic-access") }
        await #expect(throws: GitHubTransportError.responseTooLarge) { try await transport.identity(accessToken: "synthetic-access") }
        await #expect(throws: GitHubTransportError.responseTooLarge) { try await transport.identity(accessToken: "synthetic-access") }
        await #expect(throws: GitHubTransportError.invalidPayload) { try await transport.identity(accessToken: "synthetic-access") }
        await #expect(throws: GitHubTransportError.invalidCredential) { try await transport.identity(accessToken: "synthetic\naccess") }
        #expect(GitHubStubProtocol.requests.count == 4)
    }

    @Test func restoresTwoAccountsAndReauthorizationChecksIdentity() async throws {
        let otherTokens = Self.tokenJSON.replacingOccurrences(of: "synthetic", with: "other")
        GitHubStubProtocol.prepare([
            .init(Self.challengeJSON), .init(Self.tokenJSON), .init(#"{"id":42,"login":"octocat"}"#),
            .init(Self.challengeJSON), .init(otherTokens), .init(#"{"id":21,"login":"hubot"}"#),
            .init(Self.challengeJSON), .init(otherTokens), .init(#"{"id":21,"login":"hubot"}"#)
        ])
        let transport = GitHubTransport(protocolClasses: [GitHubStubProtocol.self])
        let store = GitHubMemoryCredentialStore()
        let accounts = GitHubAccounts(transport: transport, clientID: "client", clock: GitHubTestClock(), store: store)
        let first = try await accounts.beginSignIn()
        #expect(try await accounts.completeSignIn(first).id == 42)
        let second = try await accounts.beginSignIn()
        #expect(try await accounts.completeSignIn(second).id == 21)
        let reauthorization = try await accounts.beginSignIn()
        await #expect(throws: GitHubAccountError.identityChanged) {
            try await accounts.completeSignIn(reauthorization, expectedUserID: 42)
        }

        let restored = GitHubAccounts(transport: transport, clientID: "client", clock: GitHubTestClock(), store: store)
        #expect(try await restored.identities().map(\.id) == [21, 42])
        #expect(try await restored.accessToken(userID: 42) == "synthetic-access")
        #expect(try await restored.accessToken(userID: 21) == "other-access")
        try await restored.signOut(userID: 42)
        #expect(try await restored.identities().map(\.id) == [21])
        await #expect(throws: GitHubAccountError.signedOut) { try await restored.accessToken(userID: 42) }
        #expect(GitHubStubProtocol.requests.count == 9)
    }

    @Test func concurrentAccessRotatesOnceAndPersistsTheUpdatedPair() async throws {
        let response = try JSONDecoder().decode(GitHubTokenResponse.self, from: Data(Self.tokenJSON.utf8))
        let initial = Date(timeIntervalSince1970: 100)
        let now = initial.addingTimeInterval(28_800)
        let credential = GitHubCredential(
            identity: GitHubIdentity(id: 42, login: "octocat"),
            tokens: try GitHubTokenPair(response: response, now: initial)
        )
        let store = GitHubMemoryCredentialStore()
        store.save(credential)
        GitHubStubProtocol.prepare([.init(Self.tokenJSON.replacingOccurrences(of: "synthetic", with: "rotated"))])
        let transport = GitHubTransport(protocolClasses: [GitHubStubProtocol.self])
        let accounts = GitHubAccounts(
            transport: transport, clientID: "client", clock: GitHubTestClock(), store: store, now: { now }
        )
        async let first = accounts.accessToken(userID: 42)
        async let second = accounts.accessToken(userID: 42)
        let values = try await [first, second]
        #expect(values == ["rotated-access", "rotated-access"])
        #expect(store.load(userID: 42)?.tokens.refreshToken == "rotated-refresh")
        #expect(GitHubStubProtocol.requests.count == 1)
    }

    @Test func signOutInvalidatesAnOutstandingSignInChallenge() async throws {
        GitHubStubProtocol.prepare([.init(Self.challengeJSON)])
        let transport = GitHubTransport(protocolClasses: [GitHubStubProtocol.self])
        let accounts = GitHubAccounts(
            transport: transport, clientID: "client", clock: GitHubTestClock(), store: GitHubMemoryCredentialStore()
        )
        let signIn = try await accounts.beginSignIn()
        try await accounts.signOut(userID: 42)
        await #expect(throws: GitHubAccountError.signedOut) { try await accounts.completeSignIn(signIn) }
        #expect(GitHubStubProtocol.requests.count == 1)
    }

    @Test func fetchRemoteRecognitionUsesAnExactGitHubAuthority() {
        for valid in [
            "https://GitHub.com/Octocat/Hello_World.git", "git@github.com:Octocat/Hello_World.git",
            "ssh://git@github.com:22/Octocat/Hello_World", "ssh://git@ssh.github.com:443/Octocat/Hello_World.git"
        ] {
            let remote = GitHubRemote(fetchURL: valid)
            #expect(remote?.owner == "octocat")
            #expect(remote?.repository == "hello_world")
        }

        for invalid in [
            "https://github.com.example.test/a/b", "https://github.com@other.test/a/b",
            "https://token@github.com/a/b", "https://github.com:444/a/b",
            "https://github.com/a/%2eb", "https://github.com/a/..",
            "https://github.com/a/b/c", "https://github.com/a/b?next=1", "http://github.com/a/b",
            "file:///a/b", "git@github.com:/a/b", "https://%67ithub.com/a/b"
        ] {
            #expect(GitHubRemote(fetchURL: invalid) == nil)
        }
    }

    @Test func fetchesReadOnlyRepositoryMetadataFromTheCanonicalAPIHost() async throws {
        GitHubStubProtocol.prepare([
            .init(#"{"id":25,"full_name":"Octocat/Example","default_branch":"main","visibility":"private","archived":false}"#),
            .init("", status: 301, headers: ["Location": "https://example.test/user"])
        ])
        let transport = GitHubTransport(protocolClasses: [GitHubStubProtocol.self])
        let remote = try #require(GitHubRemote(fetchURL: "git@github.com:Octocat/Example.git"))
        let metadata = try await transport.repository(remote, accessToken: "synthetic-access")
        #expect(metadata.fullName == "Octocat/Example")
        #expect(metadata.defaultBranch == "main")
        #expect(metadata.visibility == "private")
        await #expect(throws: GitHubTransportError.httpStatus(301)) {
            try await transport.repository(remote, accessToken: "synthetic-access")
        }
        #expect(GitHubStubProtocol.requests.count == 2)
        for request in GitHubStubProtocol.requests {
            #expect(request.url?.absoluteString == "https://api.github.com/repos/octocat/example")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
        }
    }

    private static func body(_ request: URLRequest) -> String? {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        var data = Data()
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            guard count > 0 else { return String(decoding: data, as: UTF8.self) }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}

private final class GitHubTestClock: Clock, Sendable {
    private struct State {
        var now = ContinuousClock.now
        var delays: [Duration] = []
    }

    private let state = Mutex(State())
    var now: ContinuousClock.Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var delays: [Duration] { state.withLock { $0.delays } }

    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        state.withLock {
            $0.delays.append($0.now.duration(to: deadline))
            $0.now = deadline
        }
    }
}

private final class GitHubStubProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let body: Data
        let status: Int
        let headers: [String: String]

        init(_ body: String, status: Int = 200, headers: [String: String] = [:]) {
            self.body = Data(body.utf8)
            self.status = status
            self.headers = headers
        }
    }

    private struct State {
        var responses: [Response]
        var requests: [URLRequest] = []
    }

    private static let state = Mutex(State(responses: []))

    static func prepare(_ responses: [Response]) {
        state.withLock { $0 = State(responses: responses) }
    }

    static var requests: [URLRequest] { state.withLock { $0.requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let next = Self.state.withLock { state -> Response? in
            state.requests.append(request)
            return state.responses.isEmpty ? nil : state.responses.removeFirst()
        }
        guard let next, let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class GitHubMemoryCredentialStore: GitHubCredentialStore {
    private let records = Mutex([Int64: GitHubCredential]())

    func identities() -> [GitHubIdentity] { records.withLock { $0.values.map(\.identity) } }
    func load(userID: Int64) -> GitHubCredential? { records.withLock { $0[userID] } }
    func save(_ credential: GitHubCredential) { records.withLock { $0[credential.identity.id] = credential } }
    func remove(userID: Int64) { records.withLock { _ = $0.removeValue(forKey: userID) } }
}
