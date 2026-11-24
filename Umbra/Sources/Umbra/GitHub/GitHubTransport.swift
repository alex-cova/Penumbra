import Foundation

enum GitHubTransportError: Error, Equatable {
    case invalidCredential
    case connectionFailed
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
    case invalidPayload
    case rateLimited(until: Date)
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
        try await repository(remote, accessToken: accessToken, cached: nil).metadata
    }

    struct RepositoryResponse: Sendable {
        let metadata: GitHubRepositoryMetadata
        let etag: String?
    }

    @concurrent
    func repository(
        _ remote: GitHubRemote, accessToken: String, cached: RepositoryResponse?
    ) async throws -> RepositoryResponse {
        var request = try authenticatedGET(path: "/repos/\(remote.owner)/\(remote.repository)", accessToken: accessToken)
        request.setValue(cached?.etag, forHTTPHeaderField: "If-None-Match")
        let response = try await receive(request, allowsNotModified: cached?.etag != nil)
        if response.status == 304, let cached { return cached }
        let metadata = try decode(GitHubRepositoryMetadata.self, from: response.body)
        guard metadata.id > 0, (1...256).contains(metadata.fullName.utf8.count),
              metadata.defaultBranch.utf8.count <= 1024, metadata.visibility.utf8.count <= 32
        else { throw GitHubTransportError.invalidPayload }
        let etag = response.etag.flatMap { $0.utf8.count <= 512 ? $0 : nil }
        return RepositoryResponse(metadata: metadata, etag: etag)
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
        let response = try await receive(request)
        return try decode(decoding, from: response.body)
    }

    private func decode<Response: Decodable>(_ type: Response.Type, from body: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw GitHubTransportError.invalidPayload
        }
    }

    private struct ResponseBody {
        let body: Data
        let status: Int
        let etag: String?
    }

    private func receive(_ request: URLRequest, allowsNotModified: Bool = false) async throws -> ResponseBody {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw GitHubTransportError.invalidResponse }
            let status = response.statusCode
            if status == 304, allowsNotModified {
                try Task.checkCancellation()
                return ResponseBody(body: Data(), status: status, etag: nil)
            }
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            if status == 429 || (status == 403 && (retryAfter != nil || remaining == "0")) {
                let now = Date()
                let delay = retryAfter.flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
                let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Int.init)
                let until = delay.map { now.addingTimeInterval(Double($0)) }
                    ?? reset.map { Date(timeIntervalSince1970: Double($0)) }
                    ?? now.addingTimeInterval(60)
                throw GitHubTransportError.rateLimited(until: max(now, until))
            }
            guard (200...299).contains(status) else {
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
            return ResponseBody(body: body, status: status, etag: response.value(forHTTPHeaderField: "ETag"))
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
