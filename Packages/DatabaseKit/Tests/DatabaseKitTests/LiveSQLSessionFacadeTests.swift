import Foundation
import Testing

@testable import DatabaseKit

private let liveEnabled = ProcessInfo.processInfo.environment["UMBRA_DB_INTEGRATION"] == "1"
    && ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != "true"  // never on the CI pipeline

/// `SQLSession` is the facade the app still calls. These tests drive it the way the app does, to
/// prove the move to single-connection sessions did not change what the explorer and console see.
@Suite(.enabled(if: liveEnabled, "needs UMBRA_DB_INTEGRATION=1 and Scripts/db-test-env.sh up"), .serialized)
struct LiveSQLSessionFacadeTests {
    @Test func explicitPostgresSchemaUsesTheSameScopeForQueriesAndMetadata() async throws {
        let writer = try await connect(readOnly: false)
        let name = "phase4_\(UUID().uuidString.prefix(8))'\\ scope"
        let quoted = try SQLIdentifiers.quote(name, engine: .postgres)
        defer {
            Task {
                _ = try? await writer.query("DROP SCHEMA IF EXISTS \(quoted) CASCADE")
                await writer.disconnect()
            }
        }
        _ = try await writer.query("CREATE SCHEMA \(quoted)")
        _ = try await writer.query("CREATE TABLE \(quoted).scope_item (id int PRIMARY KEY)")
        _ = try await writer.query("INSERT INTO \(quoted).scope_item VALUES (17)")
        #expect(try await writer.schemaNames().contains(name))
        let url = try #require(ProcessInfo.processInfo.environment["UMBRA_TEST_PG_URL"])
        var login = try SQLURLs.parse(url)
        #expect(try await writer.databaseNames().contains(login.handshakeDatabase))
        login.postgresSchema = name
        let scoped = try await SQLSession.connect(login: login, readOnly: true)
        defer { Task { await scoped.disconnect() } }
        #expect(try await scoped.query("SELECT id FROM scope_item").rows == [["17"]])
        let catalog = try await scoped.sqlCatalog()
        #expect(catalog.defaultSchema == name)
        #expect(catalog.relations.map(\.name) == ["scope_item"])
        #expect(catalog.relation(named: "scope_item")?.columns?.first?.isPrimaryKey == true)
    }

    private func connect(readOnly: Bool) async throws -> SQLSession {
        guard let url = ProcessInfo.processInfo.environment["UMBRA_TEST_PG_URL"] else {
            throw DatabaseError.executionFailed("UMBRA_TEST_PG_URL is not set; run Scripts/db-test-env.sh env")
        }
        return try await SQLSession.connect(login: SQLURLs.parse(url), readOnly: readOnly)
    }

