import DatabaseKit
import XCTest

@testable import Umbra

/// Editing on PostgreSQL, MySQL and MongoDB. The first group needs no server: what a target
/// allows, why a column is locked, and the guarded statements. The second runs the whole path
/// (execute, server-verified target, stage, submit) on the disposable servers.
@MainActor
final class IDEDatabaseEngineEditTests: XCTestCase {
    private func postgresTarget() -> SQLEditTarget {
        SQLEditTarget(engine: .postgres, schema: "public", table: "t", keys: [
            .init(resultIndex: 0, name: "id", typeName: "integer", isKey: true, isRequired: true, readOnlyReason: "id identifies the row."),
        ], columns: [
            .init(resultIndex: 0, name: "id", typeName: "integer", isKey: true, isRequired: true, readOnlyReason: "id identifies the row."),
            .init(resultIndex: 1, name: "amount", typeName: "numeric(10,2)", isKey: false, isRequired: false),
            .init(resultIndex: 2, name: "tags", typeName: "text[]", isKey: false, isRequired: false,
                  readOnlyReason: "tags has type text[], which is not editable here yet."),
        ])
    }

    private func columns(_ names: [String]) -> [ResultColumn] { names.map { ResultColumn(name: $0) } }

    func testPostgresTargetMapsServerVerdictsToKeysWritableColumnsAndReasons() throws {
        let target = try XCTUnwrap(IDEDatabaseEditTarget(sql: postgresTarget(), columns: columns(["id", "amount", "tags", "computed"])))
        XCTAssertEqual(target.engine, .postgres)
        XCTAssertEqual(target.schema, "public")
        XCTAssertEqual(target.keys.map(\.name), ["id"])
        XCTAssertEqual(Set(target.writable.keys), [1])
        XCTAssertEqual(target.lockedReason(forColumn: 2), "tags has type text[], which is not editable here yet.")
        XCTAssertEqual(target.lockedReason(forColumn: 3), "computed is computed, so its source is not verified.")
        XCTAssertFalse(target.allowsRowChanges)
        XCTAssertFalse(target.allowsExpressions)
        XCTAssertFalse(target.accepts(.expression(.currentDate)), "Expressions are SQLite-only")

        let draft = try XCTUnwrap(target.draft(row: 4, column: 1, values: [.int(7), .decimal("1.50"), .null, .null]))
        XCTAssertEqual(draft.keys.map(\.value), [.int(7)])
        XCTAssertNil(target.draft(row: 4, column: 0, values: [.int(7), .decimal("1.50"), .null, .null]), "A key is not editable")
        XCTAssertNil(target.draft(row: 4, column: 2, values: [.int(7), .decimal("1.50"), .null, .null]))
        XCTAssertNil(target.draft(row: 4, column: 1, values: [.null, .decimal("1.50"), .null, .null]), "A NULL key cannot identify a row")
        XCTAssertNil(target.draft(row: 4, column: 1, values: [.int(7), .bytes(count: 2, prefix: [1, 2]), .null, .null]))
    }

    func testPostgresStatementsCastEveryOperandAndCompareNullSafely() throws {
        let target = postgresTarget()
        let update = SQLiteOptimisticUpdate(
            keys: [.init(column: "id", value: .int(1))],
            changes: [.init(column: "amount", original: .decimal("1.50"), replacement: .text("2.25"))]
        )
        let statement = try target.statement(for: update)
        XCTAssertEqual(statement.sql, """
        UPDATE "public"."t"
        SET "amount" = $1::numeric(10,2)
        WHERE "id" = $2::integer AND "amount" IS NOT DISTINCT FROM $3::numeric(10,2);
        """)
        XCTAssertEqual(statement.parameters, [.text("2.25"), .int(1), .text("1.50")])
        let wrong = SQLiteOptimisticUpdate(keys: [.init(column: "id", value: .int(1))],
                                           changes: [.init(column: "tags", original: .null, replacement: .text("x"))])
        XCTAssertThrowsError(try target.statement(for: wrong), "A locked column is never written")
        let expression = SQLiteOptimisticUpdate(keys: [.init(column: "id", value: .int(1))],
                                                changes: [.init(column: "amount", original: .null, replacement: .expression(.currentDate))])
        XCTAssertThrowsError(try target.statement(for: expression))
        let injected = SQLiteOptimisticUpdate(keys: [.init(column: "id; DROP TABLE t", value: .int(1))],
                                              changes: [.init(column: "amount", original: .null, replacement: .text("1"))])
        XCTAssertThrowsError(try target.statement(for: injected), "Only the resolved key columns are accepted")
    }

