import Foundation

actor GitHubMetadataClient {
    private struct Key: Equatable {
        let userID: Int64
        let remote: GitHubRemote
    }

    private struct Entry {
        let key: Key
        let response: GitHubTransport.RepositoryResponse
    }

    private let transport: GitHubTransport
    private let now: @Sendable () -> Date
    private var entries: [Entry] = []
    private var holds: [Int64: Date] = [:]
    private var invalidations: [Int64: UInt64] = [:]

    init(transport: GitHubTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    func invalidate(userID: Int64) {
        invalidations[userID, default: 0] &+= 1
        entries.removeAll { $0.key.userID == userID }
        holds.removeValue(forKey: userID)
    }

    func repository<C: Clock>(
        _ remote: GitHubRemote, userID: Int64, accounts: GitHubAccounts<C>
    ) async throws -> GitHubRepositoryMetadata where C.Duration == Duration {
        let started = invalidations[userID]
        let key = Key(userID: userID, remote: remote)
        if let until = holds[userID] {
            if until > now() { throw GitHubTransportError.rateLimited(until: until) }
            holds.removeValue(forKey: userID)
        }
        let token = try await accounts.accessToken(userID: userID)
        try Task.checkCancellation()
        guard started == invalidations[userID] else { throw CancellationError() }
        let cached = entries.first { $0.key == key }?.response
        do {
            let response = try await transport.repository(remote, accessToken: token, cached: cached)
            try Task.checkCancellation()
            guard started == invalidations[userID] else { throw CancellationError() }
            entries.removeAll { $0.key == key }
            if response.etag != nil {
                entries.append(Entry(key: key, response: response))
                if entries.count > 128 { entries.removeFirst() }
            }
            return response.metadata
        } catch let error as GitHubTransportError {
            guard started == invalidations[userID] else { throw CancellationError() }
            switch error {
            case .rateLimited(let until):
                holds[userID] = max(until, holds[userID] ?? .distantPast)
            case .httpStatus(401):
                invalidate(userID: userID)
            case .httpStatus(403), .httpStatus(404):
                entries.removeAll { $0.key == key }
            default: break
            }
            throw error
        }
    }
}
