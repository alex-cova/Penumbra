import Foundation
import Testing

@testable import DatabaseKit

private let liveEnabled = ProcessInfo.processInfo.environment["UMBRA_DB_INTEGRATION"] == "1"

/// Field edits on a real replica set: exact `_id`, type-preserving `$set`, a pre-flight check
/// against what the grid showed, and a filter that makes a racing change match nothing.
@Suite(.enabled(if: liveEnabled, "needs UMBRA_DB_INTEGRATION=1 and Scripts/db-test-env.sh up"), .serialized)
struct LiveMongoFieldUpdateTests {
    private let database = "umbra_edit_test"

    private func connect() async throws -> MongoSession {
        guard let url = ProcessInfo.processInfo.environment["UMBRA_TEST_MONGO_URL"] else {
            throw DatabaseError.executionFailed("UMBRA_TEST_MONGO_URL is not set; run Scripts/db-test-env.sh env")
        }
        return try await MongoSession.connect(login: MongoURLs.parse(url), readOnly: false)
    }

    private func cell(_ session: MongoSession, _ collection: String, _ id: BSONValue, _ field: String) async throws -> BSONValue? {
        let request = MongoFindRequest(database: database, collection: collection, filter: BSONDocument(["_id": id]), limit: 2)
        return try await session.console.findDocuments(request, limit: 2).first?[field]
    }

    @Test func editsKeepTheFieldsTypeAndUseTheExactID() async throws {
        let session = try await connect()
        defer { Task { await session.disconnect() } }
        try await session.console.dropCollection(database: database, collection: "typed")
        let objectID = BSONValue.objectId(Array(1...12))
        _ = try await session.console.insertOne(database: database, collection: "typed", document: BSONDocument([
            "_id": objectID, "small": .int32(5), "big": .int64(9_007_199_254_740_993), "ratio": .double(1.5),
            "name": .string("old"), "flag": .bool(false), "nothing": .null,
        ]))
        _ = try await session.console.insertOne(database: database, collection: "typed", document: BSONDocument([
            "_id": .string("custom"), "name": .string("other"),
        ]))
        defer { Task { try? await session.console.dropCollection(database: database, collection: "typed") } }

        let id = DatabaseValue.bson(typeName: "objectId", extendedJSON: ExtendedJSON.string(objectID, mode: .canonical))
        let update = MongoFieldUpdate(id: id, changes: [
            .init(field: "small", original: .int(5), replacement: .int(6)),
            .init(field: "big", original: .int(9_007_199_254_740_993), replacement: .int(9_007_199_254_740_994)),
            .init(field: "ratio", original: .double(1.5), replacement: .int(2)),
            .init(field: "name", original: .text("old"), replacement: .text("new")),
            .init(field: "flag", original: .bool(false), replacement: .bool(true)),
            .init(field: "nothing", original: .null, replacement: .text("set")),
            .init(field: "added", original: .missing, replacement: .int(7_000_000_000)),
        ])
        let textID = MongoFieldUpdate(id: .text("custom"), changes: [.init(field: "name", original: .text("other"), replacement: .text("renamed"))])
        let result = try await session.applyFieldUpdates(database: database, collection: "typed", updates: [update, textID])
        #expect(result.rowsAffected == 2)

        #expect(try await cell(session, "typed", objectID, "small") == .int32(6), "an int32 field stays int32")
        #expect(try await cell(session, "typed", objectID, "big") == .int64(9_007_199_254_740_994))
        #expect(try await cell(session, "typed", objectID, "ratio") == .double(2), "a double field stays double")
        #expect(try await cell(session, "typed", objectID, "name") == .string("new"))
        #expect(try await cell(session, "typed", objectID, "flag") == .bool(true))
        #expect(try await cell(session, "typed", objectID, "nothing") == .string("set"))
        #expect(try await cell(session, "typed", objectID, "added") == .int64(7_000_000_000))
        #expect(try await cell(session, "typed", .string("custom"), "name") == .string("renamed"))
    }

    @Test func aChangedFieldOrMissingDocumentWritesNothing() async throws {
        let session = try await connect()
        defer { Task { await session.disconnect() } }
        try await session.console.dropCollection(database: database, collection: "guard")
        for number in 1...2 {
            _ = try await session.console.insertOne(database: database, collection: "guard",
                                                    document: BSONDocument(["_id": .int32(Int32(number)), "v": .string("a\(number)")]))
        }
        defer { Task { try? await session.console.dropCollection(database: database, collection: "guard") } }
        _ = try await session.console.updateOne(database: database, collection: "guard",
                                                filter: BSONDocument(["_id": .int32(2)]),
                                                update: BSONDocument(["$set": .document(BSONDocument(["v": .string("edited elsewhere")]))]))

        let updates = [
            MongoFieldUpdate(id: .int(1), changes: [.init(field: "v", original: .text("a1"), replacement: .text("b1"))]),
            MongoFieldUpdate(id: .int(2), changes: [.init(field: "v", original: .text("a2"), replacement: .text("b2"))]),
        ]
        do {
            _ = try await session.applyFieldUpdates(database: database, collection: "guard", updates: updates)
            Issue.record("the changed document must be a conflict")
        } catch let conflict as SQLiteOptimisticConflict {
            #expect(conflict.updateIndex == 1)
            #expect(conflict.current == [.text("edited elsewhere")])
        }
        #expect(try await cell(session, "guard", .int32(1), "v") == .string("a1"), "the document that did match was not written")

        do {
            _ = try await session.applyFieldUpdates(database: database, collection: "guard", updates: [
                MongoFieldUpdate(id: .int(99), changes: [.init(field: "v", original: .text("x"), replacement: .text("y"))]),
            ])
            Issue.record("a missing document must be a conflict")
        } catch let conflict as SQLiteOptimisticConflict {
            #expect(conflict.current == nil)
        }
        // _id cannot be edited, and a binary id cannot name its document.
        await #expect(throws: Error.self) {
            _ = try await session.applyFieldUpdates(database: database, collection: "guard", updates: [
                MongoFieldUpdate(id: .int(1), changes: [.init(field: "_id", original: .int(1), replacement: .int(5))]),
            ])
        }
        await #expect(throws: Error.self) {
            _ = try await session.applyFieldUpdates(database: database, collection: "guard", updates: [
                MongoFieldUpdate(id: .bytes(count: 2, prefix: [1, 2]), changes: [.init(field: "v", original: .text("a1"), replacement: .text("z"))]),
            ])
        }
    }

    @Test func aReadOnlySessionRefusesBeforeReadingAnything() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["UMBRA_TEST_MONGO_URL"])
        let session = try await MongoSession.connect(login: MongoURLs.parse(url), readOnly: true)
        defer { Task { await session.disconnect() } }
        await #expect(throws: DatabaseError.self) {
            _ = try await session.applyFieldUpdates(database: database, collection: "guard", updates: [
                MongoFieldUpdate(id: .int(1), changes: [.init(field: "v", original: .text("a"), replacement: .text("b"))]),
            ])
        }
    }
}
