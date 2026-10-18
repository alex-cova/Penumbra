import Foundation
@preconcurrency import MongoKitten

/// What `MongoSession` opens. The password stays here, never on ``DatabaseConnection``.
public struct MongoLogin: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var authSource: String
    public var defaultDatabase: String
    public var useTLS: Bool
    /// DNS seed list (`mongodb+srv://`). Implies a single host with no port; TLS defaults to on.
    public var useSRV: Bool
    public var replicaSet: String
    /// `directConnection` — only meaningful for a standard URI without a replica set.
    public var directConnection: Bool

    public init(
        host: String = "localhost",
        port: Int = 27017,
        username: String = "",
        password: String = "",
        authSource: String = "admin",
        defaultDatabase: String = "admin",
        useTLS: Bool = false,
        useSRV: Bool = false,
        replicaSet: String = "",
        directConnection: Bool = true
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.authSource = authSource
        self.defaultDatabase = defaultDatabase
        self.useTLS = useTLS
        self.useSRV = useSRV
        self.replicaSet = replicaSet
        self.directConnection = directConnection
    }
}

enum MongoURLs {
    static func connectionURI(from login: MongoLogin) -> String {
        let database = sanitizedDatabaseName(login.defaultDatabase)
        var authSource = login.authSource.trimmingCharacters(in: .whitespacesAndNewlines)
        if authSource.isEmpty { authSource = "admin" }
        let replicaSet = login.replicaSet.trimmingCharacters(in: .whitespacesAndNewlines)

        var authority = ""
        if !login.username.isEmpty {
            let user = percentEncode(login.username)
            if login.password.isEmpty {
                authority = "\(user)@"
            } else {
                authority = "\(user):\(percentEncode(login.password))@"
            }
        }

        let scheme = login.useSRV ? "mongodb+srv" : "mongodb"
        let hostPart = login.useSRV ? login.host : "\(login.host):\(login.port)"
        var uri = "\(scheme)://\(authority)\(hostPart)/\(database)"

        var query: [String] = []
        if !login.useSRV {
            if !replicaSet.isEmpty {
                query.append("replicaSet=\(percentEncode(replicaSet))")
            }
            if replicaSet.isEmpty, login.directConnection {
                query.append("directConnection=true")
            }
        } else if !replicaSet.isEmpty {
            query.append("replicaSet=\(percentEncode(replicaSet))")
        }
        if !login.username.isEmpty {
            query.append("authSource=\(percentEncode(authSource))")
        }
        if login.useSRV {
            if !login.useTLS { query.append("tls=false") }
        } else if login.useTLS {
            query.append("tls=true")
        }
        if !query.isEmpty {
            uri += "?" + query.joined(separator: "&")
        }
        return uri
    }

    /// Same URI with the password replaced by `***`.
    static func redactedURI(from login: MongoLogin) -> String {
        guard !login.password.isEmpty else { return connectionURI(from: login) }
        return connectionURI(from: login).replacingOccurrences(of: percentEncode(login.password), with: "***")
    }

    static func parse(_ raw: String) throws -> MongoLogin {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DatabaseError.invalidURL(raw)
        }
        let lower = trimmed.lowercased()
        let useSRV: Bool
        if lower.hasPrefix("mongodb+srv://") {
            useSRV = true
        } else if lower.hasPrefix("mongodb://") {
            useSRV = false
        } else {
            throw DatabaseError.invalidURL(trimmed)
        }

        let normalized = normalizeQuerySeparators(trimmed)
        let components: URLComponents
        if let parsed = URLComponents(string: normalized), parsed.host != nil {
            components = parsed
        } else {
            components = try hierarchicalComponents(from: normalized, useSRV: useSRV)
        }

        let (host, portFromAuthority) = try resolveHostAndPort(
            host: components.host,
            port: components.port,
            useSRV: useSRV
        )
        let port = useSRV ? 27017 : (portFromAuthority ?? 27017)
        guard (1 ... 65_535).contains(port) else {
            throw DatabaseError.executionFailed("Port must be between 1 and 65535.")
        }

