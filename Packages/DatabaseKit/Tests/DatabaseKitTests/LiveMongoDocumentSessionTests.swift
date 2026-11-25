import Foundation
import Testing

@testable import DatabaseKit

private let liveEnabled = ProcessInfo.processInfo.environment["UMBRA_DB_INTEGRATION"] == "1"

@Suite(.enabled(if: liveEnabled, "needs UMBRA_DB_INTEGRATION=1 and Scripts/db-test-env.sh up"), .serialized)
struct LiveMongoDocumentSessionTests {
    private let db = "umbra_test"

    private func login() throws -> MongoLogin {
        guard let url = ProcessInfo.processInfo.environment["UMBRA_TEST_MONGO_URL"] else {
            throw DatabaseError.executionFailed("UMBRA_TEST_MONGO_URL is not set; run Scripts/db-test-env.sh env")
        }
        return try MongoURLs.parse(url)
    }

    private func connect(readOnly: Bool = false) async throws -> MongoDocumentSession {
        try await MongoDocumentSession.connect(login: login(), readOnly: readOnly)
    }

    private func documents(
        _ session: MongoDocumentSession, _ collection: String, filter: BSONDocument = BSONDocument(), limit: Int = 1000
    ) async throws -> [BSONDocument] {
        try await session.findDocuments(MongoFindRequest(database: db, collection: collection, filter: filter), limit: limit)
    }

    private func fresh(_ session: MongoDocumentSession, _ collection: String) async throws {
        try await session.dropCollection(database: db, collection: collection)
    }

