import Foundation
import Testing

@testable import DatabaseKit

private let liveEnabled = ProcessInfo.processInfo.environment["UMBRA_DB_INTEGRATION"] == "1"
    && ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != "true"  // never on the CI pipeline

@Suite(.enabled(if: liveEnabled, "needs UMBRA_DB_INTEGRATION=1 and Scripts/db-test-env.sh up"), .serialized)
struct LiveMySQLSessionTests {
    private func login() throws -> SQLLogin {
        guard let url = ProcessInfo.processInfo.environment["UMBRA_TEST_MYSQL_URL"] else {
            throw DatabaseError.executionFailed("UMBRA_TEST_MYSQL_URL is not set; run Scripts/db-test-env.sh env")
        }
        var parsed = try SQLURLs.parse(url)
        // A MySQL URL parses as "use TLS"; the test container has a self-signed certificate, so
        // the plain-text tests switch it off and the TLS test turns it on explicitly.
        parsed.useTLS = false
        parsed.requireTLS = false
        return parsed
    }

    private func connect(readOnly: Bool = false) async throws -> MySQLSession {
        try await MySQLSession.connect(login: login(), readOnly: readOnly)
    }

    @discardableResult
    private func run(
        _ session: MySQLSession, _ sql: String, limit: Int? = nil, options: ExecuteOptions = .init()
    ) async throws -> (summary: ExecutionSummary, rows: [[String?]]) {
        let store = ResultStore(columns: [], rowLimit: limit)
        let summary = try await session.execute(sql, into: store, options: options)
        let rows = try await store.rows(in: 0..<min(await store.rowCount, 100_000)).map { $0.map(\.rawText) }
        await store.close()
        return (summary, rows)
    }

    private func count(_ session: MySQLSession, _ table: String) async throws -> Int {
        Int(try await run(session, "SELECT COUNT(*) FROM \(table)").rows[0][0] ?? "") ?? -1
    }

    @Test func consoleStreamPausesAndResumesReadsAcrossManyBatches() async throws {
        let session = try await connect(readOnly: true)
        defer { Task { await session.close() } }
        let query = """
        WITH RECURSIVE seed(n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM seed WHERE n < 99)
        SELECT a.n * 100 + b.n AS id, REPEAT('x', 400) AS data
        FROM seed AS a CROSS JOIN seed AS b ORDER BY id
        """
        let store = ResultStore(columns: [], memoryLimitBytes: 256_000)
        let result = try await session.execute(query, into: store)
        #expect(result.rowCount == 10_000)
        #expect(await store.stats.spillFileExists)
        #expect(try await store.row(at: 9_999).first == .int(9_999))
        #expect(try await store.row(at: 0).first == .int(0))
        await store.close()

        let limited = ResultStore(columns: [], rowLimit: 600)
        #expect(try await session.execute(query, into: limited).limitReached)
        #expect(await limited.rowCount == 600)
        await limited.close()
        #expect(try await run(session, "SELECT 42").rows == [["42"]])
    }

    // MARK: Values

    @Test func typedValuesArriveAsTheirTypes() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await run(session, "DROP TABLE IF EXISTS my_types")
        try await run(session, """
            CREATE TABLE my_types (
              i8 TINYINT, u64 BIGINT UNSIGNED, d DECIMAL(10,4), f FLOAT, dbl DOUBLE,
              dt DATETIME(3), dte DATE, tm TIME, j JSON, e ENUM('small','large'), s SET('a','b','c'),
              t TEXT, b BLOB, vb VARBINARY(8), bt BIT(5), n TEXT, blank VARCHAR(5), yr YEAR
            ) ENGINE=InnoDB
        """)
        defer { Task { _ = try? await self.run(session, "DROP TABLE IF EXISTS my_types") } }
        try await run(session, """
            INSERT INTO my_types VALUES (-128, 18446744073709551615, 12345.6789, 0.1, 1.5,
              '2024-03-05 10:20:30.123', '2024-03-05', '-838:59:59', '{"a": [1, 2]}', 'large', 'a,c',
              'héllo', 0xDEADBEEF, 0x0102, b'10101', NULL, '', 2024)
        """)
        let store = ResultStore(columns: [])
        _ = try await session.execute("SELECT * FROM my_types", into: store)
        let row = try await store.row(at: 0)
        let columns = await store.columns
        await store.close()
        func value(_ name: String) -> DatabaseValue { row[columns.firstIndex { $0.name == name }!] }
        #expect(value("i8") == .int(-128))
        #expect(value("u64") == .uint(UInt64.max))
        #expect(value("d") == .decimal("12345.6789"))
        #expect(value("f") == .double(0.1))
        #expect(value("dbl") == .double(1.5))
        #expect(value("dt") == .temporal("2024-03-05 10:20:30.123", .timestamp))
        #expect(value("dte") == .temporal("2024-03-05", .date))
        #expect(value("tm") == .temporal("-838:59:59", .time))
        #expect(value("j").presence == .value)
        if case .json(let text) = value("j") { #expect(text.contains("\"a\"")) } else { Issue.record("json column was \(value("j"))") }
        #expect(value("e") == .text("large"))
        #expect(value("s") == .text("a,c"))
        #expect(value("t") == .text("héllo"), "a TEXT column is text, decided by its charset")
        #expect(value("b") == .bytes(count: 4, prefix: [0xDE, 0xAD, 0xBE, 0xEF]), "a BLOB column is binary")
        #expect(value("vb") == .bytes(count: 2, prefix: [1, 2]))
        #expect(value("bt").presence == .binary)
        #expect(value("n") == .null)
        #expect(value("blank") == .text(""), "the empty string is not NULL")
        #expect(value("yr") == .int(2024))
        #expect(columns.first { $0.name == "u64" }?.typeName == "bigint unsigned")
        #expect(columns.first { $0.name == "t" }?.typeName == "text")
        #expect(columns.first { $0.name == "b" }?.typeName == "blob")
        #expect(columns.first { $0.name == "t" }?.origin == ResultColumn.Origin(schema: "umbra", table: "my_types", column: "t"))
    }