        let username = percentDecode(components.percentEncodedUser ?? components.user ?? "")
        let password = percentDecode(components.percentEncodedPassword ?? components.password ?? "")
        let path = components.path
        let pathSpecified = !(path.isEmpty || path == "/")
        let database: String
        if !pathSpecified {
            database = "admin"
        } else {
            let stripped = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let segment = stripped.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map(String.init) ?? ""
            database = sanitizedDatabaseName(percentDecode(segment))
        }

        var authSource = (!username.isEmpty && pathSpecified) ? database : "admin"
        var sawAuthSource = false
        var useTLS = useSRV
        var sawTLSOption = false
        var replicaSet = ""
        var directConnection = !useSRV
        var sawDirectConnection = false

        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            let value = item.value ?? ""
            switch name {
            case "authsource":
                sawAuthSource = true
                let decoded = percentDecode(value)
                if !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    authSource = decoded
                }
            case "tls", "ssl":
                sawTLSOption = true
                useTLS = isTruthy(value)
            case "replicaset":
                replicaSet = percentDecode(value).trimmingCharacters(in: .whitespacesAndNewlines)
            case "directconnection":
                sawDirectConnection = true
                directConnection = isTruthy(value)
            default:
                break
            }
        }
        if useSRV, !sawTLSOption { useTLS = true }
        if !sawAuthSource, username.isEmpty { authSource = "admin" }
        if !useSRV, !replicaSet.isEmpty, !sawDirectConnection { directConnection = false }
        if useSRV { directConnection = false }

        return MongoLogin(
            host: host,
            port: port,
            username: username,
            password: password,
            authSource: authSource,
            defaultDatabase: database,
            useTLS: useTLS,
            useSRV: useSRV,
            replicaSet: replicaSet,
            directConnection: directConnection
        )
    }

    static func sanitizedDatabaseName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "admin" : trimmed
    }

    static func document(fromJSON json: String) throws -> Document {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Document() }
        guard let data = trimmed.data(using: .utf8) else {
            throw DatabaseError.invalidJSON("Not valid UTF-8.")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw DatabaseError.invalidJSON(error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else {
            throw DatabaseError.invalidJSON("Expected a JSON object.")
        }
        return try document(fromJSONObject: dictionary)
    }

    static func resultTable(from documents: [Document], columnLimit: Int = 40) -> QueryResult {
        var columns: [String] = ["_id"]
        var seen: Set<String> = ["_id"]
        for document in documents {
            guard columns.count < columnLimit else { break }
            for pair in document.pairs where pair.key != "_id" {
                guard !seen.contains(pair.key) else { continue }
                seen.insert(pair.key)
                columns.append(pair.key)
                if columns.count >= columnLimit { break }
            }
        }
        let rows = documents.map { document -> [String?] in
            columns.map { column in
                guard let value = document[column] else { return nil }
                return primitivePreview(value, stringLimit: 120)
            }
        }
        return QueryResult(columns: columns, rows: rows, rowsAffected: nil, isReadQuery: true)
    }

    private static func document(fromJSONObject object: [String: Any]) throws -> Document {
        var document = Document()
        for (key, value) in object {
            document[key] = try primitive(fromJSONValue: value)
        }
        return document
    }

    private static func primitive(fromJSONValue value: Any) throws -> Primitive {
        switch value {
        case is NSNull:
            return Null()
        case let string as String:
            return string
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            let doubleValue = number.doubleValue
            if doubleValue.rounded() == doubleValue,
               doubleValue >= Double(Int.min),
               doubleValue <= Double(Int.max),
               String(describing: number).contains(".") == false {
                return number.intValue
            }
            return doubleValue
        case let array as [Any]:
            var document = Document(isArray: true)
            for item in array {
                document.append(try primitive(fromJSONValue: item))
            }
            return document
        case let dict as [String: Any]:
            if dict.count == 1, let oid = dict["$oid"] as? String {
                guard let objectId = ObjectId(oid) else {
                    throw DatabaseError.invalidJSON("Invalid ObjectId \"\(oid)\".")
                }
                return objectId
            }
            if dict.count == 1, let dateString = dict["$date"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString) {
                    return date
                }
                throw DatabaseError.invalidJSON("Invalid date \"\(dateString)\".")
            }
            return try document(fromJSONObject: dict)
        default:
            throw DatabaseError.invalidJSON("Unsupported JSON value \(value).")
        }
    }

    private static func primitivePreview(_ value: Primitive, stringLimit: Int = 40) -> String {
        switch value {
        case let objectId as ObjectId:
            return objectId.hexString
        case let string as String:
            return string.count > stringLimit ? String(string.prefix(stringLimit)) + "…" : string
        case let bool as Bool:
            return bool ? "true" : "false"
        case let int as Int:
            return String(int)
        case let int32 as Int32:
            return String(int32)
        case let double as Double:
            return String(double)
        case is Null:
            return "null"
        case let nested as Document:
            return nested.isArray ? "[…]" : "{…}"
        default:
            return String(describing: value)
        }
    }

    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func percentDecode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private static func isTruthy(_ value: String) -> Bool {
        ["true", "1", "yes"].contains(value.lowercased())
    }

    private static func normalizeQuerySeparators(_ raw: String) -> String {
        guard let question = raw.firstIndex(of: "?") else { return raw }
        let head = raw[..<question]
        let query = raw[raw.index(after: question)...].replacingOccurrences(of: ";", with: "&")
        return String(head) + "?" + query
    }

    private static func resolveHostAndPort(
        host: String?,
        port: Int?,
        useSRV: Bool
    ) throws -> (host: String, port: Int?) {
        guard var host, !host.isEmpty else {
            throw DatabaseError.executionFailed("Connection URI is missing a host.")
        }
        if host.contains(",") {
            host = String(host.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)[0])
        }
        if useSRV {
            if host.contains(":") || port != nil {
                throw DatabaseError.executionFailed(
                    "mongodb+srv:// must not include a port; DNS SRV records supply ports."
                )
            }
            return (host, nil)
        }
        if let port { return (host, port) }
        if let colon = host.lastIndex(of: ":"),
           colon > host.startIndex,
           let parsedPort = Int(host[host.index(after: colon)...]),
           !host[host.index(after: colon)...].isEmpty {
            let name = String(host[..<colon])
            guard !name.isEmpty else {
                throw DatabaseError.executionFailed("Connection URI is missing a host.")
            }
            return (name, parsedPort)
        }
        return (host, nil)
    }

    private static func hierarchicalComponents(from raw: String, useSRV: Bool) throws -> URLComponents {
        let prefix = useSRV ? "mongodb+srv://" : "mongodb://"
        let withoutScheme = String(raw.dropFirst(prefix.count))
        let authorityAndRest: String
        let userinfo: String?
        if let at = withoutScheme.firstIndex(of: "@") {
            userinfo = String(withoutScheme[..<at])
            authorityAndRest = String(withoutScheme[withoutScheme.index(after: at)...])
        } else {
            userinfo = nil
            authorityAndRest = withoutScheme
        }
        let hostPort: String
        let pathAndQuery: String
        if let slash = authorityAndRest.firstIndex(of: "/") {
            hostPort = String(authorityAndRest[..<slash])
            pathAndQuery = String(authorityAndRest[slash...])
        } else if let question = authorityAndRest.firstIndex(of: "?") {
            hostPort = String(authorityAndRest[..<question])
            pathAndQuery = String(authorityAndRest[question...])
        } else {
            hostPort = authorityAndRest
            pathAndQuery = ""
        }
        guard !hostPort.isEmpty else {
            throw DatabaseError.executionFailed("Connection URI is missing a host.")
        }
        let firstHost = hostPort.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? hostPort
        var rebuilt = prefix
        if let userinfo { rebuilt += userinfo + "@" }
        rebuilt += firstHost
        rebuilt += pathAndQuery.isEmpty ? "/" : pathAndQuery
        guard let components = URLComponents(string: rebuilt), components.host != nil else {
            throw DatabaseError.executionFailed("Could not parse connection URI.")
        }
        return components
    }
}

