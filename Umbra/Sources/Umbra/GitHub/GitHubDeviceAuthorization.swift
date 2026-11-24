import Foundation

enum GitHubAuthorizationError: Error, Equatable {
    case denied
    case expired
    case unavailable
    case reauthorizationRequired
    case invalidResponse
}

struct GitHubDeviceCodeResponse: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let deviceCode: String?
    let userCode: String?
    let verificationURI: String?
    let expiresIn: Int?
    let interval: Int?
    let error: String?

    var description: String { "GitHub device authorization response" }
    var debugDescription: String { description }

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval, error
    }
}

struct GitHubTokenResponse: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let refreshTokenExpiresIn: Int?
    let tokenType: String?
    let interval: Int?
    let error: String?

    var description: String { "GitHub token response" }
    var debugDescription: String { description }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case tokenType = "token_type"
        case interval, error
    }
}

struct GitHubTokenPair: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let accessToken: String
    let refreshToken: String
    let accessExpiresAt: Date
    let refreshExpiresAt: Date

    var description: String { "GitHub token pair" }
    var debugDescription: String { description }

    init(response: GitHubTokenResponse, now: Date) throws {
        guard response.error == nil,
              response.tokenType?.lowercased() == "bearer",
              let accessToken = response.accessToken, Self.valid(accessToken),
              let refreshToken = response.refreshToken, Self.valid(refreshToken),
              let lifetime = response.expiresIn, (1...86_400).contains(lifetime),
              let refreshLifetime = response.refreshTokenExpiresIn, (1...31_622_400).contains(refreshLifetime)
        else { throw GitHubAuthorizationError.invalidResponse }
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        accessExpiresAt = now.addingTimeInterval(Double(lifetime))
        refreshExpiresAt = now.addingTimeInterval(Double(refreshLifetime))
    }

    private static func valid(_ value: String) -> Bool {
        (1...1024).contains(value.utf8.count) && value.utf8.allSatisfy { (33...126).contains($0) }
    }
}

struct GitHubDeviceAuthorization<C: Clock>: Sendable where C.Duration == Duration {
    struct Challenge: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let userCode: String
        let verificationURL: URL
        fileprivate let deviceCode: String
        fileprivate let deadline: C.Instant
        fileprivate let interval: Duration

        var description: String { "GitHub device authorization challenge" }
        var debugDescription: String { description }
    }

    private let transport: GitHubTransport
    private let clientID: String
    private let clock: C
    private let now: @Sendable () -> Date

    init(transport: GitHubTransport, clientID: String, clock: C, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.clientID = clientID
        self.clock = clock
        self.now = now
    }

    func begin() async throws -> Challenge {
        let start = clock.now
        let response = try await transport.requestDeviceCode(clientID: clientID)
        if response.error == "device_flow_disabled" { throw GitHubAuthorizationError.unavailable }
        guard response.error == nil,
              let deviceCode = response.deviceCode, !deviceCode.isEmpty, deviceCode.utf8.count <= 128,
              let userCode = response.userCode, userCode.utf8.count == 9,
              userCode.utf8.enumerated().allSatisfy({ index, byte in
                  index == 4 ? byte == 45 : (65...90).contains(byte) || (48...57).contains(byte)
              }),
              response.verificationURI == "https://github.com/login/device",
              let expiresIn = response.expiresIn, (1...900).contains(expiresIn),
              let interval = response.interval, (1...900).contains(interval)
        else { throw GitHubAuthorizationError.invalidResponse }

        let deadline = start.advanced(by: .seconds(expiresIn))
        guard clock.now < deadline else { throw GitHubAuthorizationError.expired }
        return Challenge(
            userCode: userCode, verificationURL: URL(string: "https://github.com/login/device")!,
            deviceCode: deviceCode, deadline: deadline, interval: .seconds(interval)
        )
    }

    func complete(_ challenge: Challenge) async throws -> GitHubTokenPair {
        var interval = challenge.interval
        while true {
            try Task.checkCancellation()
            let next = clock.now.advanced(by: interval)
            try await clock.sleep(until: min(next, challenge.deadline), tolerance: nil)
            try Task.checkCancellation()
            guard clock.now < challenge.deadline else { throw GitHubAuthorizationError.expired }
            let response = try await transport.exchangeDeviceCode(clientID: clientID, deviceCode: challenge.deviceCode)
            switch response.error {
            case nil:
                return try GitHubTokenPair(response: response, now: now())
            case "authorization_pending":
                continue
            case "slow_down":
                let serverInterval = response.interval.flatMap { (1...900).contains($0) ? $0 : nil } ?? 0
                interval = max(interval + .seconds(5), .seconds(serverInterval))
            case "access_denied":
                throw GitHubAuthorizationError.denied
            case "expired_token", "token_expired":
                throw GitHubAuthorizationError.expired
            default:
                throw GitHubAuthorizationError.invalidResponse
            }
        }
    }

    func refresh(_ pair: GitHubTokenPair) async throws -> GitHubTokenPair {
        guard now() < pair.refreshExpiresAt else { throw GitHubAuthorizationError.reauthorizationRequired }
        let response = try await transport.refreshDeviceToken(clientID: clientID, refreshToken: pair.refreshToken)
        if response.error == "bad_refresh_token" { throw GitHubAuthorizationError.reauthorizationRequired }
        return try GitHubTokenPair(response: response, now: now())
    }
}