    // MARK: F-01

    @Test func statementsRunOnOneConnectionAndATransactionIsReal() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await run(session, "CREATE TEMPORARY TABLE my_pin (id INT) ENGINE=InnoDB")
        try await session.begin()
        try await run(session, "INSERT INTO my_pin VALUES (1), (2)")
        let ids = try await (0..<5).asyncMap { _ in try await run(session, "SELECT CONNECTION_ID()").rows[0][0] }
        #expect(Set(ids).count == 1)
        #expect(ids.first! == String(session.connectionID))
        #expect(try await count(session, "my_pin") == 2)
        #expect(await session.transaction == .active(readOnly: false))
        try await session.rollback()
        #expect(try await count(session, "my_pin") == 0)
        try await session.begin(TransactionOptions(isolation: .serializable))
        try await run(session, "INSERT INTO my_pin VALUES (3)")
        // `SET TRANSACTION` applies to this transaction only, so the session variable still shows the
        // default; the transaction's own level is in INNODB_TRX.
        let level = try await run(
            session,
            "SELECT trx_isolation_level FROM information_schema.innodb_trx WHERE trx_mysql_thread_id = CONNECTION_ID()"
        )
        #expect(level.rows.first?[0] == "SERIALIZABLE")
        try await session.commit()
        #expect(try await count(session, "my_pin") == 1)
    }

    @Test func sessionSettingsStayWithTheSession() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await run(session, "SET @umbra_marker = 42")
        #expect(try await run(session, "SELECT @umbra_marker").rows[0][0] == "42", "user variables need one connection")
    }

    // MARK: F-03

    @Test func readOnlySessionsAreRefusedByTheServer() async throws {
        let writer = try await connect()
        let reader = try await connect(readOnly: true)
        defer { Task { await writer.close(); await reader.close() } }
        try await run(writer, "DROP TABLE IF EXISTS my_ro")
        try await run(writer, "DROP TABLE IF EXISTS my_ro_myisam")
        try await run(writer, "DROP PROCEDURE IF EXISTS my_ro_wipe")
        try await run(writer, "CREATE TABLE my_ro (id INT PRIMARY KEY, note VARCHAR(10)) ENGINE=InnoDB")
        try await run(writer, "CREATE TABLE my_ro_myisam (id INT) ENGINE=MyISAM")
        try await run(writer, "INSERT INTO my_ro VALUES (1,'a'),(2,'b'),(3,'c')")
        try await run(writer, "INSERT INTO my_ro_myisam VALUES (1),(2)")
        try await run(writer, "CREATE PROCEDURE my_ro_wipe() DELETE FROM my_ro")
        defer { Task { _ = try? await writer.close() } }

        let attacks = [
            "DELETE FROM my_ro", "UPDATE my_ro SET note = 'x'", "INSERT INTO my_ro VALUES (9,'z')",
            "WITH c AS (SELECT 1) DELETE FROM my_ro", "TRUNCATE TABLE my_ro", "CALL my_ro_wipe()",
            "CREATE TABLE my_ro_new (id INT)", "DROP TABLE my_ro_myisam", "DELETE FROM my_ro_myisam",
            "REPLACE INTO my_ro VALUES (1,'q')", "SET TRANSACTION READ WRITE", "ALTER TABLE my_ro ADD COLUMN x INT",
        ]
        for attack in attacks {
            _ = try? await run(reader, attack)
            #expect(try await count(writer, "my_ro") == 3, "'\(attack)' changed my_ro")
            #expect(try await count(writer, "my_ro_myisam") == 2, "'\(attack)' changed my_ro_myisam")
        }
        await #expect(throws: DatabaseServerError.self) { try await self.run(reader, "DELETE FROM my_ro") }
        #expect(try await run(reader, "SELECT COUNT(*) FROM my_ro").rows[0][0] == "3")
        let tables = try await run(writer, "SHOW TABLES LIKE 'my_ro_new'")
        #expect(tables.rows.isEmpty, "CREATE TABLE must not have run")
        try await run(writer, "DROP PROCEDURE my_ro_wipe")
        try await run(writer, "DROP TABLE my_ro")
        try await run(writer, "DROP TABLE my_ro_myisam")
    }

    @Test func forceReadOnlyProtectsAWritableConnection() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await run(session, "DROP TABLE IF EXISTS my_force")
        try await run(session, "CREATE TABLE my_force (id INT) ENGINE=InnoDB")
        defer { Task { _ = try? await self.run(session, "DROP TABLE IF EXISTS my_force") } }
        await #expect(throws: DatabaseServerError.self) {
            try await self.run(session, "INSERT INTO my_force VALUES (1)", options: ExecuteOptions(forceReadOnly: true))
        }
        #expect(try await count(session, "my_force") == 0)
        try await run(session, "INSERT INTO my_force VALUES (1)")
        #expect(try await count(session, "my_force") == 1)
    }

    // MARK: F-07 / F-05

    @Test func cancellingARunningStatementReturnsPromptly() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        async let outcome = run(session, "SELECT SLEEP(30)")
        try await Task.sleep(for: .milliseconds(300))
        let requested = ContinuousClock.now
        await session.cancelRunning()
        let result = try await outcome
        let afterCancel = ContinuousClock.now - requested
        print("MYCANCEL afterCancelRequest=\(afterCancel)")
        #expect(result.summary.wasCancelled)
        #expect(afterCancel < .seconds(2))
        #expect(try await run(session, "SELECT 1").rows[0][0] == "1")
    }

    @Test func aRowLimitStopsAHugeJoinEarly() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        let start = ContinuousClock.now
        let result = try await run(
            session,
            "SELECT a.column_name FROM information_schema.columns a CROSS JOIN information_schema.columns b",
            limit: 2_000
        )
        let elapsed = ContinuousClock.now - start
        print("MYLIMIT rows=\(result.rows.count) elapsed=\(elapsed)")
        #expect(result.summary.limitReached)
        #expect(result.rows.count == 2_000)
        #expect(elapsed < .seconds(10))
        #expect(try await run(session, "SELECT 1").rows[0][0] == "1", "the session survives the KILL")
    }

    // MARK: Results, errors, transactions

    @Test func affectedRowsAreReported() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await run(session, "CREATE TEMPORARY TABLE my_aff (id INT, v VARCHAR(5)) ENGINE=InnoDB")
        #expect(try await run(session, "INSERT INTO my_aff VALUES (1,'a'),(2,'b'),(3,'c')").summary.affectedRows == 3)
        #expect(try await run(session, "UPDATE my_aff SET v = 'z' WHERE id < 3").summary.affectedRows == 2)
        #expect(try await run(session, "UPDATE my_aff SET v = 'q' WHERE id = 99").summary.affectedRows == 0)
        #expect(try await run(session, "DELETE FROM my_aff WHERE id = 3").summary.affectedRows == 1)
        let select = try await run(session, "SELECT * FROM my_aff ORDER BY id")
        #expect(select.rows == [["1", "z"], ["2", "z"]])
        #expect(select.summary.affectedRows == nil)
    }

    @Test func ddlInsideATransactionIsReportedAsAnImplicitCommit() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await run(session, "DROP TABLE IF EXISTS my_implicit")
        try await run(session, "DROP TABLE IF EXISTS my_implicit_ddl")
        try await run(session, "CREATE TABLE my_implicit (id INT) ENGINE=InnoDB")
        defer { Task {
            _ = try? await self.run(session, "DROP TABLE IF EXISTS my_implicit")
            _ = try? await self.run(session, "DROP TABLE IF EXISTS my_implicit_ddl")
        } }
        try await session.begin()
        try await run(session, "INSERT INTO my_implicit VALUES (1)")
        let ddl = try await run(session, "CREATE TABLE my_implicit_ddl (id INT)")
        #expect(ddl.summary.implicitlyCommitted)
        #expect(await session.transaction == .none, "the transaction is over; MySQL committed it")
        try await run(session, "ROLLBACK")
        #expect(try await count(session, "my_implicit") == 1, "the insert was committed by the DDL and cannot be rolled back")
    }

    @Test func serverErrorsCarryASQLState() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await run(session, "CREATE TEMPORARY TABLE my_err (id INT PRIMARY KEY)")
        try await run(session, "INSERT INTO my_err VALUES (1)")
        do {
            try await run(session, "INSERT INTO my_err VALUES (1)")
            Issue.record("expected a duplicate key error")
        } catch let error as DatabaseServerError {
            #expect(error.code == "23000")
            #expect(error.message.contains("Duplicate"))
        }
        do {
            try await run(session, "SELEC 1")
            Issue.record("expected a syntax error")
        } catch let error as DatabaseServerError {
            #expect(error.code == "42000")
        }
        #expect(try await run(session, "SELECT 1").rows[0][0] == "1")
    }

    @Test func serverFactsAreDetected() async throws {
        let session = try await connect(readOnly: true)
        defer { Task { await session.close() } }
        let info = await session.serverInfo
        #expect(info.engine == .mysql)
        #expect(info.majorVersion == 8)
        #expect(!info.sqlMode.isEmpty)
        let capabilities = await session.capabilities
        #expect(capabilities.contains(.explainAnalyze))
        #expect(capabilities.contains(.ddlImplicitlyCommits))
        #expect(capabilities.contains(.serverEnforcedReadOnly))
        #expect(await session.currentDatabase == "umbra")
        await #expect(throws: DatabaseError.self) { try await session.begin() }
    }

    @Test func requireTLSIsStrict() async throws {
        var strict = try login()
        strict.useTLS = true
        strict.requireTLS = true
        // The container offers TLS with a self-signed certificate. Require means verified TLS, so
        // this must fail; a "TLS if possible" connect would have succeeded.
        do {
            let session = try await MySQLSession.connect(login: strict, readOnly: true)
            await session.close()
            Issue.record("connected with an unverifiable certificate although TLS was required")
        } catch {
            print("MYTLS error=\(error)")
        }
    }
}

