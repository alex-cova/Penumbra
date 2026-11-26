import DatabaseKit
import XCTest
@testable import Umbra

@MainActor
final class IDEDatabaseGridCopyTests: XCTestCase {
    func testClipboardParserPreservesBlankAndQuotedRecordsAndRejectsRaggedInput() {
        XCTAssertEqual(IDECSVTable.clipboardRecords("first\n\n\"two\nlines\"\n", delimiter: "\t", cellLimit: 5),
                       [["first"], [""], ["two\nlines"]])
        XCTAssertEqual(IDECSVTable.clipboardRecords("\"x\tinside\"\ty\r\n\t\"z\"\"q\"", delimiter: "\t", cellLimit: 4),
                       [["x\tinside", "y"], ["", "z\"q"]])
        XCTAssertNil(IDECSVTable.clipboardRecords("a\tb\nc", delimiter: "\t", cellLimit: 5))
        XCTAssertNil(IDECSVTable.clipboardRecords("\"unfinished", delimiter: "\t", cellLimit: 5))
        XCTAssertNil(IDECSVTable.clipboardRecords("\"ended\"tail", delimiter: "\t", cellLimit: 5))
        XCTAssertNil(IDECSVTable.clipboardRecords("a\tb\tc", delimiter: "\t", cellLimit: 2))
    }

    func testGridFilterUsesOriginalRowIndicesAndDisplayPreviews() async throws {
        let store = ResultStore(columns: [.init(name: "name"), .init(name: "other")])
        try await store.append([[.text("Äpple"), .null], [.text("pear"), .text("apple")],
                                [.text("apple tree"), .text("")], [.null, .missing]])
        let matches = try await IDEDatabaseLoadedFilter(text: "apple", column: 0).apply(to: store)
        XCTAssertEqual(matches.indices, [0, 2])
        XCTAssertEqual(matches.loadedRows, 4)
        let all = try await IDEDatabaseLoadedFilter(text: "apple", column: nil).apply(to: store)
        XCTAssertEqual(all.indices, [0, 1, 2])
        let nulls = try await IDEDatabaseLoadedFilter(text: "NULL", column: 0).apply(to: store)
        XCTAssertEqual(nulls.indices, [3])
        let reordered = try await store.mapRows(at: [2, 0, 2]) { $0.first }
        XCTAssertEqual(reordered, [.text("apple tree"), .text("Äpple"), .text("apple tree")])
        await store.close()
    }

    func testServerFilterKeepsLivePostgresAndMySQLBindingsInOrder() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["UMBRA_DB_INTEGRATION"] == "1")
        for (key, sql) in [
            ("UMBRA_TEST_PG_URL", "SELECT $1::bigint AS number, 'label'::text AS name"),
            ("UMBRA_TEST_MYSQL_URL", "SELECT CAST(? AS SIGNED) AS number, 'label' AS name"),
        ] {
            let url = try XCTUnwrap(environment[key])
            let draft = try DatabaseURL.parse(url)
            var login = draft.connection.sqlLogin(password: draft.password)
            if login.engine == .mysql {
                login.useTLS = false
                login.requireTLS = false
            }
            let session = try await SQLSession.connect(login: login, readOnly: true)
            do {
                let source = IDEDatabaseServerFilter(statement: .init(sql, parameters: [.int(7)]),
                                                    columns: ["number", "name"], engine: login.engine,
                                                    connectionID: draft.connection.id, scopeRevision: nil)
                let query = try source.query(column: 0, comparison: .equals, value: .int(7))
                XCTAssertEqual(query.parameters, [.int(7), .int(7)])
                let rows = try await session.query(query.sql, parameters: query.parameters)
                XCTAssertEqual(rows.rows, [["7", "label"]])
                await session.disconnect()
            } catch {
                await session.disconnect()
                throw error
            }
        }
    }
    func testCopiesTheRequestedRectangleInDisplayColumnOrder() async throws {
        let store = ResultStore(columns: [.init(name: "a"), .init(name: "b")])
        try await store.append([[.text("ignored"), .int(0)], [.text("x\ty"), .int(-3)], [.text("a|b"), .text("=formula")]])
        let indices = IndexSet(integersIn: 1..<3)
        let tsv = try await IDEDatabaseGridCopy.tsv.text(from: store, rows: indices, columns: [1, 0], engine: .sqlite)
        XCTAssertEqual(tsv, "-3\t\"x\ty\"\r\n'=formula\ta|b")
        let markdown = try await IDEDatabaseGridCopy.markdown.text(from: store, rows: indices, columns: [1, 0], engine: .sqlite)
        XCTAssertEqual(markdown, "| b | a |\n| --- | --- |\n| -3 | x\ty |\n| =formula | a\\|b |")
        let sql = try await IDEDatabaseGridCopy.sql.text(from: store, rows: indices, columns: [1, 0], engine: .sqlite)
        XCTAssertEqual(sql, "SELECT -3 AS \"b\", 'x\ty' AS \"a\"\nUNION ALL SELECT '=formula', 'a|b'")
        await store.close()
    }
}