    @Test func theExplorerCanReadMetadataWhileAConsoleQueryRuns() async throws {
        let writer = try await connect(readOnly: false)
        defer { Task { await writer.disconnect() } }
        _ = try await writer.query("DROP TABLE IF EXISTS facade_child; DROP TABLE IF EXISTS facade_parent".components(separatedBy: ";")[0])
        _ = try await writer.query("DROP TABLE IF EXISTS facade_parent")
        _ = try await writer.query("CREATE TABLE facade_parent (id int, name text, PRIMARY KEY (id, name))")
        _ = try await writer.query("""
            CREATE TABLE facade_child (
                id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                parent_id int, parent_name text,
                computed int GENERATED ALWAYS AS (parent_id + 1) STORED,
                CONSTRAINT facade_parent_fk FOREIGN KEY (parent_id, parent_name) REFERENCES facade_parent (id, name)
            )
            """)
        defer { Task { _ = try? await writer.query("DROP TABLE IF EXISTS facade_child"); _ = try? await writer.query("DROP TABLE IF EXISTS facade_parent") } }

        async let slow = writer.query("SELECT pg_sleep(1.5), 1 AS done")
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        let tables = try await writer.tables()
        let columns = try await writer.allColumns()
        let keys = try await writer.foreignKeys()
        let metadataTime = ContinuousClock.now - started
        #expect(tables.contains("facade_parent") && tables.contains("facade_child"))
        #expect(columns["facade_parent"]?.map(\.name) == ["id", "name"])
        #expect(columns["facade_parent"]?.first?.isPrimaryKey == true)
        #expect(keys.filter { $0.constraint == "facade_parent_fk" } == [
            SQLForeignKey(fromTable: "facade_child", fromColumn: "parent_id", toTable: "facade_parent", toColumn: "id",
                          constraint: "facade_parent_fk", ordinal: 1),
            SQLForeignKey(fromTable: "facade_child", fromColumn: "parent_name", toTable: "facade_parent", toColumn: "name",
                          constraint: "facade_parent_fk", ordinal: 2),
        ])
        #expect(metadataTime < .seconds(1.2), "metadata waited behind the running query (\(metadataTime))")
        let result = try await slow
        #expect(result.rows == [["", "1"]])
        let catalog = try await writer.sqlCatalog()
        #expect(catalog.isComplete)
        #expect(catalog.relation(named: "facade_child")?.columns?.first?.isIdentityAlways == true)
        #expect(catalog.relation(named: "facade_child")?.columns?.last?.isGenerated == true)
        #expect(catalog.foreignKeys.contains(SQLCatalog.ForeignKey(
            name: "facade_parent_fk", fromRelation: "facade_child", fromColumns: ["parent_id", "parent_name"],
            toRelation: "facade_parent", toColumns: ["id", "name"]
        )))
    }

    @Test func concurrentMetadataCallsAreQueuedNotRejected() async throws {
        let session = try await connect(readOnly: true)
        defer { Task { await session.disconnect() } }
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { try await session.tables().count }
                group.addTask { try await session.allColumns().count }
            }
            for try await _ in group {}
        }
    }

    @Test func postgresParametersAreBoundWithTypes() async throws {
        let session = try await connect(readOnly: true)
        defer { Task { await session.disconnect() } }
        let text = "O'Reilly; --"
        let result = try await session.query(
            "SELECT $1 AS text, $2 AS n, $3::text AS absent",
            parameters: [.text(text), .int(Int64.max), .null]
        )
        #expect(result.rows == [[text, String(Int64.max), nil]])
    }

    @Test func postgresErrorPositionSurvivesPaginationAndParameterRewriting() async throws {
        let session = try await connect(readOnly: true)
        defer { Task { await session.disconnect() } }
        let source = "SELECT 'e\u{301}😀', :long_parameter, missing_column"
        let plan = SQLParameterPlan(source, dialect: .postgres)
        do {
            _ = try await DatabaseQuery.run(statement: plan.sql, readOnly: true, page: 0, pageSize: 1,
                                            engine: .postgres, using: session, parameters: [.int(1)])
            Issue.record("Expected the server to report an unknown column")
        } catch let error as DatabaseServerError {
            let position = try #require(error.position)
            #expect(plan.sourceRange(at: position)?.location == (source as NSString).range(of: "missing_column").location)
        }
    }

    @Test func consoleResultsKeepTypesNullsAndAffectedRows() async throws {
        let session = try await connect(readOnly: false)
        defer { Task { await session.disconnect() } }
        _ = try await session.query("DROP TABLE IF EXISTS facade_rows")
        _ = try await session.query("CREATE TABLE facade_rows (id int, label text, score numeric(6,2), at timestamptz)")
        defer { Task { _ = try? await session.query("DROP TABLE IF EXISTS facade_rows") } }
        let insert = try await session.query(
            "INSERT INTO facade_rows VALUES (1,'a',1.50,'2024-03-05 10:20:30+00'), (2,'',NULL,NULL)"
        )
        #expect(insert.rowsAffected == 2)
        #expect(insert.columns.isEmpty)
        let select = try await session.query("SELECT * FROM facade_rows ORDER BY id")
        #expect(select.columns == ["id", "label", "score", "at"])
        #expect(select.rows == [["1", "a", "1.50", "2024-03-05 10:20:30+00"], ["2", "", nil, nil]])
        let none = try await session.query("SELECT * FROM facade_rows WHERE false")
        #expect(none.columns == ["id", "label", "score", "at"], "an empty result keeps its headers")
        #expect(none.rows.isEmpty)
    }

    @Test func readOnlyFacadeRefusesWritesAtTheServer() async throws {
        let writer = try await connect(readOnly: false)
        let reader = try await connect(readOnly: true)
        defer { Task { await writer.disconnect(); await reader.disconnect() } }
        _ = try await writer.query("DROP TABLE IF EXISTS facade_ro")
        _ = try await writer.query("CREATE TABLE facade_ro (id int)")
        _ = try await writer.query("INSERT INTO facade_ro VALUES (1),(2)")
        defer { Task { _ = try? await writer.query("DROP TABLE IF EXISTS facade_ro") } }
        // The audit's bypass: starts with WITH, deletes rows. The keyword scan now refuses it
        // early; and the server would refuse it regardless.
        await #expect(throws: DatabaseError.self) {
            _ = try await reader.query("WITH gone AS (DELETE FROM facade_ro RETURNING *) SELECT * FROM gone")
        }
        #expect(try await writer.query("SELECT count(*) FROM facade_ro").rows == [["2"]])
    }

    @Test func cancelStopsTheConsoleStatement() async throws {
        let session = try await connect(readOnly: true)
        defer { Task { await session.disconnect() } }
        let task = Task { try await session.query("SELECT pg_sleep(30)") }
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        await session.cancelRunning()
        _ = try await task.value
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(try await session.query("SELECT 1").rows == [["1"]])
    }
}

