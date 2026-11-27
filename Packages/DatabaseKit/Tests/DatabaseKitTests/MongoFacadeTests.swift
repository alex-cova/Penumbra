import Foundation
import Testing

@testable import DatabaseKit

struct MongoTableTests {
    @Test func missingFieldsAreNilAndExplicitNullIsText() throws {
        let documents = [
            BSONDocument(["_id": .int32(1), "a": .null, "b": .string("x")]),
            BSONDocument(["_id": .int32(2), "c": .double(2)]),
        ]
        let result = MongoTable.result(from: documents)
        #expect(result.columns == ["_id", "a", "b", "c"])
        #expect(result.rows[0] == ["1", "null", "x", nil], "a field the document lacks is nil; an explicit null is the text null")
        #expect(result.rows[1] == ["2", nil, nil, "2"])
    }

    @Test func valuesKeepTheirExactText() throws {
        let document = BSONDocument([
            "_id": .objectId(Array(0..<12)), "big": .int64(9_007_199_254_740_993), "dec": .decimal128(try Decimal128Value("1.50")),
            "when": .date(milliseconds: 1_709_634_030_123), "bin": .binary(subtype: 0, bytes: [1, 2, 3]),
            "nested": .document(BSONDocument(["a": .array([.int32(1)])])), "empty": .string(""),
        ])
        let row = MongoTable.result(from: [document])
        let values = Dictionary(uniqueKeysWithValues: zip(row.columns, row.rows[0]))
        #expect(values["_id"]! == "000102030405060708090a0b")
        #expect(values["big"]! == "9007199254740993")
        #expect(values["dec"]! == "1.50")
        #expect(values["when"]! == "2024-03-05T10:20:30.123Z")
        #expect(values["bin"]! == "‹binary, 3 bytes›")
        #expect(values["nested"]! == "{\"a\":[1]}")
        #expect(values["empty"]! == "", "the empty string is not missing")
    }

    @Test func longNestedValuesAreBoundedNotCopiedWhole() {
        let document = BSONDocument(["_id": .int32(1), "big": .string(String(repeating: "x", count: 1_000_000))])
        let result = MongoTable.result(from: [document])
        // Plain strings are shown whole by design (the cell clips); documents and arrays are bounded.
        let nested = MongoTable.result(from: [BSONDocument(["_id": .int32(1), "d": .array(Array(repeating: .string("yyyyyyyy"), count: 10_000))])])
        #expect(nested.rows[0][1]!.count <= DatabaseValue.displayLimit + 1)
        #expect(result.rows[0][1]!.count == 1_000_000)
    }

    @Test func columnsAreCapped() {
        let document = BSONDocument((0..<100).map { BSONField("f\($0)", .int32(Int32($0))) })
        #expect(MongoTable.result(from: [document]).columns.count == MongoTable.columnLimit)
    }
}

private let liveEnabled = ProcessInfo.processInfo.environment["UMBRA_DB_INTEGRATION"] == "1"
    && ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != "true"  // never on the CI pipeline

@Suite(.enabled(if: liveEnabled, "needs UMBRA_DB_INTEGRATION=1 and Scripts/db-test-env.sh up"), .serialized)
struct LiveMongoFacadeTests {
    private let db = "umbra_test"

    private func connect(readOnly: Bool = false) async throws -> MongoSession {
        guard let url = ProcessInfo.processInfo.environment["UMBRA_TEST_MONGO_URL"] else {
            throw DatabaseError.executionFailed("UMBRA_TEST_MONGO_URL is not set; run Scripts/db-test-env.sh env")
        }
        return try await MongoSession.connect(login: MongoURLs.parse(url), readOnly: readOnly)
    }

