import DatabaseKit
import XCTest

@testable import Umbra

/// The inspector's viewers and live reread, and following foreign keys with Back and Forward.
@MainActor
final class IDEDatabaseNavigationAndValueTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-navigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSupport() -> IDEDatabaseSupport {
        let catalog = IDEDatabaseCatalog(storeURL: directory.appendingPathComponent("database-connections.json"))
        return IDEDatabaseSupport(catalog: catalog, keychain: IDEDatabaseMemoryKeyStore())
    }

    private func makeDatabase(named name: String, _ statements: [String]) async throws -> String {
        let path = directory.appendingPathComponent(name).path
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(path), createIfMissing: true))
        let store = ResultStore(columns: [])
        for statement in statements { _ = try await session.execute(statement, into: store) }
        await store.close()
        await session.close()
        return path
    }

    // MARK: Viewers

    func testHexDumpImageSniffingAndXMLAreBoundedAndDecided() throws {
        let dump = IDEDatabaseValueFormats.hexDump(Array("Hello, Umbra!!\u{0}\u{1}".utf8), limit: 1_000)
        XCTAssertEqual(dump, "00000000  48 65 6C 6C 6F 2C 20 55 6D 62 72 61 21 21 00 01  |Hello, Umbra!!..|")
        XCTAssertEqual(IDEDatabaseValueFormats.hexDump(Array(0..<40), limit: 17).split(separator: "\n").count, 2, "Cut at the limit")

        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0, count: 8)
        XCTAssertEqual(IDEDatabaseValueFormats.imageType(png), "PNG")
        XCTAssertEqual(IDEDatabaseValueFormats.imageType([0xFF, 0xD8, 0xFF] + Array(repeating: 0, count: 12)), "JPEG")
        XCTAssertNil(IDEDatabaseValueFormats.imageType(Array("not an image at all".utf8)))
        XCTAssertEqual(IDEDatabaseValueFormats.available(for: .bytes(count: png.count, prefix: png)), [.image, .hex])
        XCTAssertEqual(IDEDatabaseValueFormats.available(for: .bytes(count: 100, prefix: png)), [.hex],
                       "A partial value is never previewed as an image")
        XCTAssertEqual(IDEDatabaseValueFormats.available(for: .bytes(count: 3, prefix: Array("abc".utf8))), [.hex, .text])
        XCTAssertEqual(IDEDatabaseValueFormats.available(for: .bytes(count: 2, prefix: [0xFF, 0xFE])), [.hex], "Not UTF-8")

        XCTAssertEqual(IDEDatabaseValueFormats.available(for: .text("plain")), [.text])
        XCTAssertEqual(IDEDatabaseValueFormats.available(for: .text(#"{"a":1}"#)), [.text, .json])
        XCTAssertEqual(IDEDatabaseValueFormats.available(for: .text("<a><b>1</b></a>")), [.text, .xml])
        XCTAssertEqual(IDEDatabaseValueFormats.available(for: .text("{not json")), [.text])
        XCTAssertEqual(IDEDatabaseValueFormats.available(for: .text("<unclosed>")), [.text])
        XCTAssertTrue(try XCTUnwrap(IDEDatabaseValueFormats.prettyXML("<a><b>1</b></a>")).contains("\n"))
        // An entity pointing at a file is never loaded.
        let xxe = #"<?xml version="1.0"?><!DOCTYPE d [<!ENTITY x SYSTEM "file:///etc/hosts">]><d>&x;</d>"#
        XCTAssertFalse(IDEDatabaseValueFormats.prettyXML(xxe)?.contains("localhost") ?? false)

        let large = DatabaseValue.text(String(repeating: "x", count: 200_000))
        let rendered = IDEDatabaseValueFormats.render(large, as: .text)
        XCTAssertLessThan(rendered.text.utf8.count, 70_000)
        XCTAssertEqual(IDEDatabaseValueFormats.copyText(large, as: .text).utf8.count, 200_000, "Copy is the whole value")
    }

    func testALiveReadIsLabelledAndComparedOnlyWhenTheStoredValueWasWhole() {
        let column = ResultColumn(name: "body")
        let stored = IDEDatabaseInspectedValue(row: 3, column: column, cell: .truncated(preview: "abc", fullCount: 10_000))
        XCTAssertTrue(stored.isPartial)
        XCTAssertFalse(stored.isLive)
        let live = IDEDatabaseInspectedValue(live: .text(String(repeating: "a", count: 10_000)), replacing: stored, at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(live.isLive)
        XCTAssertFalse(live.isPartial)
        XCTAssertFalse(live.changedSinceQuery, "A preview cannot be compared with the text it was cut from")
        XCTAssertEqual(live.storedCell, .truncated(preview: "abc", fullCount: 10_000))

        let whole = IDEDatabaseInspectedValue(row: 0, column: column, cell: .text("before"))
        XCTAssertFalse(whole.isPartial)
        XCTAssertTrue(IDEDatabaseInspectedValue(live: .text("after"), replacing: whole).changedSinceQuery)
        XCTAssertFalse(IDEDatabaseInspectedValue(live: .text("before"), replacing: whole).changedSinceQuery)
        let bytes = IDEDatabaseInspectedValue(row: 0, column: column, cell: .bytes(count: 500, prefix: [1, 2]))
        XCTAssertTrue(bytes.isPartial)
    }

    // MARK: History and queries

    func testHistoryIsABrowserStackThatDropsTheFutureOnANewHop() {
        func entry(_ title: String) -> IDEDatabaseNavigationEntry {
            .init(title: title, statement: IDEDatabaseStatement("SELECT '\(title)'"),
                  binding: .init(connectionID: UUID()), scopeRevision: nil)
        }
        var history = IDEDatabaseNavigationHistory(origin: entry("origin"))
        XCTAssertFalse(history.canGoBack || history.canGoForward)
        history.visit(entry("a"))
        history.visit(entry("b"))
        XCTAssertEqual(history.current?.title, "b")
        XCTAssertEqual(history.backTitle, "a")
        XCTAssertEqual(history.move(by: -1)?.title, "a")
        XCTAssertEqual(history.move(by: -1)?.title, "origin")
        XCTAssertNil(history.move(by: -1), "Nothing before the origin")
        XCTAssertEqual(history.forwardTitle, "a")
        XCTAssertEqual(history.move(by: 1)?.title, "a")
        history.visit(entry("c"))
        XCTAssertFalse(history.canGoForward, "A new hop discards b")
        XCTAssertEqual(history.entries.map(\.title), ["origin", "a", "c"])
        for number in 0..<80 { history.visit(entry("n\(number)")) }
        XCTAssertEqual(history.entries.count, IDEDatabaseNavigationHistory.limit)
        XCTAssertEqual(history.current?.title, "n79")
    }

    func testServerForeignKeyQueriesBindEveryValueAndSkipUnbindableTypes() throws {
        let key = SQLCatalog.ForeignKey(name: "fk", fromRelation: "child", fromColumns: ["parent_id", "region"],
                                        toRelation: "parent", toColumns: ["id", "region"])
        let types = ["parent": ["id": "uuid", "region": "text"], "child": ["parent_id": "uuid", "region": "text"]]
        let binding = IDEDatabaseConsoleBinding(connectionID: UUID())
        let uuid = "11111111-2222-3333-4444-555555555555"
        let outbound = try IDEDatabaseResultQuery.make(
            engine: .postgres, schema: "public", table: "child", column: "parent_id",
            values: ["parent_id": .uuid(uuid), "region": .text("eu")], keys: [key],
            typeOf: { types[$0]?[$1] }, binding: binding, scopeRevision: nil)
        XCTAssertEqual(outbound.count, 1)
        XCTAssertEqual(outbound[0].sql, "SELECT * FROM \"public\".\"parent\"\nWHERE \"id\" = $1::uuid AND \"region\" = $2::text")
        XCTAssertEqual(outbound[0].parameters, [.text(uuid), .text("eu")], "A uuid is bound as text and cast")
        XCTAssertFalse(outbound[0].sql.contains(uuid), "Values are never interpolated")

        let inbound = try IDEDatabaseResultQuery.make(
            engine: .mysql, schema: "shop", table: "parent", column: "id",
            values: ["id": .int(7), "region": .text("eu")], keys: [key],
            typeOf: { _, _ in "int" }, binding: binding, scopeRevision: nil)
        XCTAssertEqual(inbound.map(\.sql), ["SELECT * FROM `shop`.`child`\nWHERE `parent_id` = ? AND `region` = ?"])
        XCTAssertEqual(inbound[0].parameters, [.int(7), .text("eu")])
        XCTAssertTrue(inbound[0].title.hasPrefix("Rows in child referencing this row"))

        // A column PostgreSQL cannot be told the type of is skipped, never guessed; so is a NULL part.
        XCTAssertTrue(try IDEDatabaseResultQuery.make(
            engine: .postgres, schema: "public", table: "child", column: "parent_id",
            values: ["parent_id": .uuid(uuid), "region": .text("eu")], keys: [key],
            typeOf: { _, column in column == "id" ? "USER-DEFINED" : "text" }, binding: binding, scopeRevision: nil).isEmpty)
        XCTAssertTrue(try IDEDatabaseResultQuery.make(
            engine: .postgres, schema: "public", table: "child", column: "parent_id",
            values: ["parent_id": .null, "region": .text("eu")], keys: [key],
            typeOf: { types[$0]?[$1] }, binding: binding, scopeRevision: nil).isEmpty)
    }

    func testNavigatedTablesAreReadFromGeneratedSQLOnly() {
        XCTAssertEqual(IDEDatabaseResultQuery.navigatedTable(in: #"SELECT parent.* FROM main."p" AS parent WHERE parent."id" = ?"#), "p")
        XCTAssertEqual(IDEDatabaseResultQuery.navigatedTable(in: #"SELECT child.* FROM main."odd ""name""" AS child WHERE EXISTS (SELECT 1)"#),
                       #"odd "name""#)
        XCTAssertNil(IDEDatabaseResultQuery.navigatedTable(in: #"SELECT parent.* FROM main."p" JOIN x"#))
        XCTAssertNil(IDEDatabaseResultQuery.navigatedTable(in: "SELECT * FROM items"))
    }

    // MARK: SQLite end to end

    func testFollowingForeignKeysInOneConsoleSupportsBackForwardAndStaysEditable() async throws {
        let path = try await makeDatabase(named: "nav.sqlite", [
            "CREATE TABLE parent (id INTEGER PRIMARY KEY, name TEXT)",
            "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id), note TEXT)",
            "INSERT INTO parent VALUES (1, 'alpha'), (2, 'beta')",
            "INSERT INTO child VALUES (10, 1, 'a1'), (11, 1, 'a2'), (12, 2, 'b1')",
        ])
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: path)
        let browse = IDEDatabaseConsoleBinding(connectionID: connection.id, sqliteBrowseTable: "child")
        await support.execute(statement: #"SELECT * FROM "main"."child""#, binding: browse, resetSort: true)
        XCTAssertNil(support.navigationHistory(for: nil))

        // child row 0 → its parent
        let outbound = try await support.relatedRows(in: support.result, row: 0, columnIndex: 1)
        let toParent = try XCTUnwrap(outbound.first { $0.title.hasPrefix("Referenced row in parent") })
        await support.followRelation(toParent, consoleID: nil)
        XCTAssertEqual(support.result.rows, [["1", "alpha"]])
        XCTAssertEqual(support.navigationHistory(for: nil)?.entries.count, 2)
        XCTAssertNotNil(support.result.pendingEdits, "A hop's result is a verified table, so it is editable")
        XCTAssertEqual(support.result.rowSource?.table, "parent")

        // parent row → the children that reference it
        let inbound = try await support.relatedRows(in: support.result, row: 0, columnIndex: 0)
        let toChildren = try XCTUnwrap(inbound.first { $0.title.hasPrefix("Rows in child referencing this row") })
        await support.followRelation(toChildren, consoleID: nil)
        XCTAssertEqual(support.result.rows, [["10", "1", "a1"], ["11", "1", "a2"]])
        XCTAssertEqual(support.navigationHistory(for: nil)?.index, 2)

        await support.navigateHistory(by: -1, consoleID: nil)
        XCTAssertEqual(support.result.rows, [["1", "alpha"]])
        await support.navigateHistory(by: -1, consoleID: nil)
        XCTAssertEqual(support.result.rows.count, 3, "Back to the original query")
        XCTAssertEqual(support.navigationHistory(for: nil)?.canGoBack, false)
        await support.navigateHistory(by: 1, consoleID: nil)
        XCTAssertEqual(support.result.rows, [["1", "alpha"]])

        // A fresh hop from the middle drops the forward entry; a statement the user runs ends it all.
        let again = try await support.relatedRows(in: support.result, row: 0, columnIndex: 0)
        await support.followRelation(try XCTUnwrap(again.first), consoleID: nil)
        XCTAssertEqual(support.navigationHistory(for: nil)?.entries.count, 3)
        await support.execute(statement: "SELECT 1", binding: browse, resetSort: true)
        XCTAssertNil(support.navigationHistory(for: nil))
        await support.disconnect(connection.id)
    }

    func testAHopFromATableWithoutAKeyStillCarriesItsRowID() async throws {
        let path = try await makeDatabase(named: "nokey.sqlite", [
            "CREATE TABLE parent (id INTEGER PRIMARY KEY, name TEXT)",
            "CREATE TABLE child (parent_id INTEGER REFERENCES parent(id), note TEXT)",
            "INSERT INTO parent VALUES (1, 'alpha')",
            "INSERT INTO child VALUES (1, 'x'), (1, 'y')",
        ])
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: path)
        let browse = IDEDatabaseConsoleBinding(connectionID: connection.id, sqliteBrowseTable: "parent")
        await support.execute(statement: #"SELECT * FROM "main"."parent""#, binding: browse, resetSort: true)
        let queries = try await support.relatedRows(in: support.result, row: 0, columnIndex: 0)
        await support.followRelation(try XCTUnwrap(queries.first), consoleID: nil)
        XCTAssertEqual(support.result.columns, ["rowid", "parent_id", "note"], "The key-less child table is edited by rowid")
        XCTAssertEqual(support.result.rows.count, 2, "The hop's WHERE survived the rowid projection")
        XCTAssertEqual(support.result.pendingEdits?.target.identity, .rowID)
        await support.disconnect(connection.id)
    }

    func testAFullValueIsReReadByKeyAndAReadOnlySourceCanStillDoIt() async throws {
        let path = try await makeDatabase(named: "big.sqlite", [
            "CREATE TABLE doc (id INTEGER PRIMARY KEY, body TEXT, data BLOB)",
            "INSERT INTO doc VALUES (1, '\(String(repeating: "x", count: 300_000))', zeroblob(100000))",
            "INSERT INTO doc VALUES (2, 'short', NULL)",
        ])
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: path, readOnly: true)
        let browse = IDEDatabaseConsoleBinding(connectionID: connection.id, sqliteBrowseTable: "doc")
        await support.execute(statement: #"SELECT * FROM "main"."doc""#, binding: browse, resetSort: true)
        XCTAssertNil(support.result.pendingEdits, "A read-only source is never editable")
        XCTAssertEqual(support.result.readOnlyReason, "This connection is read-only.")
        let source = try XCTUnwrap(support.result.rowSource, "...but its rows still have a verified identity")
        XCTAssertEqual(source.table, "doc")

        let storage = try XCTUnwrap(support.result.storage)
        let stored = try await storage.store.rows(in: 0..<1)[0]
        guard case .truncated(_, let count) = stored[1] else { return XCTFail("the grid keeps a preview, got \(stored[1])") }
        XCTAssertEqual(count, 300_000)
        guard case .bytes(let length, let prefix) = stored[2] else { return XCTFail("bytes expected") }
        XCTAssertEqual(length, 100_000)
        XCTAssertLessThan(prefix.count, length)

        let body = try await support.fetchFullValue(in: support.result, row: 0, column: 1)
        XCTAssertEqual(body, .text(String(repeating: "x", count: 300_000)))
        guard case .bytes(let fullLength, let fullPrefix) = try await support.fetchFullValue(in: support.result, row: 0, column: 2) else {
            return XCTFail("bytes expected")
        }
        XCTAssertEqual(fullLength, 100_000)
        XCTAssertEqual(fullPrefix.count, 100_000)
        let afterwards = try await storage.store.rows(in: 0..<1)[0]
        XCTAssertEqual(afterwards[1], stored[1], "The stored result is unchanged by the live read")

        // A result that is not tied to a table says so instead of guessing.
        await support.execute(statement: "SELECT body FROM doc", binding: browse, resetSort: true)
        do {
            _ = try await support.fetchFullValue(in: support.result, row: 0, column: 0)
            XCTFail("An arbitrary query has no verified key")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("verified table and key"))
        }
        await support.disconnect(connection.id)
    }

    func testReReadingAVanishedRowFailsInsteadOfShowingAnotherRow() async throws {
        let path = try await makeDatabase(named: "gone.sqlite", [
            "CREATE TABLE doc (id INTEGER PRIMARY KEY, body TEXT)",
            "INSERT INTO doc VALUES (1, '\(String(repeating: "y", count: 100_000))')",
        ])
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: path)
        let browse = IDEDatabaseConsoleBinding(connectionID: connection.id, sqliteBrowseTable: "doc")
        await support.execute(statement: #"SELECT * FROM "main"."doc""#, binding: browse, resetSort: true)
        let writer = try await SQLSession.connect(login: connection.sqlLogin(password: ""), readOnly: false)
        _ = try await writer.query("DELETE FROM doc")
        _ = try await writer.query("INSERT INTO doc VALUES (2, 'someone else')")
        do {
            _ = try await support.fetchFullValue(in: support.result, row: 0, column: 1)
            XCTFail("Row 1 is gone")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no longer there"), error.localizedDescription)
        }
        await writer.disconnect()
        await support.disconnect(connection.id)
    }

    // MARK: Live PostgreSQL

    func testPostgresFollowsAUUIDForeignKeyWithBoundCastValues() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["UMBRA_DB_INTEGRATION"] == "1")
        let url = try XCTUnwrap(environment["UMBRA_TEST_PG_URL"])
        let draft = try DatabaseURL.parse(url)
        let source = draft.connection
        let catalog = IDEDatabaseCatalog(storeURL: directory.appendingPathComponent("pg.json"))
        catalog.upsert(source)
        let keychain = IDEDatabaseMemoryKeyStore()
        try keychain.save(draft.password, account: source.id.uuidString)
        let support = IDEDatabaseSupport(catalog: catalog, keychain: keychain)
        defer { support.closeAll() }
        try await support.connect(source.id)
        let setup = try await SQLSession.connect(login: source.sqlLogin(password: draft.password), readOnly: false)
        defer { Task { await setup.disconnect() } }
        for statement in ["DROP TABLE IF EXISTS nav_child", "DROP TABLE IF EXISTS nav_parent",
                          "CREATE TABLE nav_parent (id uuid, region text, label text, PRIMARY KEY (id, region))",
                          "CREATE TABLE nav_child (id int PRIMARY KEY, parent_id uuid, region text, note text, FOREIGN KEY (parent_id, region) REFERENCES nav_parent (id, region))",
                          "INSERT INTO nav_parent VALUES ('11111111-2222-3333-4444-555555555555', 'eu', 'Europe'), ('11111111-2222-3333-4444-555555555555', 'us', 'America')",
                          "INSERT INTO nav_child VALUES (1, '11111111-2222-3333-4444-555555555555', 'us', 'c')"] {
            _ = try await setup.query(statement)
        }
        defer { Task { _ = try? await setup.query("DROP TABLE IF EXISTS nav_child"); _ = try? await setup.query("DROP TABLE IF EXISTS nav_parent") } }

        let binding = IDEDatabaseConsoleBinding(connectionID: source.id)
        await support.execute(statement: "SELECT id, parent_id, region, note FROM nav_child", binding: binding, resetSort: true)
        for _ in 0..<100 where support.result.rowSource == nil && support.result.readOnlyReason == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(support.result.rowSource?.table, "nav_child", support.result.readOnlyReason ?? "")
        let queries = try await support.relatedRows(in: support.result, row: 0, columnIndex: 1)
        let toParent = try XCTUnwrap(queries.first { $0.title.hasPrefix("Referenced row in nav_parent") })
        XCTAssertTrue(toParent.sql.contains("$1::uuid") && toParent.sql.contains("$2::text"), toParent.sql)
        await support.followRelation(toParent, consoleID: nil)
        XCTAssertEqual(support.result.rows, [["11111111-2222-3333-4444-555555555555", "us", "America"]],
                       "The composite key picked exactly one of the two parents")
        XCTAssertEqual(support.navigationHistory(for: nil)?.entries.count, 2)
        await support.navigateHistory(by: -1, consoleID: nil)
        XCTAssertEqual(support.result.rows, [["1", "11111111-2222-3333-4444-555555555555", "us", "c"]])
    }
}
