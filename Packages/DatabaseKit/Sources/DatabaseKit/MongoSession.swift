import Foundation

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

/// MongoDB for the app: statements on one connection, catalog reads on another, so browsing the
/// explorer never waits behind a running query. Every value goes through `BSONValue` and Extended
/// JSON, so nothing is converted through `Double` or `JSONSerialization` on the way in or out.
public actor MongoSession {
    public static let testConnectTimeout: TimeInterval = 5
    public static let connectTimeout: TimeInterval = 10

    public nonisolated let readOnly: Bool
    /// The document-level API, for callers that work with documents rather than table rows.
    public let console: MongoDocumentSession
    private let login: MongoLogin
    private var metadata: MongoDocumentSession?
    private let metadataGate = AsyncMutex()

    private init(console: MongoDocumentSession, login: MongoLogin, readOnly: Bool) {
        self.console = console
        self.login = login
        self.readOnly = readOnly
    }

    public static func connect(
        login: MongoLogin, readOnly: Bool, timeout: TimeInterval = connectTimeout
    ) async throws -> MongoSession {
        let console = try await MongoDocumentSession.connect(login: login, readOnly: readOnly, timeout: timeout)
        return MongoSession(console: console, login: login, readOnly: readOnly)
    }

    public static func test(login: MongoLogin) async throws {
        try await MongoDocumentSession.test(login: login)
    }

    public func disconnect() async {
        let metadataSession = metadata
        metadata = nil
        await console.close()
        await metadataSession?.close()
    }

    public func cancelRunning() async {
        await console.cancelRunning()
    }

    private func withMetadata<T: Sendable>(_ body: (MongoDocumentSession) async throws -> T) async throws -> T {
        await metadataGate.lock()
        do {
            let session: MongoDocumentSession
            if let metadata {
                session = metadata
            } else {
                session = try await MongoDocumentSession.connect(login: login, readOnly: true)
                metadata = session
            }
            let value = try await body(session)
            await metadataGate.unlock()
            return value
        } catch {
            await metadataGate.unlock()
            throw error
        }
    }

    public func listDatabases() async throws -> [String] {
        try await withMetadata { try await $0.listDatabases().map(\.name) }
    }

    public func listCollections(database name: String) async throws -> [String] {
        try await withMetadata { try await $0.listCollections(database: name).map(\.name) }
    }

    /// One page of a collection as table rows. `filterJSON` is Extended JSON; an empty box matches
    /// everything. The sort is the server's (`sortKey`), not a re-ordering of the page on screen.
    public func find(
        database: String,
        collection: String,
        filterJSON: String,
        sortKey: String? = nil,
        sortAscending: Bool = true,
        skip: Int = 0,
        limit: Int = DatabasePageSize.mongo
    ) async throws -> QueryResult {
        let filter = try Self.filter(from: filterJSON)
        var request = MongoFindRequest(
            database: database, collection: collection, filter: filter,
            skip: max(0, skip), limit: max(1, limit), batchSize: max(1, limit)
        )
        if let sortKey, !sortKey.isEmpty {
            request.sort = BSONDocument([sortKey: .int32(sortAscending ? 1 : -1)])
        }
        do {
            let documents = try await console.findDocuments(request, limit: request.limit)
            return MongoTable.result(from: documents)
        } catch is CancellationError {
            return QueryResult(columns: [], rows: [], rowsAffected: nil, isReadQuery: true, wasCancelled: true)
        }
    }

    /// Streams one cursor into the flat console grid while retaining typed field values.
    public func find(
        database: String, collection: String, filterJSON: String,
        sortKey: String? = nil, sortAscending: Bool = true, into store: ResultStore
    ) async throws -> ExecutionSummary {
        var request = MongoFindRequest(
            database: database, collection: collection, filter: try Self.filter(from: filterJSON), batchSize: 256
        )
        if let sortKey, !sortKey.isEmpty {
            request.sort = BSONDocument([sortKey: .int32(sortAscending ? 1 : -1)])
        }
        return try await console.findTable(request, into: store)
    }

    public func insert(database: String, collection: String, documentJSON: String) async throws {
        let document = try Self.document(from: documentJSON)
        _ = try await console.insertOne(database: database, collection: collection, document: document)
    }

    /// Replaces the whole document that has this `_id`. Prefer `setFields` for an edit: it changes
    /// only the fields named and cannot overwrite a concurrent change to the others.
    public func replace(database: String, collection: String, documentJSON: String) async throws {
        let document = try Self.document(from: documentJSON)
        guard let id = document["_id"] else { throw DatabaseError.missingDocumentID }
        let result = try await console.updateOne(
            database: database, collection: collection, filter: BSONDocument(["_id": id]), update: document
        )
        guard result.matched == 1 else {
            throw DatabaseError.executionFailed("The document is no longer there; nothing was replaced.")
        }
    }

    /// Sets (and unsets) top-level fields of one document. `expected` holds the values the caller
    /// last saw for those fields: if any has changed since, nothing is written and the call
    /// throws, so a concurrent edit is never silently overwritten.
    public func setFields(
        database: String, collection: String, idJSON: String, setJSON: String, unset: [String] = [],
        expectedJSON: String = ""
    ) async throws {
        let idDocument = try Self.document(from: idJSON)
        guard let id = idDocument["_id"] else { throw DatabaseError.missingDocumentID }
        var filter = BSONDocument(["_id": id])
        for field in try Self.document(from: expectedJSON.isEmpty ? "{}" : expectedJSON).fields where field.key != "_id" {
            // A field that was absent is matched as absent, not as null.
            filter[field.key] = field.value == .undefined
                ? .document(BSONDocument(["$exists": .bool(false)])) : field.value
        }
        var update = BSONDocument()
        let setDocument = try Self.document(from: setJSON.isEmpty ? "{}" : setJSON)
        if !setDocument.isEmpty { update["$set"] = .document(setDocument) }
        if !unset.isEmpty {
            update["$unset"] = .document(BSONDocument(unset.map { BSONField($0, .string("")) }))
        }
        guard !update.isEmpty else { return }
        let result = try await console.updateOne(database: database, collection: collection, filter: filter, update: update)
        guard result.matched == 1 else {
            throw DatabaseError.executionFailed(
                "The document changed or was deleted since it was read; nothing was written."
            )
        }
    }

    public func delete(database: String, collection: String, idJSON: String) async throws {
        let document = try Self.document(from: idJSON)
        guard let id = document["_id"] else { throw DatabaseError.missingDocumentID }
        _ = try await console.deleteOne(database: database, collection: collection, filter: BSONDocument(["_id": id]))
    }

    static func filter(from json: String) throws -> BSONDocument {
        do {
            return try ExtendedJSON.parseDocument(json)
        } catch {
            throw DatabaseError.invalidJSON(error.localizedDescription)
        }
    }

    static func document(from json: String) throws -> BSONDocument {
        try filter(from: json)
    }
}