@Suite(.enabled(if: liveEnabled, "needs UMBRA_DB_INTEGRATION=1 and Scripts/db-test-env.sh up"), .serialized)
struct LiveMySQLFacadeTests {
    private func connect(readOnly: Bool) async throws -> SQLSession {
        guard let url = ProcessInfo.processInfo.environment["UMBRA_TEST_MYSQL_URL"] else {
            throw DatabaseError.executionFailed("UMBRA_TEST_MYSQL_URL is not set; run Scripts/db-test-env.sh env")
        }
        var login = try SQLURLs.parse(url)
        login.useTLS = false  // the container's certificate is self-signed
        return try await SQLSession.connect(login: login, readOnly: readOnly)
    }

    @Test func mysqlParametersKeepBinaryProtocolTypes() async throws {
        let session = try await connect(readOnly: true)
        defer { Task { await session.disconnect() } }
        let text = "O'Reilly; --"
        let result = try await session.query(
            """
            SELECT ? AS text_value, CAST(? AS SIGNED) AS n, ? AS absent,
                CAST('2024-03-05 10:20:30.123456' AS DATETIME(6)) AS timestamp_value
            """,
            parameters: [.text(text), .int(Int64.min), .null]
        )
        #expect(result.rows == [[text, String(Int64.min), nil, "2024-03-05 10:20:30.123456"]])
    }

    @Test func mysqlQueryResultsCarryCurrentStatementWarnings() async throws {
        let session = try await connect(readOnly: true)
        defer { Task { await session.disconnect() } }
        let result = try await session.query("SELECT CAST('bad number' AS UNSIGNED) AS n")
        #expect(result.rows == [["0"]])
        #expect(result.notices.first?.code == "1292")
        #expect(result.notices.first?.level == "Warning")
        #expect(try await session.query("SELECT 1").notices.isEmpty)
    }

    @Test func mysqlWarningsKeepAffectedRowCountsAndEmptyHeaders() async throws {
        let session = try await connect(readOnly: false)
        defer { Task { await session.disconnect() } }
        _ = try await session.query("CREATE TEMPORARY TABLE phase4_warning (id INT PRIMARY KEY)")
        let write = try await session.query("INSERT IGNORE INTO phase4_warning VALUES (1), (1)")
        #expect(write.rowsAffected == 1)
        #expect(write.notices.map(\.code) == ["1062"])
        let bound = try await session.query("INSERT IGNORE INTO phase4_warning VALUES (?), (?)", parameters: [.int(2), .int(2)])
        #expect(bound.rowsAffected == 1)
        #expect(bound.notices.map(\.code) == ["1062"])
        #expect(try await session.query("INSERT INTO phase4_warning VALUES (3)").notices.isEmpty)
        #expect(try await session.query("SELECT ROW_COUNT()").rows == [["1"]])
        let empty = try await session.query("SELECT id FROM phase4_warning WHERE id < 0")
        #expect(empty.columns == ["id"])
        #expect(empty.rows.isEmpty)
        #expect(empty.notices.isEmpty)
        #expect(try await session.databaseNames().contains("information_schema"))
    }