extension Sequence {
    fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}

@Suite(.enabled(if: liveEnabled, "needs UMBRA_DB_INTEGRATION=1 and Scripts/db-test-env.sh up"), .serialized)
struct LiveMySQLMetadataTypeTests {
    /// The explorer reads these statements. The old code guessed text from blob-typed cells; the
    /// new decoder trusts the character set, so what MySQL really sends for them must be text.
    @Test func metadataStatementsDeliverTextNotBinary() async throws {
        guard let url = ProcessInfo.processInfo.environment["UMBRA_TEST_MYSQL_URL"] else { return }
        var login = try SQLURLs.parse(url)
        login.useTLS = false
        let session = try await MySQLSession.connect(login: login, readOnly: false)
        defer { Task { await session.close() } }
        for statement in [
            "DROP TABLE IF EXISTS my_meta", "CREATE TABLE my_meta (id INT PRIMARY KEY, name VARCHAR(20) NOT NULL, KEY ix (name))",
        ] {
            let store = ResultStore(columns: [])
            _ = try await session.execute(statement, into: store)
            await store.close()
        }
        defer { Task { let s = ResultStore(columns: []); _ = try? await session.execute("DROP TABLE IF EXISTS my_meta", into: s); await s.close() } }
        let statements = [
            "SHOW FULL TABLES WHERE Table_type IN ('BASE TABLE', 'VIEW')",
            "SHOW COLUMNS FROM `my_meta`",
            "SHOW INDEX FROM `my_meta`",
            "SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME, ORDINAL_POSITION",
            "SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = DATABASE() AND REFERENCED_TABLE_NAME IS NOT NULL",
            "SHOW CREATE TABLE `my_meta`",
        ]
        var binary: [String] = []
        for statement in statements {
            let store = ResultStore(columns: [])
            _ = try await session.execute(statement, into: store)
            for row in try await store.rows(in: 0..<store.rowCount) {
                for (index, value) in row.enumerated() where value.presence == .binary {
                    binary.append("\(statement.prefix(40))… column \(await store.columns[index].name)")
                }
            }
            await store.close()
        }
        #expect(binary.isEmpty, Comment(rawValue: "binary cells where text was expected: \(binary)"))
    }
}
