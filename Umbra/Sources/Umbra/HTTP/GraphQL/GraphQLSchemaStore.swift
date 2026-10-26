import CryptoKit
import Foundation

/// What to fetch for a `###@scheme:` line: the schema's URL (http, https or a file) and the headers to
/// send with it. Headers do not take part in equality: one URL is one schema.
struct GraphQLSchemaRequest: Hashable, Sendable {
    let url: URL
    let headers: [String: String]

    init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }

    static func == (lhs: GraphQLSchemaRequest, rhs: GraphQLSchemaRequest) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    /// Whether the store may fetch this by itself, without the user asking. A file on this Mac, an
    /// `https` address and a server on this machine qualify. A plain `http` address to somewhere
    /// else waits for Refresh, so opening a file never reaches a host nobody chose.
    var isAutomaticallyFetchable: Bool {
        switch url.scheme?.lowercased() {
        case "file", "https":
            return true
        case "http":
            let host = url.host?.lowercased() ?? ""
            return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
        default:
            return false
        }
    }
}

enum GraphQLSchemaError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case http(Int)
    case noTypes
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let message): message
        case .http(let status): "The server answered with status \(status)."
        case .noTypes: "No GraphQL types were found."
        case .failed(let message): message
        }
    }
}

/// Reads `###@scheme:` URLs into schemas and keeps them: in memory for this window, and on disk so a
/// relaunch completes at once while a fresh copy loads behind it.
///
/// `schema(for:)` never waits for the network: it returns what it has and starts a load when there is
/// none, and the next keystroke finds the result. A failure is remembered for a minute so a dead
/// server is not asked on every keystroke, and keeps the schema that was already loaded.
actor GraphQLSchemaStore {
    enum State: Sendable {
        case loading
        case loaded(types: Int, date: Date)
        case failed(message: String, date: Date)
    }

    static let maximumResponseBytes = 20 * 1024 * 1024
    static let requestTimeout: TimeInterval = 15
    static let failureBackoff: TimeInterval = 60

    private struct Entry {
        var schema: GraphQLSchema?
        var loadedAt: Date?
        var failure: (message: String, date: Date)?
        var task: Task<Void, Never>?
        /// The schema came from the disk copy and has not been refreshed since.
        var isFromDisk = false
        var generation = 0
    }

    private let session: URLSession
    private let cacheDirectory: URL?
    private var entries: [URL: Entry] = [:]

    init(session: URLSession? = nil, cacheDirectory: URL? = GraphQLSchemaStore.defaultCacheDirectory()) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
        self.cacheDirectory = cacheDirectory
    }

    static func defaultCacheDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("GraphQLSchemas", isDirectory: true)
    }

    // MARK: - Reading

    /// The loaded schema, if any. Starts a load when nothing has been tried or the last try failed
    /// more than a minute ago.
    func schema(for request: GraphQLSchemaRequest) -> GraphQLSchema? {
        ensureLoading(request)
        return entries[request.url]?.schema
    }

    func prefetch(_ request: GraphQLSchemaRequest) {
        ensureLoading(request)
    }

    func state(for url: URL) -> State? {
        guard let entry = entries[url] else { return nil }
        if let schema = entry.schema, let date = entry.loadedAt {
            return .loaded(types: schema.types.values.filter { !$0.name.hasPrefix("__") }.count, date: date)
        }
        if let failure = entry.failure {
            return .failed(message: failure.message, date: failure.date)
        }
        return entry.task == nil ? nil : .loading
    }

    // MARK: - Refreshing

    /// Fetches now, whatever is cached, whatever the address (the user asked), and returns the result.
    @discardableResult
    func refresh(_ request: GraphQLSchemaRequest) async throws -> GraphQLSchema {
        var entry = entries[request.url] ?? Entry()
        entry.task?.cancel()
        entry.task = nil
        entry.generation += 1
        let generation = entry.generation
        entries[request.url] = entry
        do {
            let schema = try await Self.fetch(request, session: session)
            record(schema, for: request.url, generation: generation)
            return schema
        } catch {
            recordFailure(error, for: request.url, generation: generation)
            throw error
        }
    }

    // MARK: - Loading

    private func ensureLoading(_ request: GraphQLSchemaRequest) {
        var entry = entries[request.url] ?? Entry()
        if entry.task != nil {
            return
        }
        if entry.schema == nil, entry.failure == nil, entry.generation == 0, let cached = readCache(for: request.url) {
            entry.schema = cached.schema
            entry.loadedAt = cached.date
            entry.isFromDisk = true
        }
        let wantsRefresh = entry.schema == nil || entry.isFromDisk
        let backoffOver = entry.failure.map { Date().timeIntervalSince($0.date) > Self.failureBackoff } ?? true
        guard wantsRefresh, backoffOver, request.isAutomaticallyFetchable else {
            entries[request.url] = entry
            return
        }
        entry.generation += 1
        let generation = entry.generation
        entry.failure = nil
        let session = self.session
        entry.task = Task { [weak self] in
            do {
                let schema = try await Self.fetch(request, session: session)
                await self?.record(schema, for: request.url, generation: generation)
            } catch {
                await self?.recordFailure(error, for: request.url, generation: generation)
            }
        }
        entries[request.url] = entry
    }

    /// A result that a newer load or refresh overtook is dropped.
    private func record(_ schema: GraphQLSchema, for url: URL, generation: Int) {
        guard var entry = entries[url], entry.generation == generation else { return }
        entry.schema = schema
        entry.loadedAt = Date()
        entry.failure = nil
        entry.task = nil
        entry.isFromDisk = false
        entries[url] = entry
        writeCache(schema, for: url)
    }

    private func recordFailure(_ error: Error, for url: URL, generation: Int) {
        guard var entry = entries[url], entry.generation == generation else { return }
        if error is CancellationError {
            entry.task = nil
            entries[url] = entry
            return
        }
        entry.failure = (error.localizedDescription, Date())
        entry.task = nil
        // A schema that was loaded stays usable; it is not fresh, which is all the failure says.
        entry.isFromDisk = false
        entries[url] = entry
    }

    // MARK: - Fetching

    static func fetch(_ request: GraphQLSchemaRequest, session: URLSession) async throws -> GraphQLSchema {
        let url = request.url
        if url.isFileURL {
            return try readFile(url)
        }
        let ext = url.pathExtension.lowercased()
        if ["graphql", "graphqls", "gql", "sdl"].contains(ext) {
            return try await get(request, session: session)
        }
        if ext == "json" {
            return try await get(request, session: session)
        }
        do {
            return try await introspect(request, session: session)
        } catch is CancellationError {
            throw CancellationError()
        } catch let postError {
            // Some servers serve the schema as a document at this address instead.
            do {
                return try await get(request, session: session)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw postError
            }
        }
    }

    private static func readFile(_ url: URL) throws -> GraphQLSchema {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GraphQLSchemaError.unreadable("Could not read \(url.path).")
        }
        return try decode(data)
    }

    private static func introspect(_ request: GraphQLSchemaRequest, session: URLSession) async throws -> GraphQLSchema {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: requestTimeout)
        urlRequest.httpMethod = "POST"
        apply(request.headers, to: &urlRequest)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = GraphQLIntrospection.requestBody
        return try decode(try await data(for: urlRequest, session: session))
    }

    private static func get(_ request: GraphQLSchemaRequest, session: URLSession) async throws -> GraphQLSchema {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: requestTimeout)
        urlRequest.httpMethod = "GET"
        apply(request.headers, to: &urlRequest)
        urlRequest.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        return try decode(try await data(for: urlRequest, session: session))
    }

    private static func apply(_ headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers {
            let lowered = name.lowercased()
            if lowered == "content-length" || lowered == "content-type" || lowered == "accept" || lowered == "host" {
                continue
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private static func data(for request: URLRequest, session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GraphQLSchemaError.unreadable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // A GraphQL server may answer a valid introspection with an error status.
            if (try? decode(data)) != nil {
                return data
            }
            throw GraphQLSchemaError.http(http.statusCode)
        }
        guard data.count <= maximumResponseBytes else {
            throw GraphQLSchemaError.unreadable("The schema is larger than 20 MB.")
        }
        return data
    }

    /// An introspection answer, or SDL. JSON starts with `{`; SDL never does.
    static func decode(_ data: Data) throws -> GraphQLSchema {
        guard data.count <= maximumResponseBytes else {
            throw GraphQLSchemaError.unreadable("The schema is larger than 20 MB.")
        }
        let first = data.first { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 && $0 != 0xEF && $0 != 0xBB && $0 != 0xBF }
        if first == 0x7B {
            do {
                return try GraphQLIntrospection.decode(data)
            } catch let error as GraphQLIntrospection.DecodeError {
                throw GraphQLSchemaError.failed(error.localizedDescription)
            }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw GraphQLSchemaError.unreadable("The schema is not text.")
        }
        let schema = GraphQLSDLParser.parse(text)
        guard schema.types.values.contains(where: { !GraphQLSchema.builtInScalars.contains($0.name) }) else {
            throw GraphQLSchemaError.noTypes
        }
        return schema
    }

    // MARK: - Disk cache

    private func cacheFile(for url: URL) -> URL? {
        guard let cacheDirectory else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(digest + ".json")
    }

    private func readCache(for url: URL) -> (schema: GraphQLSchema, date: Date)? {
        guard let file = cacheFile(for: url),
              let data = try? Data(contentsOf: file),
              let schema = try? JSONDecoder().decode(GraphQLSchema.self, from: data) else { return nil }
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return (schema, date)
    }

    private func writeCache(_ schema: GraphQLSchema, for url: URL) {
        guard let file = cacheFile(for: url), let data = try? JSONEncoder().encode(schema) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
