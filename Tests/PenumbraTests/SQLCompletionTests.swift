import DatabaseKit
import EditorIntelligence
import XCTest
@testable import Umbra

final class SQLCompletionSiteTests: XCTestCase {
    private func site(_ text: String, caret: Int? = nil) -> SQLCompletion.Site? {
        SQLCompletion.site(in: text, caretUTF16: caret ?? (text as NSString).length)
    }

    func testEmptyStatementOffersKeywords() {
        XCTAssertEqual(site(""), .keywords)
        XCTAssertEqual(site("   "), .keywords)
        XCTAssertEqual(site("SEL"), .keywords)
    }

    func testSelectOffersStatementColumns() {
        XCTAssertEqual(site("SELECT "), .columns(tables: []))
        XCTAssertEqual(site("select * from users where "), .columns(tables: ["users"]))
        XCTAssertEqual(site("SELECT * FROM users u WHERE id = 1 AND "), .columns(tables: ["users"]))
    }

    func testFromJoinUpdateIntoAndTableOfferTables() {
        XCTAssertEqual(site("SELECT * FROM "), .tables)
        XCTAssertEqual(site("SELECT * FROM users JOIN "), .tables)
        XCTAssertEqual(site("UPDATE "), .tables)
        XCTAssertEqual(site("INSERT INTO "), .tables)
        XCTAssertEqual(site("DELETE FROM "), .tables)
        XCTAssertEqual(site("select * from users ord"), .tables)
    }

    func testGroupOrderHavingAndOnOfferColumns() {
        XCTAssertEqual(site("SELECT a FROM t GROUP BY "), .columns(tables: ["t"]))
        XCTAssertEqual(site("SELECT a FROM t ORDER BY "), .columns(tables: ["t"]))
        XCTAssertEqual(site("SELECT a FROM t HAVING "), .columns(tables: ["t"]))
        XCTAssertEqual(site("SELECT * FROM a JOIN b ON "), .columns(tables: ["a", "b"]))
        XCTAssertEqual(site("UPDATE t SET "), .columns(tables: ["t"]))
    }

    func testMemberAccessResolvesAliases() {
        XCTAssertEqual(site("SELECT * FROM users u WHERE u."), .singleTableColumns(table: "users"))
        XCTAssertEqual(site("SELECT * FROM users AS u WHERE u."), .singleTableColumns(table: "users"))
        XCTAssertEqual(
            site("SELECT users. FROM users", caret: ("SELECT users." as NSString).length),
            .singleTableColumns(table: "users")
        )
        XCTAssertEqual(site("SELECT * FROM users u WHERE u.na"), .singleTableColumns(table: "users"))
    }

    func testCommentsAreSkipped() {
        XCTAssertEqual(site("-- pick a table\nSELECT "), .columns(tables: []))
        XCTAssertEqual(site("SELECT /* active */ * FROM "), .tables)
        XCTAssertEqual(site("SELECT 'it''s' FROM "), .tables)
    }

    func testInsideStringsAndCommentsReturnsNothing() {
        XCTAssertNil(site("SELECT 'abc"))
        XCTAssertNil(site("SELECT -- pick one"))
        XCTAssertNil(site("SELECT /* pick one"))
        XCTAssertNil(site("SELECT # pick one"))
    }

    func testStatementBoundaryStopsTheScan() {
        XCTAssertEqual(site("SELECT * FROM a; SELECT "), .columns(tables: []))
        XCTAssertEqual(site("SELECT * FROM a; DEL"), .keywords)
    }

    func testNumbersAreNotMemberAccess() {
        XCTAssertEqual(site("SELECT 1."), .columns(tables: []))
    }

    func testInsertColumnListOffersColumnsButValuesStepAside() {
        XCTAssertEqual(site("INSERT INTO users (na"), .columns(tables: ["users"]))
        XCTAssertNil(site("INSERT INTO users (name) VALUES (1,"))
    }
}

final class SQLStatementSplitTests: XCTestCase {
    func testStatementsSplitOnTopLevelSemicolons() {
        let statements = SQLCompletion.statements(in: "SELECT 1;\nSELECT *\nFROM users;\n")
        XCTAssertEqual(statements.map(\.startLine), [1, 2])
        XCTAssertEqual(statements[0].text, "SELECT 1")
        XCTAssertEqual(statements[1].text, "SELECT *\nFROM users")
        XCTAssertEqual(statements[1].endLine, 3)
    }