/// Documents as table rows for the string-based result the console still shows. The document
/// views read `BSONDocument` directly; this is only the flat projection of the top level.
public enum MongoTable {
    public static let columnLimit = 40

    /// Columns are `_id` then every other top-level key in order of first appearance. A missing
    /// field is `nil`; an explicit `null` is the text `null`.
    public static func result(from documents: [BSONDocument]) -> QueryResult {
        var columns: [String] = ["_id"]
        var seen: Set<String> = ["_id"]
        outer: for document in documents {
            for field in document.fields where !seen.contains(field.key) {
                if columns.count >= columnLimit { break outer }
                seen.insert(field.key)
                columns.append(field.key)
            }
        }
        let rows = documents.map { document in columns.map { document[$0].map(cellText) } }
        return QueryResult(columns: columns, rows: rows, rowsAffected: nil, isReadQuery: true)
    }

    public static func cellText(_ value: BSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .objectId: return value.objectIdHex ?? ""
        case .int32(let number): return String(number)
        case .int64(let number): return String(number)
        case .double(let number): return DatabaseValue.format(double: number)
        case .decimal128(let decimal): return decimal.description
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .date(let milliseconds):
            return ExtendedJSON.isoString(milliseconds: milliseconds) ?? "date(\(milliseconds))"
        case .binary(_, let bytes): return "‹binary, \(bytes.count) bytes›"
        default:
            let text = ExtendedJSON.string(value, mode: .relaxed)
            return text.count > DatabaseValue.displayLimit ? String(text.prefix(DatabaseValue.displayLimit)) + "…" : text
        }
    }

    static func typedCell(_ value: BSONValue, limits: ValueLimits = .current) -> DatabaseValue {
        func bounded(_ text: String, as makeValue: (String) -> DatabaseValue) -> DatabaseValue {
            let count = text.utf8.count
            guard count > limits.maxTextBytes else { return makeValue(text) }
            var end = text.utf8.index(text.utf8.startIndex, offsetBy: limits.maxTextBytes)
            while end > text.utf8.startIndex, text.utf8[end] & 0xC0 == 0x80 {
                end = text.utf8.index(before: end)
            }
            return .truncated(preview: String(decoding: text.utf8[..<end], as: UTF8.self), fullCount: count)
        }

        switch value {
        case .null: return .null
        case .string(let text): return bounded(text, as: DatabaseValue.text)
        case .int32(let number): return .int(Int64(number))
        case .int64(let number): return .int(number)
        case .decimal128(let decimal): return .decimal(decimal.description)
        case .double(let number): return .double(number)
        case .bool(let flag): return .bool(flag)
        case .binary(_, let bytes): return .bytes(count: bytes.count, prefix: Array(bytes.prefix(limits.binaryPrefix)))
        default:
            return bounded(ExtendedJSON.string(value, mode: .canonical)) { .bson(typeName: value.typeName, extendedJSON: $0) }
        }
    }
}