    @Test func theExplorerReadsMetadataWhileAConsoleQueryRuns() async throws {
        let writer = try await connect(readOnly: false)
        defer { Task { await writer.disconnect() } }
        _ = try await writer.query("DROP TABLE IF EXISTS facade_child")
        _ = try await writer.query("DROP TABLE IF EXISTS facade_parent")
        _ = try await writer.query("CREATE TABLE facade_parent (id INT PRIMARY KEY, name VARCHAR(20) NOT NULL) ENGINE=InnoDB")
        _ = try await writer.query("CREATE TABLE facade_child (id INT PRIMARY KEY, parent_id INT, KEY ix_parent (parent_id), FOREIGN KEY (parent_id) REFERENCES facade_parent(id)) ENGINE=InnoDB")
        defer { Task { _ = try? await writer.query("DROP TABLE IF EXISTS facade_child"); _ = try? await writer.query("DROP TABLE IF EXISTS facade_parent") } }

        async let slow = writer.query("SELECT SLEEP(1.5) AS slept")
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        let tables = try await writer.tables()
        let columns = try await writer.allColumns()
        let keys = try await writer.foreignKeys()
        let indexes = try await writer.indexes(of: "facade_child")
        let ddl = try await writer.createTableStatement("facade_parent")
        let elapsed = ContinuousClock.now - started
        #expect(tables.contains("facade_parent") && tables.contains("facade_child"))
        #expect(columns["facade_parent"]?.map(\.name) == ["id", "name"])
        #expect(columns["facade_parent"]?.first?.isPrimaryKey == true)
        #expect(columns["facade_parent"]?.last?.declaredType == "varchar(20)", "column types are text, not binary")
        #expect(keys.contains(SQLForeignKey(
            fromTable: "facade_child", fromColumn: "parent_id", toTable: "facade_parent", toColumn: "id",
            constraint: "facade_child_ibfk_1", ordinal: 1
        )))
        #expect(indexes.contains { $0.name == "ix_parent" && $0.columns == ["parent_id"] })
        #expect(ddl.contains("CREATE TABLE `facade_parent`"))
        #expect(elapsed < .seconds(1.2), "metadata waited behind the running query (\(elapsed))")
        _ = try await slow
    }

    @Test func consoleResultsKeepNullsEmptyStringsAndAffectedRows() async throws {
        let session = try await connect(readOnly: false)
        defer { Task { await session.disconnect() } }
        _ = try await session.query("DROP TABLE IF EXISTS facade_rows")
        _ = try await session.query("CREATE TABLE facade_rows (id INT, label VARCHAR(10), score DECIMAL(6,2)) ENGINE=InnoDB")
        defer { Task { _ = try? await session.query("DROP TABLE IF EXISTS facade_rows") } }
        let insert = try await session.query("INSERT INTO facade_rows VALUES (1,'a',1.50), (2,'',NULL)")
        #expect(insert.rowsAffected == 2)
        let select = try await session.query("SELECT * FROM facade_rows ORDER BY id")
        #expect(select.rows == [["1", "a", "1.50"], ["2", "", nil]])
    }

    @Test func readOnlyRefusesWritesAtTheServerAndCancelWorks() async throws {
        let writer = try await connect(readOnly: false)
        let reader = try await connect(readOnly: true)
        defer { Task { await writer.disconnect(); await reader.disconnect() } }
        _ = try await writer.query("DROP TABLE IF EXISTS facade_ro")
        _ = try await writer.query("CREATE TABLE facade_ro (id INT) ENGINE=InnoDB")
        _ = try await writer.query("INSERT INTO facade_ro VALUES (1),(2)")
        defer { Task { _ = try? await writer.query("DROP TABLE IF EXISTS facade_ro") } }
        await #expect(throws: (any Error).self) { _ = try await reader.query("DELETE FROM facade_ro") }
        await #expect(throws: (any Error).self) { _ = try await reader.query("WITH c AS (SELECT 1) DELETE FROM facade_ro") }
        #expect(try await writer.query("SELECT COUNT(*) FROM facade_ro").rows == [["2"]])

        let task = Task { try await reader.query("SELECT SLEEP(30)") }
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        await reader.cancelRunning()
        _ = try await task.value
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