    func testSemicolonsInStringsDoNotSplit() {
        let statements = SQLCompletion.statements(in: "INSERT INTO t VALUES ('a;b');\nSELECT 1")
        XCTAssertEqual(statements.count, 2)
        XCTAssertEqual(statements[0].text, "INSERT INTO t VALUES ('a;b')")
    }

    func testBlankTextAndCommentsYieldNothingExtra() {
        XCTAssertTrue(SQLCompletion.statements(in: "").isEmpty)
        XCTAssertTrue(SQLCompletion.statements(in: "  \n-- just a comment\n").isEmpty)
        let statements = SQLCompletion.statements(in: "{}\n")
        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0].startLine, 1)
    }

    func testStatementAtLineFindsTheEnclosingStatement() {
        let text = "SELECT 1;\nSELECT *\nFROM users;\nDELETE FROM users"
        XCTAssertEqual(SQLCompletion.statement(atLine: 1, in: text), "SELECT 1")
        XCTAssertEqual(SQLCompletion.statement(atLine: 2, in: text), "SELECT *\nFROM users")
        XCTAssertEqual(SQLCompletion.statement(atLine: 3, in: text), "SELECT *\nFROM users")
        XCTAssertEqual(SQLCompletion.statement(atLine: 4, in: text), "DELETE FROM users")
        XCTAssertNil(SQLCompletion.statement(atLine: 5, in: text))
    }
}

final class SQLCompletionProviderTests: XCTestCase {
    private func snapshot(engine: DatabaseEngine = .postgres) -> SQLCompletionSnapshot {
        SQLCompletionSnapshot(
            engine: engine,
            tables: ["users", "orders"],
            columnsByTable: [
                "users": [
                    SQLColumn(name: "id", declaredType: "integer", isPrimaryKey: true, isNotNull: true),
                    SQLColumn(name: "name", declaredType: "text", isPrimaryKey: false, isNotNull: false),
                ],
                "orders": [
                    SQLColumn(name: "id", declaredType: "integer", isPrimaryKey: true, isNotNull: true),
                    SQLColumn(name: "user_id", declaredType: "integer", isPrimaryKey: false, isNotNull: false),
                ],
            ]
        )
    }

    private func provider(with snapshot: SQLCompletionSnapshot?, id: DocumentID) -> SQLCompletionProvider {
        let provider = SQLCompletionProvider()
        provider.setSnapshot(snapshot, for: id)
        return provider
    }

    func testSelectOffersColumnsAndFunctions() async {
        let id = DocumentID()
        let provider = provider(with: snapshot(), id: id)
        let context = makeSQLContext("SELECT ", documentID: id)
        XCTAssertTrue(provider.isPrimary(for: context))
        let items = await provider.provide(context: context)
        let labels = Set(items.map(\.label))
        XCTAssertTrue(labels.contains("id"))
        XCTAssertTrue(labels.contains("name"))
        XCTAssertTrue(labels.contains("user_id"))
        XCTAssertTrue(labels.contains("COUNT"))
        XCTAssertEqual(items.first { $0.label == "name" }?.detail, "text")
        XCTAssertEqual(items.first { $0.label == "id" }?.labelDetail, "PK")
    }

    func testFromOffersTablesButNoColumns() async {
        let id = DocumentID()
        let provider = provider(with: snapshot(), id: id)
        let context = makeSQLContext("SELECT * FROM ", documentID: id)
        XCTAssertTrue(provider.isPrimary(for: context))
        let items = await provider.provide(context: context)
        XCTAssertEqual(Set(items.map(\.label)), ["users", "orders"])
    }

    func testAliasDotOffersOneTablesColumns() async {
        let id = DocumentID()
        let provider = provider(with: snapshot(), id: id)
        let context = makeSQLContext("SELECT * FROM users u WHERE u.", documentID: id)
        XCTAssertTrue(provider.isPrimary(for: context))
        XCTAssertTrue(context.isMemberAccess)
        let items = await provider.provide(context: context)
        XCTAssertEqual(Set(items.map(\.label)), ["id", "name"])
    }

    func testPrefixFilteringThroughTheEngine() async throws {
        let id = DocumentID()
        let provider = provider(with: snapshot(), id: id)
        let engine = CompletionEngine(providers: [provider], debounceInterval: 0)
        let columns = try await engine.complete(context: makeSQLContext("SELECT na", documentID: id))
        XCTAssertTrue(columns.contains { $0.label == "name" })
        XCTAssertFalse(columns.contains { $0.label == "users" })
        let tables = try await engine.complete(context: makeSQLContext("SELECT * FROM ord", documentID: id))
        XCTAssertTrue(tables.contains { $0.label == "orders" })
        XCTAssertFalse(tables.contains { $0.label == "users" })
    }