/// Field changes for one document, identified by the `_id` cell the grid shows.
public struct MongoFieldUpdate: Equatable, Sendable {
    public struct Change: Equatable, Sendable {
        public let field: String
        public let original: DatabaseValue
        public let replacement: DatabaseValue

        public init(field: String, original: DatabaseValue, replacement: DatabaseValue) {
            self.field = field
            self.original = original
            self.replacement = replacement
        }
    }

    public let id: DatabaseValue
    public let changes: [Change]

    public init(id: DatabaseValue, changes: [Change]) {
        self.id = id
        self.changes = changes
    }

    /// The shell form shown before anything is written.
    public func preview(collection: String) -> String {
        let id = (try? MongoSession.idValue(self.id)).map { ExtendedJSON.string($0, mode: .canonical) } ?? "<_id>"
        let set = changes.map { "\($0.field): \(MongoSession.previewText($0.replacement))" }.joined(separator: ", ")
        let expected = changes.map { "\($0.field): \(MongoSession.previewText($0.original))" }.joined(separator: ", ")
        return "db.\(collection).updateOne(\n  { _id: \(id), \(expected) },\n  { $set: { \(set) } }\n)"
    }
}

extension MongoSession {
    static func previewText(_ value: DatabaseValue) -> String {
        switch value {
        case .missing: "<missing>"
        case .null: "null"
        case .text(let text): ExtendedJSON.string(.string(text), mode: .relaxed)
        default: value.rawText ?? "?"
        }
    }

    /// The `_id` as BSON. A binary or otherwise lossy cell cannot name its document exactly, so it
    /// is refused rather than guessed.
    static func idValue(_ cell: DatabaseValue) throws -> BSONValue {
        switch cell {
        case .text(let text): return .string(text)
        case .int(let number): return .int64(number)
        case .bson(let type, let json) where type == "objectId": return try ExtendedJSON.parse(json)
        default: throw DatabaseError.executionFailed("This _id cannot identify its document exactly.")
        }
    }

    /// A new value of the type the field already has: an int32 field stays int32 while the value
    /// fits, so an edit never changes a number's width by accident.
    static func bsonValue(_ value: DatabaseValue, replacing current: BSONValue?) throws -> BSONValue {
        switch value {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .text(let text): return .string(text)
        case .double(let number): return .double(number)
        case .int(let number):
            switch current {
            case .double?: return .double(Double(number))
            case .int64?: return .int64(number)
            default: return Int32(exactly: number).map(BSONValue.int32) ?? .int64(number)
            }
        default: throw DatabaseError.executionFailed("That value type cannot be written to a MongoDB field here.")
        }
    }