    @Test func serverFactsAndCapabilitiesAreDetected() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        let info = await session.serverInfo
        #expect(info.engine == .mongo)
        #expect(info.majorVersion == 7)
        #expect(info.features.contains("replicaSet"), "the test deployment is a one-node replica set")
        let capabilities = await session.capabilities
        #expect(capabilities.contains(.transactions), "transactions are offered because the topology supports them")
        #expect(capabilities.contains(.cancellation))
        #expect(!capabilities.contains(.serverEnforcedReadOnly), "MongoDB has no server-side read-only mode; never claim it")
    }

    @Test func everyBSONTypeSurvivesTheServerExactly() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await fresh(session, "fidelity")
        defer { Task { try? await self.fresh(session, "fidelity") } }
        let original = try ExtendedJSON.parseDocument("""
        {"_id": {"$oid": "507f1f77bcf86cd799439011"},
         "i32": {"$numberInt": "-5"}, "i64": {"$numberLong": "9007199254740993"}, "dbl": {"$numberDouble": "1.5"},
         "dec": {"$numberDecimal": "1.50"}, "str": "héllo", "date": {"$date": {"$numberLong": "-62135596800000"}},
         "bin": {"$binary": {"base64": "AQID", "subType": "00"}}, "uuid": {"$binary": {"base64": "oO68mZwLTvi7bWu5vTgKEQ==", "subType": "04"}},
         "re": {"$regularExpression": {"pattern": "^a", "options": "i"}}, "ts": {"$timestamp": {"t": 1700000000, "i": 7}},
         "nested": {"a": [1, {"b": null}]}, "yes": true, "nothing": null,
         "min": {"$minKey": 1}, "max": {"$maxKey": 1}}
        """)
        _ = try await session.insertOne(database: db, collection: "fidelity", document: original)
        let back = try #require(try await documents(session, "fidelity").first)
        #expect(back == original, "the document came back different")

        // The server's own opinion of the stored types (not just our decoder agreeing with our encoder).
        let store = ResultStore(columns: [])
        _ = try await session.aggregate(
            database: db, collection: "fidelity",
            pipeline: [try ExtendedJSON.parseDocument("""
            {"$project": {"_id": 0, "i32": {"$type": "$i32"}, "i64": {"$type": "$i64"}, "dbl": {"$type": "$dbl"},
              "dec": {"$type": "$dec"}, "decText": {"$toString": "$dec"}, "date": {"$type": "$date"}, "ts": {"$type": "$ts"},
              "bin": {"$type": "$bin"}, "re": {"$type": "$re"}, "oid": {"$type": "$_id"}}}
            """)],
            into: store
        )
        let row = try #require(try await store.rows(in: 0..<1).first)
        await store.close()
        guard case .bson(_, let json) = row[0], case .document(let types) = try ExtendedJSON.parse(json) else {
            Issue.record("unexpected aggregate row \(row)")
            return
        }
        #expect(types["i32"] == .string("int"))
        #expect(types["i64"] == .string("long"))
        #expect(types["dbl"] == .string("double"))
        #expect(types["dec"] == .string("decimal"))
        #expect(types["decText"] == .string("1.50"), "the trailing zero of a Decimal128 must survive")
        #expect(types["date"] == .string("date"))
        #expect(types["ts"] == .string("timestamp"))
        #expect(types["bin"] == .string("binData"))
        #expect(types["re"] == .string("regex"))
        #expect(types["oid"] == .string("objectId"))
    }

    @Test func missingFieldsAndNullAreDifferent() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await fresh(session, "nulls")
        defer { Task { try? await self.fresh(session, "nulls") } }
        _ = try await session.insertMany(database: db, collection: "nulls", documents: [
            BSONDocument(["_id": .int32(1), "a": .null]), BSONDocument(["_id": .int32(2)]), BSONDocument(["_id": .int32(3), "a": .int32(0)]),
        ])
        let all = try await documents(session, "nulls")
        #expect(all[0]["a"] == .null)
        #expect(all[1]["a"] == nil, "a missing field is absent, not null")
        #expect(all[2]["a"] == .int32(0))
        let exists = try await documents(session, "nulls", filter: try ExtendedJSON.parseDocument("{\"a\": {\"$exists\": true}}"))
        #expect(exists.map { $0["_id"] } == [.int32(1), .int32(3)])
    }

    @Test func consoleGridStreamsTypedCellsAcrossMultipleBatches() async throws {
        let facade = try await MongoSession.connect(login: login(), readOnly: false)
        let session = await facade.console
        let collection = "grid_\(UUID().uuidString)"
        defer { Task { try? await self.fresh(session, collection); await facade.disconnect() } }
        var documents = (0..<300).map { BSONDocument(["_id": .int32(Int32($0))]) }
        documents[0]["value"] = .null
        documents[299]["later"] = .int64(9_007_199_254_740_993)
        _ = try await session.insertMany(database: db, collection: collection, documents: documents)
        let store = ResultStore(columns: [])
        let summary = try await facade.find(database: db, collection: collection, filterJSON: "{}",
                                            sortKey: "_id", into: store)
        #expect(summary.rowCount == 300)
        #expect(summary.columns.map(\.name) == ["_id", "value", "later"])
        #expect(try await store.row(at: 0) == [.int(0), .null])
        #expect(try await store.row(at: 1) == [.int(1), .missing])
        #expect(try await store.row(at: 299) == [.int(299), .missing, .int(9_007_199_254_740_993)])
        await store.close()
    }

    @Test func aCursorIsReadInBatchesStoppedEarlyAndNeverLeftOpen() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await fresh(session, "many")
        defer { Task { try? await self.fresh(session, "many") } }
        _ = try await session.insertMany(
            database: db, collection: "many",
            documents: (0..<5_000).map { BSONDocument(["_id": .int32(Int32($0)), "n": .int32(Int32($0)), "pad": .string(String(repeating: "x", count: 200))]) }
        )
        let before = try await session.openCursorCount()

        // Stopped by the store's row limit while the server cursor still has 3,500 documents.
        let limited = ResultStore(columns: [], rowLimit: 1_500)
        let summary = try await session.find(
            MongoFindRequest(database: db, collection: "many", sort: BSONDocument(["n": .int32(1)]), batchSize: 100), into: limited
        )
        #expect(summary.limitReached)
        #expect(await limited.rowCount == 1_500)
        #expect(try await session.openCursorCount() == before, "the server cursor must be killed when we stop early")
        let last = try await limited.row(at: 1_499)
        if case .bson(_, let json) = last[0] { #expect(json.contains("\"1499\"")) } else { Issue.record("not a document cell") }
        await limited.close()

        // Read to the end.
        let all = ResultStore(columns: [])
        let full = try await session.find(MongoFindRequest(database: db, collection: "many", batchSize: 500), into: all)
        #expect(full.rowCount == 5_000)
        #expect(!full.limitReached)
        #expect(try await session.openCursorCount() == before)
        await all.close()

        // An aggregation pipeline streams the same way.
        let aggregated = ResultStore(columns: [])
        let aggSummary = try await session.aggregate(
            database: db, collection: "many",
            pipeline: [try ExtendedJSON.parseDocument("{\"$match\": {\"n\": {\"$lt\": 10}}}")], into: aggregated
        )
        #expect(aggSummary.rowCount == 10)
        await aggregated.close()
    }

    @Test func cancellingARunningOperationStopsItOnTheServer() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await fresh(session, "slow")
        defer { Task { try? await self.fresh(session, "slow") } }
        _ = try await session.insertOne(database: db, collection: "slow", document: BSONDocument(["_id": .int32(1)]))
        let task = Task {
            let store = ResultStore(columns: [])
            defer { Task { await store.close() } }
            // `$where` runs JavaScript on the server for each document: 30 s for the one document.
            return try await session.find(
                MongoFindRequest(
                    database: db, collection: "slow",
                    filter: try ExtendedJSON.parseDocument("{\"$where\": \"sleep(30000) || true\"}")
                ),
                into: store
            )
        }
        try await Task.sleep(for: .milliseconds(800))
        let requested = ContinuousClock.now
        await session.cancelRunning()
        let summary = try await task.value
        let elapsed = ContinuousClock.now - requested
        print("MONGOCANCEL afterCancelRequest=\(elapsed)")
        #expect(summary.wasCancelled)
        #expect(elapsed < .seconds(5), "cancel took \(elapsed)")
        #expect(try await documents(session, "slow").count == 1, "the session is usable afterwards")
    }

    @Test func readOnlySessionsRefuseWritesAndOutputStages() async throws {
        let writer = try await connect()
        let reader = try await connect(readOnly: true)
        defer { Task { await writer.close(); await reader.close() } }
        try await fresh(writer, "ro")
        defer { Task { try? await self.fresh(writer, "ro") } }
        _ = try await writer.insertOne(database: db, collection: "ro", document: BSONDocument(["_id": .int32(1)]))
        await #expect(throws: DatabaseError.readOnlyViolation) {
            _ = try await reader.insertOne(database: self.db, collection: "ro", document: BSONDocument(["_id": .int32(2)]))
        }
        await #expect(throws: DatabaseError.readOnlyViolation) {
            _ = try await reader.deleteOne(database: self.db, collection: "ro", filter: BSONDocument())
        }
        await #expect(throws: DatabaseError.readOnlyViolation) {
            _ = try await reader.updateOne(database: self.db, collection: "ro", filter: BSONDocument(), update: BSONDocument(["$set": .document(BSONDocument(["a": .int32(1)]))]))
        }
        await #expect(throws: DatabaseError.readOnlyViolation) {
            try await reader.dropCollection(database: self.db, collection: "ro")
        }
        let store = ResultStore(columns: [])
        await #expect(throws: DatabaseError.readOnlyViolation) {
            _ = try await reader.aggregate(
                database: self.db, collection: "ro",
                pipeline: [BSONDocument(["$match": .document(BSONDocument())]), BSONDocument(["$out": .string("stolen")])], into: store
            )
        }
        await #expect(throws: DatabaseError.readOnlyViolation) {
            _ = try await reader.aggregate(
                database: self.db, collection: "ro",
                pipeline: [BSONDocument(["$merge": .document(BSONDocument(["into": .string("stolen")]))])], into: store
            )
        }
        await store.close()
        #expect(try await documents(writer, "ro").count == 1)
        #expect(try await documents(reader, "ro").count == 1, "reading is fine")
        let collections = try await writer.listCollections(database: db)
        #expect(!collections.contains { $0.name == "stolen" })
    }

    @Test func fieldLevelEditsDetectConcurrentChanges() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await fresh(session, "edits")
        defer { Task { try? await self.fresh(session, "edits") } }
        _ = try await session.insertOne(database: db, collection: "edits", document: try ExtendedJSON.parseDocument(
            "{\"_id\": 1, \"name\": \"Ada\", \"score\": {\"$numberDecimal\": \"9.50\"}, \"tags\": [\"a\"]}"
        ))
        // Edit `name` with the original value in the filter: succeeds and touches nothing else.
        let first = try await session.updateOne(
            database: db, collection: "edits",
            filter: try ExtendedJSON.parseDocument("{\"_id\": 1, \"name\": \"Ada\"}"),
            update: try ExtendedJSON.parseDocument("{\"$set\": {\"name\": \"Ada L.\"}}")
        )
        #expect(first.matched == 1 && first.modified == 1)
        // Someone else changed `score` meanwhile; our edit of `name` is unaffected and keeps the Decimal128.
        let after = try #require(try await documents(session, "edits").first)
        #expect(after["name"] == .string("Ada L."))
        #expect(after["score"] == .decimal128(try Decimal128Value("9.50")))
        #expect(after["tags"] == .array([.string("a")]))
        // A stale edit (the original value is no longer there) matches nothing: no silent overwrite.
        let stale = try await session.updateOne(
            database: db, collection: "edits",
            filter: try ExtendedJSON.parseDocument("{\"_id\": 1, \"name\": \"Ada\"}"),
            update: try ExtendedJSON.parseDocument("{\"$set\": {\"name\": \"overwritten\"}}")
        )
        #expect(stale.matched == 0)
        #expect(try #require(try await documents(session, "edits").first)["name"] == .string("Ada L."))
        // Duplicate key is a structured error.
        do {
            _ = try await session.insertOne(database: db, collection: "edits", document: BSONDocument(["_id": .int32(1)]))
            Issue.record("expected a duplicate key error")
        } catch let error as DatabaseServerError {
            #expect(error.code == "11000" || error.message.contains("duplicate key"))
        }
        let deleted = try await session.deleteOne(database: db, collection: "edits", filter: BSONDocument(["_id": .int32(1)]))
        #expect(deleted.matched == 1)
        #expect(try await documents(session, "edits").isEmpty)
    }

    @Test func indexesAndExplainAndCatalog() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await fresh(session, "idx")
        defer { Task { try? await self.fresh(session, "idx") } }
        _ = try await session.insertMany(database: db, collection: "idx", documents: (0..<100).map { BSONDocument(["_id": .int32(Int32($0)), "k": .int32(Int32($0 % 10))]) })
        try await session.createIndex(database: db, collection: "idx", keys: BSONDocument(["k": .int32(1)]), name: "k_1")
        let indexes = try await session.listIndexes(database: db, collection: "idx")
        #expect(indexes.compactMap { if case .string(let name)? = $0["name"] { name } else { nil } }.sorted() == ["_id_", "k_1"])
        let plan = try await session.explain(
            MongoFindRequest(database: db, collection: "idx", filter: BSONDocument(["k": .int32(3)])), verbosity: "executionStats"
        )
        #expect(plan["executionStats"] != nil)
        #expect(ExtendedJSON.string(plan).contains("IXSCAN"), "the query should use the new index")
        try await session.dropIndex(database: db, collection: "idx", name: "k_1")
        #expect(try await session.listIndexes(database: db, collection: "idx").count == 1)
        #expect(try await session.estimatedCount(database: db, collection: "idx") == 100)
        #expect(try await session.count(database: db, collection: "idx", filter: BSONDocument(["k": .int32(3)])) == 10)
        let collections = try await session.listCollections(database: db)
        #expect(collections.contains { $0.name == "idx" && $0.type == "collection" })
        #expect(try await session.listDatabases().contains { $0.name == db })
        let stats = try await session.collectionStats(database: db, collection: "idx")
        #expect(stats["count"] != nil)
    }
}
