import Foundation

enum GitHubAccountError: Error, Equatable {
    case signedOut
    case identityChanged
}

/// Instantiate one owner per registration for the lifetime of the app.
actor GitHubAccounts<C: Clock> where C.Duration == Duration {
    struct SignIn: Sendable {
        let challenge: GitHubDeviceAuthorization<C>.Challenge
        fileprivate let generation: UInt64
        fileprivate let owner: UUID
    }

    private struct Refresh {
        let id: UUID
        let task: Task<Void, Error>
    }

    private let owner = UUID()
    private var generation: UInt64 = 0
    private var refreshes: [Int64: Refresh] = [:]
    private let authorization: GitHubDeviceAuthorization<C>
    private let transport: GitHubTransport
    private let store: any GitHubCredentialStore
    private let now: @Sendable () -> Date

    init(
        transport: GitHubTransport, clientID: String, clock: C, store: any GitHubCredentialStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.authorization = GitHubDeviceAuthorization(transport: transport, clientID: clientID, clock: clock, now: now)
        self.store = store
        self.now = now
    }

    func identities() throws -> [GitHubIdentity] {
        try store.identities().sorted { $0.id < $1.id }
    }

    func beginSignIn() async throws -> SignIn {
        let started = generation
        let challenge = try await authorization.begin()
        try Task.checkCancellation()
        guard started == generation else { throw GitHubAccountError.signedOut }
        return SignIn(challenge: challenge, generation: started, owner: owner)
    }

    func completeSignIn(_ signIn: SignIn, expectedUserID: Int64? = nil) async throws -> GitHubIdentity {
        guard signIn.owner == owner, signIn.generation == generation else { throw GitHubAccountError.signedOut }
        let tokens = try await authorization.complete(signIn.challenge)
        let identity = try await transport.identity(accessToken: tokens.accessToken)
        try Task.checkCancellation()
        guard signIn.generation == generation else { throw GitHubAccountError.signedOut }
        if let expectedUserID, expectedUserID != identity.id { throw GitHubAccountError.identityChanged }
        try store.save(GitHubCredential(identity: identity, tokens: tokens))
        refreshes.removeValue(forKey: identity.id)?.task.cancel()
        return identity
    }

    func signOut(userID: Int64) throws {
        try store.remove(userID: userID)
        generation &+= 1
        refreshes.removeValue(forKey: userID)?.task.cancel()
    }

    func accessToken(userID: Int64) async throws -> String {
        try Task.checkCancellation()
        let pending: Refresh
        if let existing = refreshes[userID] {
            pending = existing
        } else {
            guard let credential = try store.load(userID: userID) else { throw GitHubAccountError.signedOut }
            if credential.tokens.accessExpiresAt > now().addingTimeInterval(60) {
                return credential.tokens.accessToken
            }
            let id = UUID()
            let task = Task {
                defer {
                    if refreshes[userID]?.id == id { refreshes.removeValue(forKey: userID) }
                }
                let tokens = try await authorization.refresh(credential.tokens)
                try Task.checkCancellation()
                guard refreshes[userID]?.id == id else { throw GitHubAccountError.signedOut }
                try store.save(GitHubCredential(identity: credential.identity, tokens: tokens))
            }
            pending = Refresh(id: id, task: task)
            refreshes[userID] = pending
        }
        try await pending.task.value
        try Task.checkCancellation()
        guard let current = try store.load(userID: userID) else { throw GitHubAccountError.signedOut }
        // Reauthorization may have replaced the record after the refresh completed.
        return current.tokens.accessToken
    }
}
