import DatabaseKit
import XCTest

@testable import Umbra

/// Staged inserts, deletes and expressions against real SQLite files, through the same facade the
/// result grid uses: conflicts, rejected rows, and the local → submitted → committed / rolled-back
/// states when the console has a transaction open.
@MainActor
final class IDEDatabaseRowMutationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-row-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSupport() -> IDEDatabaseSupport {
        let catalog = IDEDatabaseCatalog(storeURL: directory.appendingPathComponent("database-connections.json"))
        return IDEDatabaseSupport(catalog: catalog, keychain: IDEDatabaseMemoryKeyStore())
    }

    private func makeDatabase(named name: String, statements: [String]) async throws -> String {
        let path = directory.appendingPathComponent(name).path
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(path), createIfMissing: true))
        let store = ResultStore(columns: [])
        for statement in statements { _ = try await session.execute(statement, into: store) }
        await store.close()
        await session.close()
        return path
    }

    private static let itemStatements = [
        "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT DEFAULT 'none', stamp TEXT, code TEXT UNIQUE)",
        "INSERT INTO items (name, note, code) VALUES ('apple', 'a', 'A'), ('pear', 'p', 'P'), ('plum', 'q', 'Q')",
    ]

    private func browse(
        _ support: IDEDatabaseSupport, table: String, connection: DatabaseConnection
    ) async throws -> (pending: IDEDatabasePendingEdits, storage: IDEDatabaseResultStorage, rows: [[DatabaseValue]]) {
        let binding = IDEDatabaseConsoleBinding(connectionID: connection.id, sqliteBrowseTable: table)
        await support.execute(statement: #"SELECT * FROM "main"."\#(table)""#, binding: binding, resetSort: true)
        let pending = try XCTUnwrap(support.result.pendingEdits, support.result.readOnlyReason ?? "no pending edits")
        let storage = try XCTUnwrap(support.result.storage)
        let rows = try await storage.store.rows(in: 0..<support.result.rowCount)
        return (pending, storage, rows)
    }

    func testInsertDuplicateDeleteAndEditCommitAsOneBatchAndUndoStepsBack() async throws {
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: try await makeDatabase(named: "batch.sqlite", statements: Self.itemStatements))
        let (pending, storage, rows) = try await browse(support, table: "items", connection: connection)
        let target = pending.target
        XCTAssertEqual(target.identity, .primaryKey)
        XCTAssertEqual(target.insertColumns.map(\.name), ["id", "name", "note", "stamp", "code"])
        XCTAssertTrue(target.insertColumns[0].isRowIDAlias)
        XCTAssertFalse(target.insertColumns[0].required)
        XCTAssertTrue(target.insertColumns[1].required)
        XCTAssertEqual(target.insertColumns[2].defaultExpression, "'none'")

        // A duplicate keeps every value but the rowid alias; the unique code must change.
        let columns = await storage.store.snapshot.columns
        var fields = target.duplicate(values: rows[0], columns: columns)
        XCTAssertEqual(fields.map(\.column), ["name", "note", "stamp", "code"])
        fields = fields.map { $0.column == "code" ? .init(column: "code", value: .value(.text("A2"))) : $0 }
        try pending.stageInsertion(fields)
        XCTAssertThrowsError(try pending.stageInsertion([.init(column: "note", value: .value(.text("no name")))]),
                             "A NOT NULL column without a default must be filled")
        XCTAssertThrowsError(try pending.stageInsertion([.init(column: "name", value: .value(.text("x"))),
                                                         .init(column: "ghost", value: .value(.int(1)))]))

        // Delete one row, and a cell edit staged for it disappears with it.
        let edit = try XCTUnwrap(target.draft(row: 1, column: 2, values: rows[1]))
        try pending.stage(edit, replacement: .expression(.columnDefault("'none'")))
        XCTAssertEqual(pending.edits.count, 1)
        try pending.stageDeletions([try XCTUnwrap(target.deletion(row: 1, values: rows[1]))])
        XCTAssertTrue(pending.edits.isEmpty)
        XCTAssertEqual(pending.deletedRows, [1])
        XCTAssertThrowsError(try pending.stage(edit, replacement: .value(.text("again"))), "A deleted row cannot be edited")
        pending.undo()
        XCTAssertTrue(pending.deletedRows.isEmpty)
        XCTAssertEqual(pending.edits.count, 1, "One undo restores the deletion and its dropped edit")
        pending.redo()
        XCTAssertEqual(pending.deletedRows, [1])

        // A clock expression and an explicit value on another row.
        let stamp = try XCTUnwrap(target.draft(row: 2, column: 3, values: rows[2]))
        try pending.stage(stamp, replacement: .expression(.currentTimestamp))
        XCTAssertEqual(pending.changeCount, 3)
        XCTAssertEqual(pending.preview().map(\.kind), [.delete, .update, .insert])

        let committed = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertTrue(committed)
        XCTAssertEqual(pending.phase, .committed)
        XCTAssertEqual(pending.submittedCounts, .init(updatedRows: 1, insertedRows: 1, deletedRows: 1))
        let writer = try await SQLSession.connect(login: connection.sqlLogin(password: ""), readOnly: false)
        let actual = try await writer.query("SELECT id, name, code, stamp IS NOT NULL FROM items ORDER BY id")
        XCTAssertEqual(actual.rows, [["1", "apple", "A", "0"], ["3", "plum", "Q", "1"], ["4", "apple", "A2", "0"]])
        await writer.disconnect()
        await support.disconnect(connection.id)
    }

    func testAChangedOrMissingRowBlocksADeleteAndTheBatchStaysStaged() async throws {
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: try await makeDatabase(named: "conflict.sqlite", statements: Self.itemStatements))
        let (pending, storage, rows) = try await browse(support, table: "items", connection: connection)
        let target = pending.target
        try pending.stageDeletions([try XCTUnwrap(target.deletion(row: 0, values: rows[0])),
                                    try XCTUnwrap(target.deletion(row: 1, values: rows[1]))])
        let writer = try await SQLSession.connect(login: connection.sqlLogin(password: ""), readOnly: false)
        _ = try await writer.query("UPDATE items SET note = 'edited elsewhere' WHERE id = 2")

        let first = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertFalse(first)
        let conflict = try XCTUnwrap(pending.conflict)
        XCTAssertEqual(conflict.row.kind, .delete)
        XCTAssertEqual(conflict.row.row, 1)
        XCTAssertEqual(conflict.current?.contains(.text("edited elsewhere")), true)
        var remaining = try await writer.query("SELECT count(*) FROM items")
        XCTAssertEqual(remaining.rows, [["3"]], "Nothing was deleted, including the row that did match")
        XCTAssertEqual(pending.deletedRows, [0, 1])

        pending.rebaseConflict()
        XCTAssertNil(pending.conflict)
        _ = try await writer.query("DELETE FROM items WHERE id = 1")
        let second = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertFalse(second, "A row that is already gone is a conflict, not a silent success")
        XCTAssertNil(pending.conflict?.current)
        pending.discardConflictedRow()
        XCTAssertEqual(pending.deletedRows, [1], "Only the conflicting row's change is dropped")
        let third = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertTrue(third)
        remaining = try await writer.query("SELECT id FROM items")
        XCTAssertEqual(remaining.rows, [["3"]])
        await writer.disconnect()
        await support.disconnect(connection.id)
    }

    func testARejectedRowNamesItselfAndLeavesEverythingStagedAndUnwritten() async throws {
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: try await makeDatabase(named: "reject.sqlite", statements: Self.itemStatements))
        let (pending, storage, rows) = try await browse(support, table: "items", connection: connection)
        let edit = try XCTUnwrap(pending.target.draft(row: 0, column: 1, values: rows[0]))
        try pending.stage(edit, replacement: .text("changed"))
        try pending.stageInsertion([.init(column: "name", value: .value(.text("clash"))),
                                    .init(column: "code", value: .value(.text("P")))])

        let submitted = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertFalse(submitted)
        let rejection = try XCTUnwrap(pending.rejection)
        XCTAssertEqual(rejection.row.kind, .insert)
        XCTAssertTrue(rejection.message.contains("UNIQUE"), rejection.message)
        XCTAssertEqual(pending.phase, .local)
        XCTAssertEqual(pending.changeCount, 2)
        let writer = try await SQLSession.connect(login: connection.sqlLogin(password: ""), readOnly: false)
        let name = try await writer.query("SELECT name FROM items WHERE id = 1")
        XCTAssertEqual(name.rows, [["apple"]])

        pending.undo()
        XCTAssertNil(pending.rejection, "Changing the batch clears the stale rejection")
        try pending.stageInsertion([.init(column: "name", value: .value(.text("fine"))), .init(column: "code", value: .value(.text("Z")))])
        let again = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertTrue(again)
        await writer.disconnect()
        await support.disconnect(connection.id)
    }

    func testSubmittingInsideAnOpenTransactionIsNotCommittedUntilTheUserCommits() async throws {
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: try await makeDatabase(named: "txn.sqlite", statements: Self.itemStatements))
        let (pending, storage, rows) = try await browse(support, table: "items", connection: connection)
        let writer = try await SQLSession.connect(login: connection.sqlLogin(password: ""), readOnly: false)
        func count() async throws -> String? {
            try await writer.query("SELECT count(*) FROM items").rows.first?.first ?? nil
        }

        await support.performTransaction(.begin(.init()), connectionID: connection.id)
        XCTAssertEqual(support.sqlTransactions[connection.id], .active(readOnly: false))
        try pending.stageDeletions([try XCTUnwrap(pending.target.deletion(row: 0, values: rows[0]))])
        let submitted = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertTrue(submitted)
        XCTAssertEqual(pending.phase, .submitted)
        XCTAssertEqual(pending.submittedCounts.deletedRows, 1)
        XCTAssertTrue(pending.edits.isEmpty && pending.deletedRows.isEmpty)
        XCTAssertEqual(support.sqlTransactions[connection.id], .active(readOnly: false), "The user's transaction stays open")
        XCTAssertNotNil(support.closeBlocker)
        let inside = try await support.sqlSession(for: connection.id)?.query("SELECT count(*) FROM items")
        XCTAssertEqual(inside?.rows, [["2"]])
        let outside = try await count()
        XCTAssertEqual(outside, "3", "Not committed yet")

        // Rolling back shows as rolled back and offers the same batch again.
        await support.performTransaction(.rollback, connectionID: connection.id)
        XCTAssertEqual(pending.phase, .rolledBack)
        let restored = try await count()
        XCTAssertEqual(restored, "3")
        pending.restageRolledBack()
        XCTAssertEqual(pending.phase, .local)
        XCTAssertEqual(pending.deletedRows, [0])

        await support.performTransaction(.begin(.init()), connectionID: connection.id)
        _ = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertEqual(pending.phase, .submitted)
        await support.performTransaction(.commit, connectionID: connection.id)
        XCTAssertEqual(pending.phase, .committed)
        let committed = try await count()
        XCTAssertEqual(committed, "2")
        XCTAssertNil(support.closeBlocker)
        await writer.disconnect()
        await support.disconnect(connection.id)
    }

    func testARawRollbackOrSavepointRollbackInTheConsoleDecidesTheSubmittedBatch() async throws {
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: try await makeDatabase(named: "raw.sqlite", statements: Self.itemStatements))
        let binding = IDEDatabaseConsoleBinding(connectionID: connection.id, sqliteBrowseTable: "items")
        let (pending, storage, rows) = try await browse(support, table: "items", connection: connection)

        // ROLLBACK TO a savepoint taken before the submit undoes it.
        await support.performTransaction(.begin(.init()), connectionID: connection.id)
        await support.performTransaction(.savepoint, connectionID: connection.id)
        let savepoint = try XCTUnwrap(support.databaseSavepoints[connection.id]?.first)
        try pending.stageDeletions([try XCTUnwrap(pending.target.deletion(row: 2, values: rows[2]))])
        _ = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertEqual(pending.phase, .submitted)
        await support.performTransaction(.rollbackTo(savepoint), connectionID: connection.id)
        XCTAssertEqual(pending.phase, .rolledBack)

        // A typed COMMIT in the console is read from its own words.
        pending.restageRolledBack()
        _ = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertEqual(pending.phase, .submitted)
        await support.execute(statement: "COMMIT", binding: binding, resetSort: true)
        XCTAssertEqual(pending.phase, .committed)

        XCTAssertEqual(IDEDatabaseSupport.transactionBoundary(of: "  -- done\n rollback to savepoint \"Sp1\"", engine: .sqlite),
                       .rolledBackTo("sp1"))
        XCTAssertEqual(IDEDatabaseSupport.transactionBoundary(of: "END", engine: .sqlite), .committed)
        XCTAssertEqual(IDEDatabaseSupport.transactionBoundary(of: "ROLLBACK", engine: .postgres), .rolledBack)
        XCTAssertNil(IDEDatabaseSupport.transactionBoundary(of: "SELECT 1", engine: .sqlite))
        await support.disconnect(connection.id)
    }

    func testATableWithoutAKeyIsEditedThroughItsRowIDAndSaysWhyWhenItCannotBe() async throws {
        let support = makeSupport()
        let path = try await makeDatabase(named: "rowid.sqlite", statements: [
            "CREATE TABLE log (message TEXT, level TEXT)",
            "INSERT INTO log VALUES ('boot', 'info'), ('boot', 'info')",
            "CREATE TABLE odd (rowid TEXT, oid TEXT, _rowid_ TEXT, v TEXT)",
            "INSERT INTO odd VALUES ('a', 'b', 'c', 'd')",
            "CREATE VIEW recent AS SELECT message FROM log",
        ])
        let connection = try await support.addSQLiteSource(path: path)
        let (pending, storage, rows) = try await browse(support, table: "log", connection: connection)
        XCTAssertEqual(pending.target.identity, .rowID)
        XCTAssertEqual(support.result.columns, ["rowid", "message", "level"])
        XCTAssertNil(pending.target.draft(row: 0, column: 0, values: rows[0]), "The rowid itself is not editable")
        let draft = try XCTUnwrap(pending.target.draft(row: 1, column: 2, values: rows[1]))
        try pending.stage(draft, replacement: .text("warn"))
        let committed = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertTrue(committed)
        let writer = try await SQLSession.connect(login: connection.sqlLogin(password: ""), readOnly: false)
        let levels = try await writer.query("SELECT rowid, level FROM log ORDER BY rowid")
        XCTAssertEqual(levels.rows, [["1", "info"], ["2", "warn"]], "Only the chosen duplicate row changed")
        await writer.disconnect()

        // Every alias is a real column, so there is nothing safe to select, and the lock says so.
        let odd = IDEDatabaseConsoleBinding(connectionID: connection.id, sqliteBrowseTable: "odd")
        await support.execute(statement: #"SELECT * FROM "main"."odd""#, binding: odd, resetSort: true)
        XCTAssertNil(support.result.pendingEdits)
        XCTAssertTrue(try XCTUnwrap(support.result.readOnlyReason).contains("rowid"), support.result.readOnlyReason ?? "")

        // A read-only source browses a keyless table as it is: no rowid column, nothing to edit.
        let readOnlyPath = try await makeDatabase(named: "rowid-readonly.sqlite", statements: [
            "CREATE TABLE log (message TEXT, level TEXT)", "INSERT INTO log VALUES ('boot', 'info')",
        ])
        let readOnlySource = try await support.addSQLiteSource(path: readOnlyPath, readOnly: true)
        let plain = IDEDatabaseConsoleBinding(connectionID: readOnlySource.id, sqliteBrowseTable: "log")
        await support.execute(statement: #"SELECT * FROM "main"."log""#, binding: plain, resetSort: true)
        XCTAssertEqual(support.result.columns, ["message", "level"])
        XCTAssertNil(support.result.pendingEdits)
        let view = IDEDatabaseConsoleBinding(connectionID: connection.id, sqliteBrowseTable: "recent")
        await support.execute(statement: #"SELECT * FROM "main"."recent""#, binding: view, resetSort: true)
        XCTAssertNil(support.result.pendingEdits)
        XCTAssertEqual(support.result.readOnlyReason, "recent is a view, not a table.")
        await support.disconnect(connection.id)
    }
}