/// One MongoDB cluster. Connect races a short timeout because the driver's own is several minutes.
public final class MongoSession: @unchecked Sendable {
    public static let testConnectTimeout: TimeInterval = 5
    public static let connectTimeout: TimeInterval = 10

    private let database: MongoDatabase
    public let readOnly: Bool

    private init(database: MongoDatabase, readOnly: Bool) {
        self.database = database
        self.readOnly = readOnly
    }

    public static func connect(
        login: MongoLogin,
        readOnly: Bool,
        timeout: TimeInterval = connectTimeout
    ) async throws -> MongoSession {
        let database = try await openDatabase(login: login, timeout: timeout)
        return MongoSession(database: database, readOnly: readOnly)
    }

    public static func test(login: MongoLogin) async throws {
        let session = try await connect(login: login, readOnly: true, timeout: testConnectTimeout)
        _ = try await session.listDatabases()
        await session.disconnect()
    }

    public func disconnect() async {
        if let cluster = database.pool as? MongoCluster {
            await cluster.disconnect()
        }
    }

    public func listDatabases() async throws -> [String] {
        let databases = try await database.pool.listDatabases()
        return databases.map(\.name).sorted()
    }

    public func listCollections(database name: String) async throws -> [String] {
        let collections = try await database.pool[name].listCollections()
        return collections.map(\.name).sorted()
    }