    func testDocumentWithoutAConsoleReturnsNothing() async {
        let provider = SQLCompletionProvider()
        let context = makeSQLContext("SELECT ")
        XCTAssertFalse(provider.isPrimary(for: context))
        let items = await provider.provide(context: context)
        XCTAssertTrue(items.isEmpty)
    }

    func testOtherLanguagesAreNotClaimed() async {
        let id = DocumentID()
        let provider = provider(with: snapshot(), id: id)
        let context = makeSQLContext("{}", documentID: id, language: "json")
        XCTAssertFalse(provider.isPrimary(for: context))
        let items = await provider.provide(context: context)
        XCTAssertTrue(items.isEmpty)
    }

    func testInsideAStringReturnsNothing() async {
        let id = DocumentID()
        let provider = provider(with: snapshot(), id: id)
        let context = makeSQLContext("SELECT 'x", documentID: id)
        XCTAssertFalse(provider.isPrimary(for: context))
        let items = await provider.provide(context: context)
        XCTAssertTrue(items.isEmpty)
    }

    func testNamesThatNeedQuotingUseEngineQuoting() async {
        let quoted = SQLCompletionSnapshot(
            engine: .mysql,
            tables: ["my table"],
            columnsByTable: [
                "my table": [SQLColumn(name: "user-name", declaredType: "", isPrimaryKey: false, isNotNull: false)],
            ]
        )
        let id = DocumentID()
        let mysql = provider(with: quoted, id: id)
        let tables = await mysql.provide(context: makeSQLContext("SELECT * FROM ", documentID: id))
        XCTAssertEqual(tables.first { $0.label == "my table" }?.insertText, "`my table`")
        let columns = await mysql.provide(context: makeSQLContext("SELECT ", documentID: id))
        XCTAssertEqual(columns.first { $0.label == "user-name" }?.insertText, "`user-name`")

        let pgID = DocumentID()
        let pg = provider(
            with: SQLCompletionSnapshot(
                engine: .postgres, tables: ["my table"],
                columnsByTable: ["my table": []]
            ),
            id: pgID
        )
        let pgTables = await pg.provide(context: makeSQLContext("SELECT * FROM ", documentID: pgID))
        XCTAssertEqual(pgTables.first { $0.label == "my table" }?.insertText, "\"my table\"")
    }

    func testKeywordListsDependOnTheEngine() async {
        let pgID = DocumentID()
        let pg = provider(with: snapshot(engine: .postgres), id: pgID)
        let pgItems = await pg.provide(context: makeSQLContext("", documentID: pgID))
        XCTAssertEqual(
            Set(pgItems.map(\.label)),
            ["SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "EXPLAIN"]
        )
        XCTAssertEqual(pgItems.first { $0.label == "SELECT" }?.insertText, "SELECT ")

        let mysqlID = DocumentID()
        let mysql = provider(with: snapshot(engine: .mysql), id: mysqlID)
        let mysqlItems = await mysql.provide(context: makeSQLContext("", documentID: mysqlID))
        XCTAssertTrue(mysqlItems.contains { $0.label == "SHOW" })
    }
}

final class SQLSchemaMappingTests: XCTestCase {
    func testMySQLColumnsGroupByTable() {
        let page = QueryResult(
            columns: ["TABLE_NAME", "COLUMN_NAME", "COLUMN_TYPE", "IS_NULLABLE", "COLUMN_KEY"],
            rows: [
                ["users", "id", "int", "NO", "PRI"],
                ["users", "name", "varchar(32)", "YES", ""],
                ["orders", "id", "bigint", "NO", "PRI"],
            ],
            rowsAffected: nil,
            isReadQuery: true
        )
        let grouped = SQLSchemaMapping.mysqlColumns(page)
        XCTAssertEqual(grouped["users"]?.map(\.name), ["id", "name"])
        XCTAssertEqual(grouped["users"]?.first?.declaredType, "int")
        XCTAssertEqual(grouped["users"]?.first?.isPrimaryKey, true)
        XCTAssertEqual(grouped["users"]?.first?.isNotNull, true)
        XCTAssertEqual(grouped["users"]?.last?.isPrimaryKey, false)
        XCTAssertEqual(grouped["orders"]?.map(\.name), ["id"])
    }

