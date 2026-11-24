import Foundation

enum GitHubTransportError: Error, Equatable {
    case invalidCredential
    case connectionFailed
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
    case invalidPayload
}

struct GitHubIdentity: Codable, Equatable, Sendable {
    let id: Int64
    let login: String
}

/// The initial surface exposes identity reads and the fixed device authorization routes.
struct GitHubTransport: Sendable {
    static let apiVersion = "2026-03-10"
    private static let maxBodyBytes = 2 * 1024 * 1024

    private let session: URLSession

    init(protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = protocolClasses ?? configuration.protocolClasses
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: GitHubNoRedirects(), delegateQueue: nil)
    }

    @concurrent
    func identity(accessToken: String) async throws -> GitHubIdentity {
        let request = try authenticatedGET(path: "/user", accessToken: accessToken)
        let identity = try await send(request, decoding: GitHubIdentity.self)
        guard identity.id > 0, !identity.login.isEmpty else { throw GitHubTransportError.invalidPayload }
        return identity
    }

    @concurrent
    func repository(_ remote: GitHubRemote, accessToken: String) async throws -> GitHubRepositoryMetadata {
        let request = try authenticatedGET(path: "/repos/\(remote.owner)/\(remote.repository)", accessToken: accessToken)
        let metadata = try await send(request, decoding: GitHubRepositoryMetadata.self)
        guard metadata.id > 0, !metadata.fullName.isEmpty else { throw GitHubTransportError.invalidPayload }
        return metadata
    }

    private func authenticatedGET(path: String, accessToken: String) throws -> URLRequest {
        guard (1...1024).contains(accessToken.utf8.count),
              accessToken.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw GitHubTransportError.invalidCredential }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = path
        guard let url = components.url else { throw GitHubTransportError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    @concurrent
    func requestDeviceCode(clientID: String) async throws -> GitHubDeviceCodeResponse {
        try await postForm(
            to: URL(string: "https://github.com/login/device/code")!,
            fields: [("client_id", clientID), ("scope", "offline_access")],
            decoding: GitHubDeviceCodeResponse.self
        )
    }

    @concurrent
    func exchangeDeviceCode(clientID: String, deviceCode: String) async throws -> GitHubTokenResponse {
        try await postForm(
            to: URL(string: "https://github.com/login/oauth/access_token")!,
            fields: [
                ("client_id", clientID),
                ("device_code", deviceCode),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")
            ],
            decoding: GitHubTokenResponse.self
        )
    }

    @concurrent
    func refreshDeviceToken(clientID: String, refreshToken: String) async throws -> GitHubTokenResponse {
        try await postForm(
            to: URL(string: "https://github.com/login/oauth/access_token")!,
            fields: [("client_id", clientID), ("refresh_token", refreshToken), ("grant_type", "refresh_token")],
            decoding: GitHubTokenResponse.self
        )
    }

    private func postForm<Response: Decodable>(
        to url: URL, fields: [(String, String)], decoding: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let pairs = try fields.map { name, value in
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw GitHubTransportError.invalidCredential
            }
            return "\(name)=\(encoded)"
        }
        request.httpBody = Data(pairs.joined(separator: "&").utf8)
        return try await send(request, decoding: decoding)
    }

    private func send<Response: Decodable>(_ request: URLRequest, decoding: Response.Type) async throws -> Response {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw GitHubTransportError.invalidResponse }
            guard (200...299).contains(response.statusCode) else {
                throw GitHubTransportError.httpStatus(response.statusCode)
            }
            let length = response.expectedContentLength
            guard length <= Self.maxBodyBytes else { throw GitHubTransportError.responseTooLarge }
            var body = Data()
            if length > 0 { body.reserveCapacity(Int(length)) }
            for try await byte in bytes {
                guard body.count < Self.maxBodyBytes else { throw GitHubTransportError.responseTooLarge }
                body.append(byte)
            }
            try Task.checkCancellation()
            do {
                return try JSONDecoder().decode(decoding, from: body)
            } catch {
                throw GitHubTransportError.invalidPayload
            }
        } catch let error as GitHubTransportError {
            try Task.checkCancellation()
            throw error
        } catch {
            try Task.checkCancellation()
            throw GitHubTransportError.connectionFailed
        }
    }
}

private final class GitHubNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
