import Foundation

/// The one HTTP seam of the adapter manager. Production uses `IDEACPURLSessionFetcher`; tests
/// pass fixtures, so no ordinary test touches the network.
protocol IDEACPHTTPFetching: Sendable {
    /// Returns the body and the HTTP status. Throws `URLError` for transport failures.
    func fetch(_ request: URLRequest) async throws -> (data: Data, status: Int)
}

/// `URLSession` with no cookies, no cache, a short timeout, and redirects that leave the
/// request's host refused.
final class IDEACPURLSessionFetcher: NSObject, IDEACPHTTPFetching, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func fetch(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http.statusCode)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let original = task.originalRequest?.url
        if request.url?.host == original?.host, request.url?.scheme == "https" {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}

/// What the registry says about one published version. Only fields the trust policy and the
/// UI read are decoded.
struct IDEACPPackageVersion: Decodable, Equatable, Sendable {
    struct Signature: Decodable, Equatable, Sendable {
        var keyid: String
        var sig: String
    }

    struct Attestations: Decodable, Equatable, Sendable {
        var url: String
    }

    struct Dist: Decodable, Equatable, Sendable {
        var integrity: String?
        var tarball: String?
        var unpackedSize: Int64?
        var signatures: [Signature]?
        var attestations: Attestations?
    }

    struct TrustedPublisher: Decodable, Equatable, Sendable {
        var id: String
    }

    struct NpmUser: Decodable, Equatable, Sendable {
        var name: String?
        var trustedPublisher: TrustedPublisher?
    }

    var name: String
    var version: String
    var dist: Dist
    var engines: [String: String]?
    var os: [String]?
    var cpu: [String]?
    var deprecated: String?
    var npmUser: NpmUser?
    /// Repository URL as published, for example `git+https://github.com/o/r.git`.
    var repositoryURL: String?

    private enum CodingKeys: String, CodingKey {
        case name, version, dist, engines, os, cpu, deprecated, repository
        case npmUser = "_npmUser"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        dist = try container.decode(Dist.self, forKey: .dist)
        engines = try? container.decodeIfPresent([String: String].self, forKey: .engines)
        os = try? container.decodeIfPresent([String].self, forKey: .os)
        cpu = try? container.decodeIfPresent([String].self, forKey: .cpu)
        deprecated = try? container.decodeIfPresent(String.self, forKey: .deprecated)
        npmUser = try? container.decodeIfPresent(NpmUser.self, forKey: .npmUser)
        if let text = try? container.decodeIfPresent(String.self, forKey: .repository) {
            repositoryURL = text
        } else if let object = try? container.decodeIfPresent([String: String].self, forKey: .repository) {
            repositoryURL = object["url"]
        }
    }

    init(
        name: String, version: String, dist: Dist, engines: [String: String]? = nil, os: [String]? = nil,
        cpu: [String]? = nil, deprecated: String? = nil, npmUser: NpmUser? = nil, repositoryURL: String? = nil
    ) {
        self.name = name
        self.version = version
        self.dist = dist
        self.engines = engines
        self.os = os
        self.cpu = cpu
        self.deprecated = deprecated
        self.npmUser = npmUser
        self.repositoryURL = repositoryURL
    }

    /// `git+https://github.com/o/r.git` and `https://github.com/o/r` compare equal.
    var normalizedRepository: String? { Self.normalizeRepository(repositoryURL) }

    static func normalizeRepository(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else { return nil }
        if text.hasPrefix("git+") { text.removeFirst(4) }
        if text.hasPrefix("git://") { text = "https://" + text.dropFirst(6) }
        if text.hasSuffix(".git") { text.removeLast(4) }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// A client for the public npm registry. Metadata only: it never downloads a tarball, and
/// nothing it reads is executed.
struct IDEACPNpmRegistry: Sendable {
    static let host = "registry.npmjs.org"

    let fetcher: any IDEACPHTTPFetching

    init(fetcher: any IDEACPHTTPFetching = IDEACPURLSessionFetcher()) {
        self.fetcher = fetcher
    }

    /// The version `latest` points at.
    func latest(package: String) async throws -> IDEACPPackageVersion {
        try await versionDocument(package: package, tag: "latest")
    }

    func version(package: String, version: String) async throws -> IDEACPPackageVersion {
        try await versionDocument(package: package, tag: version)
    }

    private func versionDocument(package: String, tag: String) async throws -> IDEACPPackageVersion {
        let url = try Self.url(path: "/\(Self.encode(package))/\(tag)")
        let data = try await get(url)
        do {
            return try JSONDecoder().decode(IDEACPPackageVersion.self, from: data)
        } catch {
            throw IDEACPAdapterError.registry("The version document for \(package) could not be read.")
        }
    }

    /// The provenance bundle the version points at, or nil when it publishes none.
    func attestations(for version: IDEACPPackageVersion) async throws -> Data? {
        guard let text = version.dist.attestations?.url else { return nil }
        guard let url = URL(string: text), url.scheme == "https", url.host == Self.host else {
            throw IDEACPAdapterError.untrusted("The provenance link points outside \(Self.host).")
        }
        return try await get(url)
    }

    /// Titles of the advisories that apply to `version`. Empty when there are none.
    func advisories(package: String, version: String) async throws -> [String] {
        let url = try Self.url(path: "/-/npm/v1/security/advisories/bulk")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [package: [version]])
        let data = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IDEACPAdapterError.registry("The advisory answer could not be read.")
        }
        let entries = object[package] as? [[String: Any]] ?? []
        return entries.compactMap { $0["title"] as? String }
    }

    // MARK: - HTTP

    static func encode(_ package: String) -> String {
        package.replacingOccurrences(of: "/", with: "%2f")
    }

    static func url(path: String) throws -> URL {
        guard let url = URL(string: "https://\(host)\(path)") else {
            throw IDEACPAdapterError.registry("Bad registry address.")
        }
        return url
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        guard request.url?.host == Self.host else {
            throw IDEACPAdapterError.untrusted("Refused a request outside \(Self.host).")
        }
        do {
            let (data, status) = try await fetcher.fetch(request)
            guard (200..<300).contains(status) else {
                throw IDEACPAdapterError.registry("The registry answered HTTP \(status).")
            }
            return data
        } catch let error as IDEACPAdapterError {
            throw error
        } catch is CancellationError {
            throw IDEACPAdapterError.cancelled
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw IDEACPAdapterError.cancelled
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
                 .secureConnectionFailed:
                throw IDEACPAdapterError.offline("(\(error.localizedDescription))")
            default:
                throw IDEACPAdapterError.registry(error.localizedDescription)
            }
        } catch {
            throw IDEACPAdapterError.registry(error.localizedDescription)
        }
    }
}
