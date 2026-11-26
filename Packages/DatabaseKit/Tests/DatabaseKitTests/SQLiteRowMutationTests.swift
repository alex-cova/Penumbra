import Foundation
import Testing

@testable import DatabaseKit

/// Row mutations against real SQLite files: the batch is atomic, a changed or missing row is a
/// conflict, a rejected statement names its row, and a batch can ride inside the caller's
/// transaction without committing it.
private final class TempDatabase {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-mutation-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    var path: String { url.appendingPathComponent("db.sqlite").path }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private func query(_ session: SQLiteSession, _ sql: String, _ parameters: [DatabaseValue] = []) async throws -> [[DatabaseValue]] {
    try await session.run(sql, parameters: parameters)
}

private func open(_ database: TempDatabase) async throws -> (SQLiteSession, Int) {
    let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(database.path), createIfMissing: true))
    _ = try await query(session, """
    CREATE TABLE items (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        note TEXT DEFAULT 'none',
        stamp TEXT,
        code TEXT UNIQUE
    )
    """)
    _ = try await query(session, "INSERT INTO items (name, note, code) VALUES ('apple', 'a', 'A'), ('pear', 'p', 'P')")
    let version = try await session.pragma("schema_version")
    return (session, Int(version ?? "") ?? 0)
}

struct SQLiteRowMutationTests {
    @Test func insertLeavesDefaultColumnsOutAndReportsTheRowID() async throws {
        let database = TempDatabase()
        let (session, version) = try await open(database)
        let insert = SQLiteInsert(fields: [
            .init(column: "name", value: .value(.text("plum"))),
            .init(column: "note", value: .expression(.columnDefault("'none'"))),
            .init(column: "stamp", value: .expression(.currentDate)),
        ])
        let statement = try insert.statement(table: "items")
        #expect(statement.sql.contains("\"name\", \"stamp\""))
        #expect(!statement.sql.contains("\"note\""))
        #expect(statement.parameters == [.text("plum")])
        let result = try await session.applyMutations([.insert(insert)], table: "items", schemaVersion: version)
        #expect(result.rowsAffected == 1)
        #expect(result.insertedRowIDs[0] == 3)
        let rows = try await query(session, "SELECT name, note, stamp IS NOT NULL FROM items WHERE id = 3")
        #expect(rows == [[.text("plum"), .text("none"), .int(1)]])
        await session.close()
    }

    @Test func emptyInsertUsesDefaultValues() async throws {
        let statement = try SQLiteInsert(fields: [.init(column: "note", value: .expression(.columnDefault("'none'")))])
            .statement(table: "items")
        #expect(statement.sql == "INSERT INTO \"main\".\"items\" DEFAULT VALUES;" || statement.sql.hasSuffix("DEFAULT VALUES;"))
        #expect(statement.parameters.isEmpty)
    }

    @Test func updateCanAssignAnExpression() async throws {
        let database = TempDatabase()
        let (session, version) = try await open(database)
        let update = SQLiteOptimisticUpdate(
            keys: [.init(column: "id", value: .int(1))],
            changes: [.init(column: "stamp", original: .null, replacement: .expression(.currentTimestamp)),
                      .init(column: "note", original: .text("a"), replacement: .expression(.columnDefault("'none'")))]
        )
        try await session.applyMutations([.update(update)], table: "items", schemaVersion: version)
        let rows = try await query(session, "SELECT note, stamp IS NOT NULL FROM items WHERE id = 1")
        #expect(rows == [[.text("none"), .int(1)]])
        await session.close()
    }

    @Test func deleteChecksTheLoadedValuesAndReportsWhatChanged() async throws {
        let database = TempDatabase()
        let (session, version) = try await open(database)
        let stale = SQLiteDelete(keys: [.init(column: "id", value: .int(2))],
                                 originals: [.init(column: "name", value: .text("pear")), .init(column: "note", value: .text("old"))])
        do {
            try await session.applyMutations([.delete(stale)], table: "items", schemaVersion: version)
            Issue.record("A row that no longer matches the loaded values must not be deleted")
        } catch let conflict as SQLiteOptimisticConflict {
            #expect(conflict.isDeletion)
            #expect(conflict.current == [.text("pear"), .text("p")])
        }
        #expect(try await query(session, "SELECT count(*) FROM items") == [[.int(2)]])

        let current = SQLiteDelete(keys: [.init(column: "id", value: .int(2))],
                                   originals: [.init(column: "name", value: .text("pear")), .init(column: "note", value: .text("p"))])
        try await session.applyMutations([.delete(current)], table: "items", schemaVersion: version)
        #expect(try await query(session, "SELECT id FROM items") == [[.int(1)]])

        let missing = SQLiteDelete(keys: [.init(column: "id", value: .int(2))], originals: [])
        do {
            try await session.applyMutations([.delete(missing)], table: "items", schemaVersion: version)
            Issue.record("Deleting a row that is already gone is a conflict")
        } catch let conflict as SQLiteOptimisticConflict {
            #expect(conflict.current == nil)
        }
        await session.close()
    }

