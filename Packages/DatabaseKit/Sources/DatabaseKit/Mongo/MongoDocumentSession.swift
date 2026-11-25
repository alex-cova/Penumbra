import BSON
import DatabaseCore
import Foundation
import Logging
@preconcurrency import MongoClient
@preconcurrency import MongoCore
@preconcurrency import MongoKitten
import NIOCore

public struct MongoFindRequest: Sendable, Equatable {
    public var database: String
    public var collection: String
    public var filter: BSONDocument
    public var projection: BSONDocument?
    public var sort: BSONDocument?
    public var skip: Int
    /// 0 means no limit.
    public var limit: Int
    public var hint: BSONValue?
    public var maxTimeMS: Int?
    public var batchSize: Int

    public init(
        database: String, collection: String, filter: BSONDocument = BSONDocument(),
        projection: BSONDocument? = nil, sort: BSONDocument? = nil, skip: Int = 0, limit: Int = 0,
        hint: BSONValue? = nil, maxTimeMS: Int? = nil, batchSize: Int = 1000
    ) {
        self.database = database
        self.collection = collection
        self.filter = filter
        self.projection = projection
        self.sort = sort
        self.skip = skip
        self.limit = limit
        self.hint = hint
        self.maxTimeMS = maxTimeMS
        self.batchSize = batchSize
    }
}

public struct MongoDatabaseInfo: Sendable, Equatable {
    public var name: String
    public var sizeOnDisk: Int64?
    public var isEmpty: Bool
}

public struct MongoCollectionInfo: Sendable, Equatable {
    public var name: String
    /// `collection`, `view` or `timeseries`.
    public var type: String
    public var options: BSONDocument
    /// The `$jsonSchema` or query validator, if the collection has one.
    public var validator: BSONDocument? { options["validator"].flatMap { if case .document(let d) = $0 { d } else { nil } } }
    public var isCapped: Bool { options["capped"] == .bool(true) }
}

public struct MongoWriteResult: Sendable, Equatable {
    /// Documents matched (update/delete) or inserted.
    public var matched: Int
    public var modified: Int
    public var upsertedID: BSONValue?
}