    @Test func filtersAreExactExtendedJSONAndSortIsTheServers() async throws {
        let session = try await connect()
        defer { Task { await session.disconnect() } }
        try await session.console.dropCollection(database: db, collection: "facade")
        defer { Task { try? await session.console.dropCollection(database: self.db, collection: "facade") } }
        for index in [3, 1, 2] {
            try await session.insert(
                database: db, collection: "facade",
                documentJSON: "{\"_id\": {\"$numberLong\": \"900719925474099\(index)\"}, \"rank\": \(index), \"name\": \"n\(index)\"}"
            )
        }
        // Int64 ids above 2^53 can be asked for exactly. A filter that went through Double would
        // have rounded ...993 to ...992 and returned the wrong document.
        let three = try await session.find(
            database: db, collection: "facade", filterJSON: "{\"_id\": {\"$numberLong\": \"9007199254740993\"}}"
        )
        #expect(three.rows.map { $0[2] } == ["n3"])
        let one = try await session.find(
            database: db, collection: "facade", filterJSON: "{\"_id\": {\"$numberLong\": \"9007199254740991\"}}"
        )
        #expect(one.rows.map { $0[2] } == ["n1"])
        // Sorting is the server's, across the whole collection, not a re-ordering of a page.
        let ascending = try await session.find(database: db, collection: "facade", filterJSON: "", sortKey: "rank", sortAscending: true)
        #expect(ascending.rows.map { $0[2] } == ["n1", "n2", "n3"])
        let descending = try await session.find(database: db, collection: "facade", filterJSON: "", sortKey: "rank", sortAscending: false)
        #expect(descending.rows.map { $0[2] } == ["n3", "n2", "n1"])
        // The sort is applied before paging: page 1 of 1 row sorted descending is the top row.
        let page = try await session.find(database: db, collection: "facade", filterJSON: "", sortKey: "rank", sortAscending: false, skip: 1, limit: 1)
        #expect(page.rows.map { $0[2] } == ["n2"])
        // An invalid filter says where.
        await #expect(throws: DatabaseError.self) {
            _ = try await session.find(database: self.db, collection: "facade", filterJSON: "{\"a\": }")
        }
    }

    @Test func setFieldsChangesOnlyThoseFieldsAndRefusesStaleEdits() async throws {
        let session = try await connect()
        defer { Task { await session.disconnect() } }
        try await session.console.dropCollection(database: db, collection: "setfields")
        defer { Task { try? await session.console.dropCollection(database: self.db, collection: "setfields") } }
        try await session.insert(
            database: db, collection: "setfields",
            documentJSON: "{\"_id\": 1, \"name\": \"Ada\", \"score\": {\"$numberDecimal\": \"9.50\"}, \"old\": 1}"
        )
        try await session.setFields(
            database: db, collection: "setfields", idJSON: "{\"_id\": 1}", setJSON: "{\"name\": \"Ada L.\"}",
            unset: ["old"], expectedJSON: "{\"name\": \"Ada\", \"old\": 1}"
        )
        let afterFirst = try await session.console.findDocuments(MongoFindRequest(database: db, collection: "setfields"), limit: 10)
        #expect(afterFirst[0]["name"] == .string("Ada L."))
        #expect(afterFirst[0]["old"] == nil, "$unset removes the field (absent, not null)")
        #expect(afterFirst[0]["score"] == .decimal128(try Decimal128Value("9.50")), "untouched fields keep their exact type")
        // The same edit again is stale: `name` is no longer "Ada".
        await #expect(throws: DatabaseError.self) {
            try await session.setFields(
                database: self.db, collection: "setfields", idJSON: "{\"_id\": 1}", setJSON: "{\"name\": \"overwritten\"}",
                expectedJSON: "{\"name\": \"Ada\"}"
            )
        }
        let afterStale = try await session.console.findDocuments(MongoFindRequest(database: db, collection: "setfields"), limit: 10)
        #expect(afterStale[0]["name"] == .string("Ada L."))
    }

    @Test func readOnlyFacadeRefusesEveryWrite() async throws {
        let writer = try await connect()
        let reader = try await connect(readOnly: true)
        defer { Task { await writer.disconnect(); await reader.disconnect() } }
        try await writer.console.dropCollection(database: db, collection: "facade_ro")
        defer { Task { try? await writer.console.dropCollection(database: self.db, collection: "facade_ro") } }
        try await writer.insert(database: db, collection: "facade_ro", documentJSON: "{\"_id\": 1}")
        await #expect(throws: DatabaseError.readOnlyViolation) { try await reader.insert(database: self.db, collection: "facade_ro", documentJSON: "{\"_id\": 2}") }
        await #expect(throws: DatabaseError.readOnlyViolation) { try await reader.replace(database: self.db, collection: "facade_ro", documentJSON: "{\"_id\": 1, \"x\": 1}") }
        await #expect(throws: DatabaseError.readOnlyViolation) { try await reader.delete(database: self.db, collection: "facade_ro", idJSON: "{\"_id\": 1}") }
        await #expect(throws: DatabaseError.readOnlyViolation) {
            try await reader.setFields(database: self.db, collection: "facade_ro", idJSON: "{\"_id\": 1}", setJSON: "{\"x\": 1}")
        }
        #expect(try await reader.find(database: db, collection: "facade_ro", filterJSON: "").rows.count == 1)
    }

    @Test func theExplorerListsWhileAQueryRuns() async throws {
        let session = try await connect()
        defer { Task { await session.disconnect() } }
        try await session.console.dropCollection(database: db, collection: "explorer")
        defer { Task { try? await session.console.dropCollection(database: self.db, collection: "explorer") } }
        try await session.insert(database: db, collection: "explorer", documentJSON: "{\"_id\": 1}")
        let slow = Task {
            try await session.find(
                database: self.db, collection: "explorer",
                filterJSON: "{\"$where\": \"sleep(2000) || true\"}"
            )
        }
        try await Task.sleep(for: .milliseconds(400))
        let started = ContinuousClock.now
        let databases = try await session.listDatabases()
        let collections = try await session.listCollections(database: db)
        let elapsed = ContinuousClock.now - started
        #expect(databases.contains(db))
        #expect(collections.contains("explorer"))
        #expect(elapsed < .seconds(1.5), "catalog reads waited behind the running query (\(elapsed))")
        _ = try await slow.value
    }
}