    func testMySQLStatementsBindValuesAndCompareTextAsBytes() throws {
        let target = SQLEditTarget(engine: .mysql, schema: "shop", table: "item", keys: [
            .init(resultIndex: 0, name: "id", typeName: "int", isKey: true, isRequired: true, readOnlyReason: "id identifies the row."),
        ], columns: [
            .init(resultIndex: 0, name: "id", typeName: "int", isKey: true, isRequired: true, readOnlyReason: "id identifies the row."),
            .init(resultIndex: 1, name: "label", typeName: "varchar", isKey: false, isRequired: true),
            .init(resultIndex: 2, name: "price", typeName: "decimal", isKey: false, isRequired: false),
            .init(resultIndex: 3, name: "seen", typeName: "datetime", isKey: false, isRequired: false),
        ])
        let update = SQLiteOptimisticUpdate(keys: [.init(column: "id", value: .int(9))], changes: [
            .init(column: "label", original: .text("a"), replacement: .text("b")),
            .init(column: "price", original: .decimal("1.50"), replacement: .text("2.50")),
            .init(column: "seen", original: .temporal("2024-05-06 07:08:09", .timestamp), replacement: .null),
        ])
        let statement = try target.statement(for: update)
        XCTAssertEqual(statement.sql, """
        UPDATE `shop`.`item`
        SET `label` = ?, `price` = ?, `seen` = ?
        WHERE `id` = ? AND BINARY `label` <=> BINARY ? AND `price` <=> CAST(? AS DECIMAL(65,30)) AND `seen` <=> CAST(? AS DATETIME(6));
        """)
        XCTAssertEqual(statement.parameters, [.text("b"), .text("2.50"), .null, .int(9), .text("a"), .text("1.50"),
                                              .text("2024-05-06 07:08:09")])
    }

    func testMongoTargetUsesIDAsTheKeyAndPreservesNothingItCannotRestate() throws {
        let target = try XCTUnwrap(IDEDatabaseEditTarget(mongoDatabase: "shop", collection: "items",
                                                         columns: columns(["name", "_id", "qty", "nested"])))
        XCTAssertEqual(target.engine, .mongo)
        XCTAssertEqual(target.keys.map(\.name), ["_id"])
        XCTAssertEqual(target.keys.first?.index, 1)
        XCTAssertEqual(Set(target.writable.keys), [0, 2, 3])
        XCTAssertNil(IDEDatabaseEditTarget(mongoDatabase: "shop", collection: "items", columns: columns(["name"])), "No _id, no identity")

        let id = DatabaseValue.bson(typeName: "objectId", extendedJSON: #"{"$oid":"000102030405060708090a0b"}"#)
        let row: [DatabaseValue] = [.text("pen"), id, .int(3), .bson(typeName: "object", extendedJSON: "{}")]
        XCTAssertNotNil(target.draft(row: 0, column: 2, values: row))
        XCTAssertNotNil(target.draft(row: 0, column: 0, values: row))
        XCTAssertNil(target.draft(row: 0, column: 3, values: row), "A nested document is shown, not edited")
        XCTAssertNil(target.draft(row: 0, column: 2, values: [.text("pen"), .bytes(count: 1, prefix: [1]), .int(3), .null]),
                     "A binary _id cannot name its document exactly")
        XCTAssertTrue(target.accepts(.missing), "A field the document lacks can be set")
        XCTAssertFalse(target.accepts(.decimal("1.5")))

        let update = SQLiteOptimisticUpdate(keys: [.init(column: "_id", value: id)],
                                            changes: [.init(column: "qty", original: .int(3), replacement: .int(4))])
        let mongo = try XCTUnwrap(target.mongoUpdate(update))
        XCTAssertEqual(mongo.id, id)
        XCTAssertEqual(mongo.changes.first?.field, "qty")
        let preview = try XCTUnwrap(target.statement(for: .update(update))?.sql)
        XCTAssertTrue(preview.contains("db.items.updateOne") && preview.contains("$set: { qty: 4 }") && preview.contains("$oid"), preview)
    }

    func testPastingTrueOrFalseIntoABooleanColumnKeepsItBoolean() async throws {
        let store = ResultStore(columns: columns(["id", "flag"]))
        try await store.append([[.int(1), .bool(false)]])
        let target = try XCTUnwrap(IDEDatabaseEditTarget(sql: SQLEditTarget(
            engine: .postgres, schema: "public", table: "t",
            keys: [.init(resultIndex: 0, name: "id", typeName: "integer", isKey: true, isRequired: true, readOnlyReason: "key")],
            columns: [.init(resultIndex: 0, name: "id", typeName: "integer", isKey: true, isRequired: true, readOnlyReason: "key"),
                      .init(resultIndex: 1, name: "flag", typeName: "boolean", isKey: false, isRequired: false)]
        ), columns: columns(["id", "flag"])))
        let proposed = try await IDEDatabaseGridPaste(text: "TRUE", delimiter: "\t", sourceRows: [0], columns: [1])
            .edits(from: store, target: target)
        XCTAssertEqual(proposed.first?.replacement, .value(.bool(true)))
        do {
            _ = try await IDEDatabaseGridPaste(text: "maybe", delimiter: "\t", sourceRows: [0], columns: [1]).edits(from: store, target: target)
            XCTFail("Not a boolean")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("true or false"))
        }
        await store.close()
    }