/// One MongoDB deployment, reached through one pinned connection and owned by one actor.
///
/// - Values stay BSON (`BSONValue`): nothing goes through `Document`, `Double` or a string, so
///   Decimal128, Int64, Timestamp, and "field absent" versus `null` are exact.
/// - Reads stream: a `find` or `aggregate` cursor is read batch by batch into a `ResultStore`, the
///   server cursor is killed when the store has enough, on error and on cancel, and a cursor is
///   never left open after the call returns.
/// - Cancelling runs `killOp` on a second connection, matching the operation by a unique
///   `comment` this session put on it. That needs the privilege to see and kill your own
///   operations; the probe at connect decides whether `.cancellation` is offered.
/// - Read-only is enforced by construction: this type has no way to send an arbitrary command, its
///   write methods refuse on a read-only session, and `aggregate` refuses `$out` and `$merge`.
///   That is **not** server-enforced (MongoDB has no read-only transaction mode); for a hard
///   guarantee use a user that has only the `read` role. `.serverEnforcedReadOnly` is therefore
///   never claimed for MongoDB.
public actor MongoDocumentSession {
    public nonisolated let readOnly: Bool
    public private(set) var serverInfo: ServerInfo
    public private(set) var capabilities: DatabaseCapabilities
    public let defaultDatabase: String

    private let database: MongoDatabase
    private var connection: MongoConnection
    private let settings: ConnectionSettings
    private var cancelDatabase: MongoDatabase?
    private var isRunning = false
    private var cancelRequested = false
    private var operationTag = ""
    private var isClosed = false

    private init(
        database: MongoDatabase, connection: MongoConnection, settings: ConnectionSettings,
        readOnly: Bool, serverInfo: ServerInfo, capabilities: DatabaseCapabilities, defaultDatabase: String
    ) {
        self.database = database
        self.connection = connection
        self.settings = settings
        self.readOnly = readOnly
        self.serverInfo = serverInfo
        self.capabilities = capabilities
        self.defaultDatabase = defaultDatabase
    }

    // MARK: - Connecting

    public static let defaultConnectTimeout: TimeInterval = 10
    /// How long a single command may wait for the server before the driver gives up. Long
    /// aggregations are legitimate, so this is minutes, not the connect timeout.
    public static let defaultSocketTimeout: TimeInterval = 600

    public static func connect(
        login: MongoLogin, readOnly: Bool, timeout: TimeInterval = defaultConnectTimeout
    ) async throws -> MongoDocumentSession {
        let uri = MongoURLs.connectionURI(from: login)
        var settings: ConnectionSettings
        do {
            settings = try ConnectionSettings(uri)
        } catch {
            throw DatabaseError.invalidURL(MongoURLs.redactedURI(from: login))
        }
        settings.connectTimeout = timeout
        settings.socketTimeout = defaultSocketTimeout
        let database = try await openDatabase(settings: settings, timeout: timeout)
        do {
            let connection = try await database.pool.next(for: .writable)
            let hello = try await runCommand(
                BSONDocument(["hello": .int32(1)]), database: "admin", on: connection
            )
            let build = try await runCommand(
                BSONDocument(["buildInfo": .int32(1)]), database: "admin", on: connection
            )
            let version: String
            if case .string(let text)? = build["version"] { version = text } else { version = "" }
            let major = Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 0
            var features: Set<String> = []
            let isReplicaSet = hello["setName"] != nil
            let isSharded: Bool
            if case .string("isdbgrid")? = hello["msg"] { isSharded = true } else { isSharded = false }
            if isReplicaSet { features.insert("replicaSet") }
            if isSharded { features.insert("sharded") }
            if !isReplicaSet, !isSharded { features.insert("standalone") }
            var capabilities: DatabaseCapabilities = [
                .explainText, .explainStructured, .explainAnalyze, .streamingCursor, .multipleDatabases,
                .spatial,
            ]
            // Multi-document transactions exist only on replica sets and sharded clusters.
            if isReplicaSet || isSharded, major >= 4 { capabilities.insert(.transactions) }
            // Cancelling needs to see and kill our own operations: probe, do not assume.
            if await canListOwnOperations(on: connection) { capabilities.insert(.cancellation) }
            let session = MongoDocumentSession(
                database: database, connection: connection, settings: settings, readOnly: readOnly,
                serverInfo: ServerInfo(engine: .mongo, version: version, majorVersion: major, features: features),
                capabilities: capabilities, defaultDatabase: login.defaultDatabase
            )
            return session
        } catch {
            await (database.pool as? MongoCluster)?.disconnect()
            throw Self.map(error)
        }
    }

    public static func test(login: MongoLogin) async throws {
        let session = try await connect(login: login, readOnly: true, timeout: 5)
        _ = try await session.listDatabases()
        await session.close()
    }

    private static func openDatabase(settings: ConnectionSettings, timeout: TimeInterval) async throws -> MongoDatabase {
        // The driver's own connect timeout is several minutes, so connecting races a short one.
        try await withThrowingTaskGroup(of: DatabaseBox.self) { group in
            group.addTask { DatabaseBox(try await MongoDatabase.connect(to: settings)) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw DatabaseError.connectionTimedOut(timeout)
            }
            defer { group.cancelAll() }
            guard let box = try await group.next() else { throw DatabaseError.connectionTimedOut(timeout) }
            return box.database
        }
    }

    private static func canListOwnOperations(on connection: MongoConnection) async -> Bool {
        let command = BSONDocument([
            "aggregate": .int32(1),
            "pipeline": .array([.document(BSONDocument(["$currentOp": .document(BSONDocument(["allUsers": .bool(false)]))])), .document(BSONDocument(["$limit": .int32(1)]))]),
            "cursor": .document(BSONDocument()),
        ])
        return (try? await runCommand(command, database: "admin", on: connection)) != nil
    }

    // MARK: - Raw commands (internal: nothing outside this type can send one)

    private static func runCommand(
        _ command: BSONDocument, database: String, on connection: MongoConnection
    ) async throws -> BSONDocument {
        let document = Document(bytes: try BSONCodec.encode(command))
        let reply = try await connection.execute(
            document, namespace: MongoNamespace(to: "$cmd", inDatabase: database), sessionId: nil
        )
        let replyDocument = try reply.getDocument()
        let decoded = try BSONCodec.decode(Array(replyDocument.makeByteBuffer().readableBytesView))
        let ok: Bool
        switch decoded["ok"] {
        case .double(let value)?: ok = value == 1
        case .int32(let value)?: ok = value == 1
        case .int64(let value)?: ok = value == 1
        default: ok = false
        }
        guard ok else {
            var message = "The server reported an error."
            if case .string(let text)? = decoded["errmsg"] { message = text }
            var code: String?
            if case .string(let name)? = decoded["codeName"] { code = name }
            else if case .int32(let number)? = decoded["code"] { code = String(number) }
            throw DatabaseServerError(message: message, code: code)
        }
        return decoded
    }

    private func run(_ command: BSONDocument, database: String? = nil) async throws -> BSONDocument {
        guard !isClosed else { throw DatabaseError.notConnected }
        do {
            return try await Self.runCommand(command, database: database ?? defaultDatabase, on: connection)
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: - Catalog

    public func listDatabases() async throws -> [MongoDatabaseInfo] {
        let reply = try await run(BSONDocument(["listDatabases": .int32(1), "nameOnly": .bool(false)]), database: "admin")
        guard case .array(let items)? = reply["databases"] else { return [] }
        return items.compactMap { item in
            guard case .document(let entry) = item, case .string(let name)? = entry["name"] else { return nil }
            var size: Int64?
            switch entry["sizeOnDisk"] {
            case .int64(let value)?: size = value
            case .int32(let value)?: size = Int64(value)
            case .double(let value)?: size = Int64(value)
            default: break
            }
            return MongoDatabaseInfo(name: name, sizeOnDisk: size, isEmpty: entry["empty"] == .bool(true))
        }
        .sorted { $0.name < $1.name }
    }

    public func listCollections(database: String) async throws -> [MongoCollectionInfo] {
        var result: [MongoCollectionInfo] = []
        try await forEachBatch(
            first: BSONDocument(["listCollections": .int32(1)]), database: database, collection: "$cmd.listCollections"
        ) { batch in
            for item in batch {
                guard case .string(let name)? = item["name"] else { continue }
                var type = "collection"
                if case .string(let text)? = item["type"] { type = text }
                var options = BSONDocument()
                if case .document(let value)? = item["options"] { options = value }
                result.append(MongoCollectionInfo(name: name, type: type, options: options))
            }
            return true
        }
        return result.sorted { $0.name < $1.name }
    }

    public func listIndexes(database: String, collection: String) async throws -> [BSONDocument] {
        var result: [BSONDocument] = []
        try await forEachBatch(
            first: BSONDocument(["listIndexes": .string(collection)]), database: database, collection: collection
        ) { batch in
            result.append(contentsOf: batch)
            return true
        }
        return result
    }

    public func collectionStats(database: String, collection: String) async throws -> BSONDocument {
        try await run(BSONDocument(["collStats": .string(collection)]), database: database)
    }

    public func estimatedCount(database: String, collection: String) async throws -> Int {
        let reply = try await run(BSONDocument(["count": .string(collection)]), database: database)
        return Self.integer(reply["n"]) ?? 0
    }

    public func count(database: String, collection: String, filter: BSONDocument) async throws -> Int {
        let reply = try await run(
            BSONDocument(["count": .string(collection), "query": .document(filter)]), database: database
        )
        return Self.integer(reply["n"]) ?? 0
    }

    // MARK: - Reading

    /// Runs a `find` and delivers each document, as canonical Extended JSON, into `store` (one
    /// `document` column), reading batches only as fast as the store takes them.
    public func find(_ request: MongoFindRequest, into store: ResultStore) async throws -> ExecutionSummary {
        try await stream(
            first: Self.findCommand(request), database: request.database, collection: request.collection,
            batchSize: request.batchSize, into: store
        )
    }

    func findTable(_ request: MongoFindRequest, into store: ResultStore) async throws -> ExecutionSummary {
        try await stream(first: Self.findCommand(request), database: request.database, collection: request.collection,
                         batchSize: request.batchSize, into: store, table: true)
    }

    /// The same read, returned as documents, for callers that need the fields (the table view,
    /// editing). Bounded by `limit`; never unbounded.
    public func findDocuments(_ request: MongoFindRequest, limit: Int) async throws -> [BSONDocument] {
        var request = request
        request.limit = request.limit == 0 ? limit : min(request.limit, limit)
        var result: [BSONDocument] = []
        try await guarded { tag in
            var command = Self.findCommand(request)
            command["comment"] = .string(tag)
            try await self.forEachBatch(
                first: command, database: request.database, collection: request.collection, batchSize: request.batchSize
            ) { batch in
                result.append(contentsOf: batch)
                return result.count < limit
            }
        }
        return result
    }

    public func aggregate(
        database: String, collection: String, pipeline: [BSONDocument], maxTimeMS: Int? = nil,
        into store: ResultStore
    ) async throws -> ExecutionSummary {
        try ensurePipelineIsReadOnly(pipeline)
        var command = BSONDocument([
            "aggregate": .string(collection),
            "pipeline": .array(pipeline.map { .document($0) }),
            "cursor": .document(BSONDocument(["batchSize": .int32(1000)])),
        ])
        if let maxTimeMS { command["maxTimeMS"] = .int64(Int64(maxTimeMS)) }
        return try await stream(first: command, database: database, collection: collection, batchSize: 1000, into: store)
    }

    /// `executionStats` or `queryPlanner` for a find. Runs the query when asked for statistics.
    public func explain(_ request: MongoFindRequest, verbosity: String = "queryPlanner") async throws -> BSONDocument {
        try await run(
            BSONDocument(["explain": .document(Self.findCommand(request)), "verbosity": .string(verbosity)]),
            database: request.database
        )
    }

    static func findCommand(_ request: MongoFindRequest) -> BSONDocument {
        var command = BSONDocument(["find": .string(request.collection), "filter": .document(request.filter)])
        if let projection = request.projection, !projection.isEmpty { command["projection"] = .document(projection) }
        if let sort = request.sort, !sort.isEmpty { command["sort"] = .document(sort) }
        if request.skip > 0 { command["skip"] = .int64(Int64(request.skip)) }
        if request.limit > 0 { command["limit"] = .int64(Int64(request.limit)) }
        if let hint = request.hint { command["hint"] = hint }
        if let maxTimeMS = request.maxTimeMS { command["maxTimeMS"] = .int64(Int64(maxTimeMS)) }
        command["batchSize"] = .int32(Int32(max(1, min(request.batchSize, 100_000))))
        return command
    }

    private func ensurePipelineIsReadOnly(_ pipeline: [BSONDocument]) throws {
        guard readOnly else { return }
        for stage in pipeline where stage["$out"] != nil || stage["$merge"] != nil {
            throw DatabaseError.readOnlyViolation
        }
    }

    // MARK: - Streaming

    private func stream(
        first: BSONDocument, database: String, collection: String, batchSize: Int, into store: ResultStore,
        table: Bool = false
    ) async throws -> ExecutionSummary {
        let start = ContinuousClock.now
        var summary = ExecutionSummary(
            columns: table ? [ResultColumn(name: "_id")] : [ResultColumn(name: "document", typeName: "object")]
        )
        var fields: Set<String> = ["_id"]
        await store.setColumns(summary.columns)
        do {
            try await guarded { tag in
                var command = first
                command["comment"] = .string(tag)
                try await self.forEachBatch(first: command, database: database, collection: collection, batchSize: batchSize) { batch in
                    if table, fields.count < MongoTable.columnLimit {
                        let previousCount = fields.count
                        outer: for document in batch {
                            for field in document.fields where fields.insert(field.key).inserted {
                                summary.columns.append(ResultColumn(name: field.key))
                                if fields.count == MongoTable.columnLimit { break outer }
                            }
                        }
                        if fields.count != previousCount { await store.setColumns(summary.columns) }
                    }
                    let rows = table ? batch.map { document in
                        summary.columns.map { document[$0.name].map { MongoTable.typedCell($0) } ?? .missing }
                    } : batch.map { [Self.cell($0)] }
                    let accepted = try await store.append(rows)
                    if !accepted { summary.limitReached = true }
                    return accepted
                }
            }
        } catch {
            if !cancelRequested, !(error is CancellationError) { throw error }
        }
        summary.rowCount = await store.rowCount
        summary.wasCancelled = cancelRequested
        summary.commandTag = "FIND \(summary.rowCount)"
        summary.duration = ContinuousClock.now - start
        await store.finish()
        return summary
    }

    /// A document as one cell: canonical Extended JSON, bounded like any large value.
    static func cell(_ document: BSONDocument, limits: ValueLimits = .standard) -> DatabaseValue {
        let text = ExtendedJSON.string(document, mode: .canonical)
        guard text.utf8.count > limits.maxTextBytes else {
            return .bson(typeName: "object", extendedJSON: text)
        }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: limits.maxTextBytes)
        while end > text.utf8.startIndex, text.utf8[end] & 0xC0 == 0x80 { end = text.utf8.index(before: end) }
        return .truncated(preview: String(text[..<end]), fullCount: text.utf8.count)
    }

    /// Reads a cursor to its end or until `body` returns false, then kills the server cursor if it
    /// is still open, however the loop ended.
    private func forEachBatch(
        first: BSONDocument, database: String, collection: String, batchSize: Int = 1000,
        _ body: ([BSONDocument]) async throws -> Bool
    ) async throws {
        var cursorID: Int64 = 0
        var cursorCollection = collection
        do {
            let reply = try await run(first, database: database)
            guard case .document(let cursor)? = reply["cursor"] else { return }
            if case .string(let namespace)? = cursor["ns"], let dot = namespace.firstIndex(of: ".") {
                cursorCollection = String(namespace[namespace.index(after: dot)...])
            }
            cursorID = Self.int64(cursor["id"]) ?? 0
            var batch = Self.documents(cursor["firstBatch"])
            var keepGoing = try await body(batch)
            while keepGoing, cursorID != 0 {
                if cancelRequested { break }
                try Task.checkCancellation()
                let next = try await run(
                    BSONDocument([
                        "getMore": .int64(cursorID), "collection": .string(cursorCollection),
                        "batchSize": .int32(Int32(max(1, min(batchSize, 100_000)))),
                    ]),
                    database: database
                )
                guard case .document(let nextCursor)? = next["cursor"] else { break }
                cursorID = Self.int64(nextCursor["id"]) ?? 0
                batch = Self.documents(nextCursor["nextBatch"])
                keepGoing = try await body(batch)
            }
        } catch {
            await killCursor(cursorID, database: database, collection: cursorCollection)
            throw error
        }
        await killCursor(cursorID, database: database, collection: cursorCollection)
    }

    private func killCursor(_ id: Int64, database: String, collection: String) async {
        guard id != 0, !isClosed else { return }
        let command = BSONDocument(["killCursors": .string(collection), "cursors": .array([.int64(id)])])
        let connection = connection
        // Unstructured: a cancelled caller must still release the server's cursor.
        await Task { _ = try? await Self.runCommand(command, database: database, on: connection) }.value
    }

    private static func documents(_ value: BSONValue?) -> [BSONDocument] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { if case .document(let document) = $0 { document } else { nil } }
    }

    // MARK: - Writing

    public func insertOne(database: String, collection: String, document: BSONDocument) async throws -> MongoWriteResult {
        try ensureWritable()
        let reply = try await run(
            BSONDocument(["insert": .string(collection), "documents": .array([.document(document)])]), database: database
        )
        try Self.throwWriteErrors(reply)
        return MongoWriteResult(matched: Self.integer(reply["n"]) ?? 0, modified: 0)
    }

    public func insertMany(database: String, collection: String, documents: [BSONDocument]) async throws -> MongoWriteResult {
        try ensureWritable()
        var inserted = 0
        // The server accepts up to 100,000 documents or 48 MB per command; stay well inside both.
        for start in stride(from: 0, to: documents.count, by: 1000) {
            let chunk = documents[start..<min(start + 1000, documents.count)]
            let reply = try await run(
                BSONDocument(["insert": .string(collection), "documents": .array(chunk.map { .document($0) })]),
                database: database
            )
            try Self.throwWriteErrors(reply)
            inserted += Self.integer(reply["n"]) ?? 0
        }
        return MongoWriteResult(matched: inserted, modified: 0)
    }

    public func dropCollection(database: String, collection: String) async throws {
        try ensureWritable()
        do {
            _ = try await run(BSONDocument(["drop": .string(collection)]), database: database)
        } catch let error as DatabaseServerError where error.code == "NamespaceNotFound" {
            return  // already gone
        }
    }

    /// `update` is an update document (`{"$set": {...}}`) or a replacement. The caller builds the
    /// filter, which is what makes an edit safe: `_id` plus the original values of the fields
    /// being changed means a concurrent change makes it match nothing instead of overwriting.
    public func updateOne(
        database: String, collection: String, filter: BSONDocument, update: BSONDocument, upsert: Bool = false
    ) async throws -> MongoWriteResult {
        try ensureWritable()
        let entry = BSONDocument([
            "q": .document(filter), "u": .document(update), "multi": .bool(false), "upsert": .bool(upsert),
        ])
        let reply = try await run(
            BSONDocument(["update": .string(collection), "updates": .array([.document(entry)])]), database: database
        )
        try Self.throwWriteErrors(reply)
        var upserted: BSONValue?
        if case .array(let items)? = reply["upserted"], case .document(let first)? = items.first { upserted = first["_id"] }
        return MongoWriteResult(
            matched: Self.integer(reply["n"]) ?? 0, modified: Self.integer(reply["nModified"]) ?? 0, upsertedID: upserted
        )
    }

    public func deleteOne(database: String, collection: String, filter: BSONDocument) async throws -> MongoWriteResult {
        try ensureWritable()
        let entry = BSONDocument(["q": .document(filter), "limit": .int32(1)])
        let reply = try await run(
            BSONDocument(["delete": .string(collection), "deletes": .array([.document(entry)])]), database: database
        )
        try Self.throwWriteErrors(reply)
        return MongoWriteResult(matched: Self.integer(reply["n"]) ?? 0, modified: 0)
    }

    public func createIndex(
        database: String, collection: String, keys: BSONDocument, name: String? = nil, unique: Bool = false
    ) async throws {
        try ensureWritable()
        var index = BSONDocument(["key": .document(keys)])
        index["name"] = .string(name ?? keys.fields.map { "\($0.key)_\(ExtendedJSON.string($0.value))" }.joined(separator: "_"))
        if unique { index["unique"] = .bool(true) }
        _ = try await run(
            BSONDocument(["createIndexes": .string(collection), "indexes": .array([.document(index)])]), database: database
        )
    }

    public func dropIndex(database: String, collection: String, name: String) async throws {
        try ensureWritable()
        _ = try await run(BSONDocument(["dropIndexes": .string(collection), "index": .string(name)]), database: database)
    }

    private func ensureWritable() throws {
        guard !readOnly else { throw DatabaseError.readOnlyViolation }
    }

    private static func throwWriteErrors(_ reply: BSONDocument) throws {
        if case .array(let errors)? = reply["writeErrors"], case .document(let first)? = errors.first {
            var message = "The write failed."
            if case .string(let text)? = first["errmsg"] { message = text }
            var code: String?
            if let number = integer(first["code"]) { code = String(number) }
            throw DatabaseServerError(message: message, code: code)
        }
    }

    /// Server cursors currently open on the deployment (`serverStatus`). A diagnostic: after any
    /// call here returns, this session must not have left one open.
    func openCursorCount() async throws -> Int {
        let reply = try await run(BSONDocument(["serverStatus": .int32(1)]), database: "admin")
        guard case .document(let metrics)? = reply["metrics"], case .document(let cursor)? = metrics["cursor"],
              case .document(let open)? = cursor["open"]
        else { return 0 }
        return Self.integer(open["total"]) ?? 0
    }

    // MARK: - Cancelling and closing

    /// Stops the operation this session is running. The server operation is found by the
    /// `comment` this session attached and killed from a second connection.
    public func cancelRunning() async {
        guard isRunning else { return }
        cancelRequested = true
        let tag = operationTag
        do {
            let helper = try await cancelHelper()
            let find = BSONDocument([
                "aggregate": .int32(1),
                "pipeline": .array([
                    .document(BSONDocument(["$currentOp": .document(BSONDocument(["allUsers": .bool(false)]))])),
                    .document(BSONDocument(["$match": .document(BSONDocument([
                        "$or": .array([
                            .document(BSONDocument(["command.comment": .string(tag)])),
                            .document(BSONDocument(["cursor.originatingCommand.comment": .string(tag)])),
                            .document(BSONDocument(["originatingCommand.comment": .string(tag)])),
                        ]),
                    ]))])),
                ]),
                "cursor": .document(BSONDocument()),
            ])
            let reply = try await Self.runCommand(find, database: "admin", on: helper)
            guard case .document(let cursor)? = reply["cursor"] else { return }
            for operation in Self.documents(cursor["firstBatch"]) {
                if let opid = operation["opid"] {
                    _ = try? await Self.runCommand(BSONDocument(["killOp": .int32(1), "op": opid]), database: "admin", on: helper)
                }
            }
        } catch {
            // No privilege to see operations: the client-side flag still ends batch loops.
        }
    }

    private func cancelHelper() async throws -> MongoConnection {
        if cancelDatabase == nil { cancelDatabase = try await MongoDatabase.connect(to: settings) }
        return try await cancelDatabase!.pool.next(for: .writable)
    }

    /// Runs `body` as the session's one running operation, with a tag cancel can find it by.
    private func guarded(_ body: (String) async throws -> Void) async throws {
        guard !isClosed else { throw DatabaseError.notConnected }
        guard !isRunning else {
            throw DatabaseError.executionFailed("An operation is already running on this connection.")
        }
        isRunning = true
        cancelRequested = false
        operationTag = "umbra:" + UUID().uuidString
        defer { isRunning = false }
        do {
            try await withTaskCancellationHandler {
                try await body(operationTag)
            } onCancel: {
                Task { await self.cancelRunning() }
            }
        } catch {
            // `killOp` ends the operation with an "interrupted" server error; that is the outcome
            // the user asked for, not a failure to report.
            if cancelRequested { throw CancellationError() }
            throw error
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        await (cancelDatabase?.pool as? MongoCluster)?.disconnect()
        await (database.pool as? MongoCluster)?.disconnect()
    }

    // MARK: - Helpers

    private static func integer(_ value: BSONValue?) -> Int? {
        switch value {
        case .int32(let number)?: Int(number)
        case .int64(let number)?: Int(number)
        case .double(let number)?: number.isFinite ? Int(number) : nil
        default: nil
        }
    }

    private static func int64(_ value: BSONValue?) -> Int64? {
        switch value {
        case .int64(let number)?: number
        case .int32(let number)?: Int64(number)
        default: nil
        }
    }

    static func map(_ error: any Error) -> any Error {
        if let error = error as? MongoServerError {
            let reply = (try? BSONCodec.decode(Array(error.document.makeByteBuffer().readableBytesView))) ?? BSONDocument()
            var message = "The server reported an error."
            if case .string(let text)? = reply["errmsg"] { message = text }
            return DatabaseServerError(message: message)
        }
        return error
    }
}

private final class DatabaseBox: @unchecked Sendable {
    // MongoDatabase is a reference type that the driver documents as thread-safe; the box only
    // carries it across the task group boundary, once, from the task that created it.
    let database: MongoDatabase
    init(_ database: MongoDatabase) { self.database = database }
}