    @Test func aRejectedStatementRollsBackTheWholeBatchAndNamesItsRow() async throws {
        let database = TempDatabase()
        let (session, version) = try await open(database)
        let good = SQLiteRowMutation.update(.init(keys: [.init(column: "id", value: .int(1))],
                                                  changes: [.init(column: "name", original: .text("apple"), replacement: .text("fig"))]))
        let duplicate = SQLiteRowMutation.insert(.init(fields: [.init(column: "name", value: .value(.text("x"))),
                                                                .init(column: "code", value: .value(.text("A")))]))
        do {
            try await session.applyMutations([good, duplicate], table: "items", schemaVersion: version)
            Issue.record("A UNIQUE violation must reject the batch")
        } catch let failure as SQLiteMutationFailure {
            #expect(failure.index == 1)
            #expect(failure.message.contains("UNIQUE"))
        }
        #expect(try await query(session, "SELECT name FROM items WHERE id = 1") == [[.text("apple")]])
        #expect(await session.transaction == .none)
        await session.close()
    }

    @Test func aStaleSchemaRejectsTheBatch() async throws {
        let database = TempDatabase()
        let (session, version) = try await open(database)
        _ = try await query(session, "ALTER TABLE items ADD COLUMN extra TEXT")
        let insert = SQLiteRowMutation.insert(.init(fields: [.init(column: "name", value: .value(.text("late")))]))
        await #expect(throws: Error.self) {
            try await session.applyMutations([insert], table: "items", schemaVersion: version)
        }
        #expect(try await query(session, "SELECT count(*) FROM items") == [[.int(2)]])
        await session.close()
    }

    @Test func insideAnOpenTransactionTheBatchIsSubmittedButNotCommitted() async throws {
        let database = TempDatabase()
        let (session, version) = try await open(database)
        let other = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(database.path)))
        try await session.begin()
        let insert = SQLiteRowMutation.insert(.init(fields: [.init(column: "name", value: .value(.text("kiwi")))]))
        let result = try await session.applyMutations([insert], table: "items", schemaVersion: version)
        #expect(result.leftTransactionOpen)
        #expect(await session.transaction.isOpen)
        #expect(try await query(session, "SELECT count(*) FROM items") == [[.int(3)]])
        #expect(try await query(other, "SELECT count(*) FROM items") == [[.int(2)]], "Not committed yet")

        // A failing batch inside the transaction undoes only itself.
        let clash = SQLiteRowMutation.insert(.init(fields: [.init(column: "name", value: .value(.text("z"))),
                                                            .init(column: "code", value: .value(.text("P")))]))
        await #expect(throws: SQLiteMutationFailure.self) {
            try await session.applyMutations([clash], table: "items", schemaVersion: version)
        }
        #expect(await session.transaction.isOpen)
        #expect(try await query(session, "SELECT count(*) FROM items") == [[.int(3)]])

        try await session.rollback()
        #expect(try await query(session, "SELECT count(*) FROM items") == [[.int(2)]])
        try await session.begin()
        try await session.applyMutations([insert], table: "items", schemaVersion: version)
        try await session.commit()
        #expect(try await query(other, "SELECT count(*) FROM items") == [[.int(3)]])
        await session.close()
        await other.close()
    }

    @Test func rowidIdentifiesRowsOfATableWithoutAKey() async throws {
        let database = TempDatabase()
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(database.path), createIfMissing: true))
        _ = try await query(session, "CREATE TABLE log (message TEXT, level TEXT)")
        _ = try await query(session, "INSERT INTO log VALUES ('a', 'info'), ('a', 'info')")
        let version = Int(try await session.pragma("schema_version") ?? "") ?? 0
        let update = SQLiteOptimisticUpdate(keys: [.init(column: "rowid", value: .int(2))],
                                            changes: [.init(column: "level", original: .text("info"), replacement: .text("warn"))])
        try await session.applyMutations([.update(update)], table: "log", schemaVersion: version)
        #expect(try await query(session, "SELECT rowid, level FROM log ORDER BY rowid") == [[.int(1), .text("info")], [.int(2), .text("warn")]])
        await session.close()
    }

    @Test func unsupportedExpressionsAreRefused() throws {
        #expect(throws: Error.self) {
            try SQLiteInsert(fields: [.init(column: "name", value: .expression(.columnDefault("1; DROP TABLE items")))])
                .statement(table: "items")
        }
        #expect(!SQLiteExpression.columnDefault("").isSupported)
    }
}