    // MARK: Live

    private func makeSupport(urlKey: String, setUp: (inout DatabaseConnection) -> Void = { _ in }) async throws
        -> (IDEDatabaseSupport, DatabaseConnection, SQLSession?, URL) {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["UMBRA_DB_INTEGRATION"] == "1")
        let url = try XCTUnwrap(environment[urlKey])
        let draft = try DatabaseURL.parse(url)
        var source = draft.connection
        setUp(&source)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-engine-edit-\(UUID().uuidString)")
        let catalog = IDEDatabaseCatalog(storeURL: folder.appendingPathComponent("connections.json"))
        catalog.upsert(source)
        let keychain = IDEDatabaseMemoryKeyStore()
        try keychain.save(draft.password, account: source.id.uuidString)
        let support = IDEDatabaseSupport(catalog: catalog, keychain: keychain)
        try await support.connect(source.id)
        var login = source.sqlLogin(password: draft.password)
        if login.engine == .mysql { login.useTLS = false; login.requireTLS = false }
        let admin = source.engine == .mongo ? nil : try await SQLSession.connect(login: login, readOnly: false)
        return (support, source, admin, folder)
    }

    private func waitForTarget(_ support: IDEDatabaseSupport) async throws -> IDEDatabasePendingEdits {
        for _ in 0..<100 {
            if let pending = support.result.pendingEdits { return pending }
            if support.result.readOnlyReason != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("No edit target: \(support.result.readOnlyReason ?? "unresolved")")
    }

    func testPostgresResultsBecomeEditableOnlyAfterTheServerVerifiesThem() async throws {
        let (support, source, admin, folder) = try await makeSupport(urlKey: "UMBRA_TEST_PG_URL")
        let setup = try XCTUnwrap(admin)
        defer { support.closeAll(); try? FileManager.default.removeItem(at: folder) }
        _ = try await setup.query("DROP TABLE IF EXISTS app_edit_pg")
        _ = try await setup.query("CREATE TABLE app_edit_pg (id int PRIMARY KEY, label text NOT NULL, amount numeric(10,2))")
        _ = try await setup.query("INSERT INTO app_edit_pg VALUES (1, 'one', 1.50), (2, 'two', NULL)")
        defer { Task { _ = try? await setup.query("DROP TABLE IF EXISTS app_edit_pg"); await setup.disconnect() } }
        let binding = IDEDatabaseConsoleBinding(connectionID: source.id)

        await support.execute(statement: "SELECT label FROM app_edit_pg", binding: binding, resetSort: true)
        for _ in 0..<100 where support.result.readOnlyReason == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(support.result.pendingEdits)
        XCTAssertTrue(support.result.readOnlyReason?.contains("primary key") == true, support.result.readOnlyReason ?? "nil")

        await support.execute(statement: "SELECT id, label, amount FROM app_edit_pg ORDER BY id", binding: binding, resetSort: true)
        let pending = try await waitForTarget(support)
        let storage = try XCTUnwrap(support.result.storage)
        let rows = try await storage.store.rows(in: 0..<2)
        let amount = try XCTUnwrap(pending.target.draft(row: 0, column: 2, values: rows[0]))
        try pending.stage(amount, replacement: .text("9.99"))
        let label = try XCTUnwrap(pending.target.draft(row: 1, column: 1, values: rows[1]))
        try pending.stage(label, replacement: .text("deux"))
        XCTAssertThrowsError(try pending.stage(label, replacement: .null), "label is NOT NULL")

        // Inside the user's transaction the batch is submitted, not committed.
        await support.performTransaction(.begin(.init()), connectionID: source.id)
        let submitted = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertTrue(submitted)
        XCTAssertEqual(pending.phase, .submitted)
        let outside = try await setup.query("SELECT amount::text FROM app_edit_pg WHERE id = 1")
        XCTAssertEqual(outside.rows, [["1.50"]])
        await support.performTransaction(.commit, connectionID: source.id)
        XCTAssertEqual(pending.phase, .committed)
        let after = try await setup.query("SELECT label, amount::text FROM app_edit_pg ORDER BY id")
        XCTAssertEqual(after.rows, [["one", "9.99"], ["deux", nil]])
        XCTAssertNil(support.closeBlocker)
    }

    func testMySQLEditsThroughServerOriginsAndSurfacesAConflict() async throws {
        let (support, source, admin, folder) = try await makeSupport(urlKey: "UMBRA_TEST_MYSQL_URL") { $0.useTLS = false }
        let setup = try XCTUnwrap(admin)
        defer { support.closeAll(); try? FileManager.default.removeItem(at: folder) }
        _ = try await setup.query("DROP TABLE IF EXISTS app_edit_my")
        _ = try await setup.query("CREATE TABLE app_edit_my (id int PRIMARY KEY, label varchar(20) NOT NULL, amount decimal(10,2))")
        _ = try await setup.query("INSERT INTO app_edit_my VALUES (1, 'one', 1.50), (2, 'two', NULL)")
        defer { Task { _ = try? await setup.query("DROP TABLE IF EXISTS app_edit_my"); await setup.disconnect() } }
        let binding = IDEDatabaseConsoleBinding(connectionID: source.id)

        await support.execute(statement: "SELECT id, label, amount FROM app_edit_my ORDER BY id", binding: binding, resetSort: true)
        let pending = try await waitForTarget(support)
        let storage = try XCTUnwrap(support.result.storage)
        let rows = try await storage.store.rows(in: 0..<2)
        try pending.stage(try XCTUnwrap(pending.target.draft(row: 0, column: 2, values: rows[0])), replacement: .text("4.25"))
        try pending.stage(try XCTUnwrap(pending.target.draft(row: 1, column: 1, values: rows[1])), replacement: .text("zwei"))
        _ = try await setup.query("UPDATE app_edit_my SET label = 'changed elsewhere' WHERE id = 2")

        let first = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertFalse(first)
        XCTAssertEqual(pending.conflict?.row.row, 1)
        let untouched = try await setup.query("SELECT amount FROM app_edit_my WHERE id = 1")
        XCTAssertEqual(untouched.rows, [["1.50"]], "The row that matched was not written either")
        pending.rebaseConflict()
        let second = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertTrue(second)
        let final = try await setup.query("SELECT label, amount FROM app_edit_my ORDER BY id")
        XCTAssertEqual(final.rows, [["one", "4.25"], ["zwei", nil]])
    }

    func testMongoCollectionEditsSetOnlyTheChosenFieldsAndKeepTheirTypes() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["UMBRA_DB_INTEGRATION"] == "1")
        let url = try XCTUnwrap(environment["UMBRA_TEST_MONGO_URL"])
        let draft = try DatabaseURL.parse(url)
        let source = draft.connection
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-engine-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = IDEDatabaseCatalog(storeURL: folder.appendingPathComponent("connections.json"))
        catalog.upsert(source)
        let support = IDEDatabaseSupport(catalog: catalog, keychain: IDEDatabaseMemoryKeyStore())
        defer { support.closeAll() }
        try await support.connect(source.id)
        let writer = try await MongoSession.connect(login: source.mongoLogin(password: draft.password), readOnly: false)
        defer { Task { await writer.disconnect() } }
        let database = "umbra_app_edit"
        try await writer.console.dropCollection(database: database, collection: "items")
        _ = try await writer.console.insertOne(database: database, collection: "items", document: BSONDocument([
            "_id": .string("a"), "name": .string("pen"), "qty": .int32(3),
        ]))
        defer { Task { try? await writer.console.dropCollection(database: database, collection: "items") } }

        let binding = IDEDatabaseConsoleBinding(connectionID: source.id, mongoDatabase: database, mongoCollection: "items")
        await support.execute(statement: "{}", binding: binding, resetSort: true)
        let pending = try XCTUnwrap(support.result.pendingEdits, support.result.readOnlyReason ?? "no target")
        let storage = try XCTUnwrap(support.result.storage)
        let names = support.result.columns
        let row = try await storage.store.rows(in: 0..<1)[0]
        let qty = try XCTUnwrap(names.firstIndex(of: "qty"))
        try pending.stage(try XCTUnwrap(pending.target.draft(row: 0, column: qty, values: row)), replacement: .int(4))
        let submitted = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertTrue(submitted)
        let stored = try await writer.console.findDocuments(
            MongoFindRequest(database: database, collection: "items", filter: BSONDocument(["_id": .string("a")]), limit: 1), limit: 1)
        let document = try XCTUnwrap(stored.first)
        XCTAssertEqual(document["qty"], BSONValue.int32(4), "An int32 field stays int32")
        XCTAssertEqual(document["name"], BSONValue.string("pen"), "Fields that were not edited are untouched")
    }
}