    func testPostgresColumnsGroupByTableWithPrimaryKeys() {
        let columns = QueryResult(
            columns: ["table_name", "column_name", "data_type", "character_maximum_length",
                      "numeric_precision", "numeric_scale", "is_nullable", "column_default"],
            rows: [
                ["users", "id", "integer", nil, nil, nil, "NO", nil],
                ["users", "name", "character varying", "32", nil, nil, "YES", nil],
                ["users", "price", "numeric", nil, "10", "2", "YES", "0"],
                ["orders", "user_id", "integer", nil, nil, nil, "YES", nil],
            ],
            rowsAffected: nil,
            isReadQuery: true
        )
        let keys = SQLSchemaMapping.postgresPrimaryKeys(QueryResult(
            columns: ["table_name", "column_name"],
            rows: [["users", "id"]],
            rowsAffected: nil,
            isReadQuery: true
        ))
        let grouped = SQLSchemaMapping.postgresColumns(columns, primaryKeyColumns: keys)
        XCTAssertEqual(grouped["users"]?.first?.isPrimaryKey, true)
        XCTAssertEqual(grouped["users"]?[1].declaredType, "character varying(32)")
        XCTAssertEqual(grouped["users"]?[2].declaredType, "numeric(10,2)")
        XCTAssertEqual(grouped["users"]?[2].defaultValue, "0")
        XCTAssertEqual(grouped["orders"]?.first?.isPrimaryKey, false)
        XCTAssertEqual(grouped["orders"]?.first?.declaredType, "integer")
    }

    func testForeignKeysMapBothEngines() {
        let page = QueryResult(
            columns: ["table_name", "column_name", "ref_table", "ref_column"],
            rows: [
                ["orders", "user_id", "users", "id"],
                ["orders", "item_id", "items", "id"],
            ],
            rowsAffected: nil,
            isReadQuery: true
        )
        XCTAssertEqual(SQLSchemaMapping.foreignKeys(page), [
            SQLForeignKey(fromTable: "orders", fromColumn: "user_id", toTable: "users", toColumn: "id"),
            SQLForeignKey(fromTable: "orders", fromColumn: "item_id", toTable: "items", toColumn: "id"),
        ])
    }

    func testPostgresCreateTableComposesDDL() {
        let columns = [
            SQLColumn(name: "id", declaredType: "integer", isPrimaryKey: true, isNotNull: true),
            SQLColumn(name: "name", declaredType: "character varying(32)", isPrimaryKey: false, isNotNull: false),
            SQLColumn(name: "user_id", declaredType: "integer", isPrimaryKey: false, isNotNull: false),
        ]
        let keys = [SQLForeignKey(fromTable: "orders", fromColumn: "user_id", toTable: "users", toColumn: "id")]
        XCTAssertEqual(
            SQLSchemaMapping.postgresCreateTable(table: "orders", columns: columns, foreignKeys: keys),
            """
            CREATE TABLE "orders" (
              "id" integer NOT NULL,
              "name" character varying(32),
              "user_id" integer,
              PRIMARY KEY ("id"),
              FOREIGN KEY ("user_id") REFERENCES "users" ("id")
            );
            """
        )
    }

    func testInsertNameQuotesOnlyWhenNeeded() {
        XCTAssertEqual(SQLIdentifiers.insertName("users", engine: .postgres), "users")
        XCTAssertEqual(SQLIdentifiers.insertName("my table", engine: .mysql), "`my table`")
        XCTAssertEqual(SQLIdentifiers.insertName("user-name", engine: .postgres), "\"user-name\"")
        XCTAssertEqual(SQLIdentifiers.insertName("order", engine: .postgres), "\"order\"")
        XCTAssertFalse(SQLIdentifiers.needsQuoting("users"))
        XCTAssertTrue(SQLIdentifiers.needsQuoting("my table"))
    }
}

private func makeSQLContext(
    _ text: String, caret: Int? = nil, documentID: DocumentID? = nil, language: String = "sql"
) -> CompletionContext {
    let offset = caret ?? (text as NSString).length
    let position = TextPosition(line: 0, column: offset, utf16Offset: offset)
    let document = Document(
        id: documentID ?? DocumentID(),
        url: nil,
        displayName: "console.sql",
        contentSnapshot: TextSnapshot(version: 0, text: text),
        selection: Selection(range: TextRange(start: position, end: position)),
        cursor: Cursor(position: position),
        viewport: Viewport(x: 0, y: 0, width: 800, height: 600),
        languageIdentifier: language
    )
    return makeCompletionContext(document: document, trigger: .manual)
}