    public func find(
        database databaseName: String,
        collection: String,
        filterJSON: String,
        skip: Int = 0,
        limit: Int = DatabasePageSize.mongo
    ) async throws -> QueryResult {
        let filter = try MongoURLs.document(fromJSON: filterJSON)
        let documents = try await database.pool[databaseName][collection]
            .find(filter)
            .skip(max(0, skip))
            .limit(max(1, limit))
            .drain()
        return MongoURLs.resultTable(from: documents)
    }

    public func insert(database databaseName: String, collection: String, documentJSON: String) async throws {
        try ensureWritable()
        let document = try MongoURLs.document(fromJSON: documentJSON)
        _ = try await database.pool[databaseName][collection].insert(document)
    }

    public func replace(database databaseName: String, collection: String, documentJSON: String) async throws {
        try ensureWritable()
        let document = try MongoURLs.document(fromJSON: documentJSON)
        guard let id = document["_id"] else { throw DatabaseError.missingDocumentID }
        _ = try await database.pool[databaseName][collection].updateOne(where: ["_id": id], to: document)
    }

    public func delete(database databaseName: String, collection: String, idJSON: String) async throws {
        try ensureWritable()
        let document = try MongoURLs.document(fromJSON: idJSON)
        guard let id = document["_id"] else { throw DatabaseError.missingDocumentID }
        _ = try await database.pool[databaseName][collection].deleteOne(where: ["_id": id])
    }

    private func ensureWritable() throws {
        guard !readOnly else { throw DatabaseError.readOnlyViolation }
    }

    private static func openDatabase(login: MongoLogin, timeout: TimeInterval) async throws -> MongoDatabase {
        let uri = MongoURLs.connectionURI(from: login)
        return try await withThrowingTaskGroup(of: MongoDatabaseBox.self) { group in
            group.addTask {
                var settings = try ConnectionSettings(uri)
                settings.connectTimeout = timeout
                settings.socketTimeout = timeout
                return MongoDatabaseBox(try await MongoDatabase.connect(to: settings))
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw DatabaseError.connectionTimedOut(timeout)
            }
            defer { group.cancelAll() }
            guard let box = try await group.next() else {
                throw DatabaseError.connectionTimedOut(timeout)
            }
            return box.database
        }
    }
}

private final class MongoDatabaseBox: @unchecked Sendable {
    let database: MongoDatabase
    init(_ database: MongoDatabase) { self.database = database }
}