    /// One top-level field of the document `id` names, with the display bound lifted. A document
    /// that changed identity or vanished throws, so the answer is never another document's value.
    public func fetchFullValue(database: String, collection: String, id: DatabaseValue, field: String) async throws -> DatabaseValue {
        let request = MongoFindRequest(database: database, collection: collection,
                                       filter: BSONDocument(["_id": try Self.idValue(id)]), limit: 2)
        let limit = ValueLimits.fullValueLimit
        return try await ValueLimits.$override.withValue(ValueLimits(maxTextBytes: limit, binaryPrefix: limit)) {
            let documents = try await console.findDocuments(request, limit: 2)
            guard documents.count == 1, let document = documents.first else {
                throw DatabaseError.executionFailed("The document is no longer there.")
            }
            return document[field].map { MongoTable.typedCell($0) } ?? .missing
        }
    }

    /// Sets top-level fields one document at a time. Every document is read first and its fields
    /// compared with what the grid showed; nothing is written if any differs. Each write then
    /// filters on the exact `_id` and the exact current field values, so a change that lands
    /// between the read and the write matches nothing. MongoDB has no rollback across documents
    /// here: a server error after the first write reports how many documents were already changed.
    @discardableResult
    public func applyFieldUpdates(
        database: String, collection: String, updates: [MongoFieldUpdate]
    ) async throws -> SQLMutationResult {
        guard !readOnly else { throw DatabaseError.readOnlyViolation }
        guard !updates.isEmpty, updates.count <= 500 else {
            throw DatabaseError.executionFailed("Submit between 1 and 500 changed documents.")
        }
        struct Prepared { let filter: BSONDocument; let set: BSONDocument }
        var prepared: [Prepared] = []
        for (index, update) in updates.enumerated() {
            try Task.checkCancellation()
            guard !update.changes.isEmpty, update.changes.allSatisfy({ $0.field != "_id" && !$0.field.contains("$") }),
                  Set(update.changes.map(\.field)).count == update.changes.count else {
                throw DatabaseError.executionFailed("A document needs distinct, editable fields.")
            }
            let request = MongoFindRequest(database: database, collection: collection,
                                           filter: BSONDocument(["_id": try Self.idValue(update.id)]), limit: 2)
            let documents = try await console.findDocuments(request, limit: 2)
            guard documents.count == 1, let document = documents.first, let exactID = document["_id"] else {
                throw SQLiteOptimisticConflict(updateIndex: index, current: nil)
            }
            var filter = BSONDocument(["_id": exactID])
            var set = BSONDocument()
            var currentCells: [DatabaseValue] = []
            var changed = false
            for change in update.changes {
                let current = document[change.field]
                let cell = current.map { MongoTable.typedCell($0) } ?? .missing
                currentCells.append(cell)
                if cell != change.original { changed = true }
                filter[change.field] = current ?? .document(BSONDocument(["$exists": .bool(false)]))
                set[change.field] = try Self.bsonValue(change.replacement, replacing: current)
            }
            guard !changed else { throw SQLiteOptimisticConflict(updateIndex: index, current: currentCells) }
            prepared.append(Prepared(filter: filter, set: set))
        }
        var result = SQLMutationResult(rowsAffected: 0, leftTransactionOpen: false, insertedRowIDs: [:])
        for (index, item) in prepared.enumerated() {
            try Task.checkCancellation()
            do {
                let written = try await console.updateOne(database: database, collection: collection, filter: item.filter,
                                                          update: BSONDocument(["$set": .document(item.set)]))
                guard written.matched == 1 else { throw SQLiteOptimisticConflict(updateIndex: index, current: nil) }
            } catch let conflict as SQLiteOptimisticConflict {
                throw conflict
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let note = index == 0 ? "Nothing was written." : "\(index) earlier document\(index == 1 ? " was" : "s were") already written."
                throw SQLiteMutationFailure(index: index, message: "\(error.localizedDescription) \(note)", code: nil)
            }
            result.rowsAffected += 1
        }
        return result
    }
}
