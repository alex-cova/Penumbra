import Foundation
import Testing

@testable import DatabaseKit

private let liveEnabled = ProcessInfo.processInfo.environment["UMBRA_DB_INTEGRATION"] == "1"

@Suite(.enabled(if: liveEnabled, "needs UMBRA_DB_INTEGRATION=1 and Scripts/db-test-env.sh up"), .serialized)
struct LivePostgresSessionTests {
    private func login() throws -> SQLLogin {
        guard let url = ProcessInfo.processInfo.environment["UMBRA_TEST_PG_URL"] else {
            throw DatabaseError.executionFailed("UMBRA_TEST_PG_URL is not set; run Scripts/db-test-env.sh env")
        }
        return try SQLURLs.parse(url)
    }

    private func connect(readOnly: Bool = false) async throws -> PostgresSession {
        try await PostgresSession.connect(login: login(), readOnly: readOnly)
    }

    @discardableResult
    private func run(
        _ session: PostgresSession, _ sql: String, limit: Int? = nil, options: ExecuteOptions = .init()
    ) async throws -> (summary: ExecutionSummary, rows: [[String?]]) {
        let store = ResultStore(columns: [], rowLimit: limit)
        let summary = try await session.execute(sql, into: store, options: options)
        let rows = try await store.rows(in: 0..<min(await store.rowCount, 100_000)).map { $0.map(\.rawText) }
        await store.close()
        return (summary, rows)
    }

    private func count(_ session: PostgresSession, _ table: String) async throws -> Int {
        let result = try await run(session, "SELECT count(*) FROM \(table)")
        return Int(result.rows[0][0] ?? "") ?? -1
    }

    // MARK: F-01: one connection, ordered, transactional

    @Test func statementsOfOneSessionRunOnOneBackendAndATransactionIsReal() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await run(session, "CREATE TEMP TABLE pin_probe (id int)")  // temp tables live on one connection
        try await session.begin()
        try await run(session, "INSERT INTO pin_probe VALUES (1), (2)")
        let pids = try await (0..<5).asyncMap { _ in try await run(session, "SELECT pg_backend_pid()").rows[0][0] }
        #expect(Set(pids).count == 1, "every statement must use the same backend")
        #expect(pids.first! == String(session.backendPID))
        #expect(try await count(session, "pin_probe") == 2)
        #expect(await session.transaction == .active(readOnly: false))
        try await session.rollback()
        #expect(try await count(session, "pin_probe") == 0, "ROLLBACK must undo the insert made after BEGIN")
        #expect(await session.transaction == .none)

        try await session.begin()
        try await run(session, "INSERT INTO pin_probe VALUES (3)")
        try await session.commit()
        #expect(try await count(session, "pin_probe") == 1)
    }

    @Test func aTransactionTypedInTheConsoleIsTracked() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await run(session, "BEGIN")
        #expect(await session.transaction == .active(readOnly: false))
        await #expect(throws: DatabaseServerError.self) { try await self.run(session, "SELECT 1/0") }
        #expect(await session.transaction == .aborted, "an error inside a transaction aborts it")
        try await run(session, "ROLLBACK")
        #expect(await session.transaction == .none)
    }

    // MARK: F-03: the server refuses writes, whatever the SQL looks like

    @Test func readOnlySessionsAreRefusedByTheServerNotByAKeywordScan() async throws {
        let writer = try await connect()
        let reader = try await connect(readOnly: true)
        defer { Task { await writer.close(); await reader.close() } }
        try await run(writer, "DROP TABLE IF EXISTS ro_probe")
        try await run(writer, "CREATE TABLE ro_probe (id int primary key, note text)")
        try await run(writer, "INSERT INTO ro_probe VALUES (1,'a'),(2,'b'),(3,'c')")
        try await run(writer, "CREATE OR REPLACE FUNCTION ro_probe_delete() RETURNS int LANGUAGE sql AS 'DELETE FROM ro_probe RETURNING 1'")
        try await run(writer, "CREATE SEQUENCE IF NOT EXISTS ro_probe_seq")

        let attacks = [
            "WITH gone AS (DELETE FROM ro_probe RETURNING *) SELECT * FROM gone",
            "SELECT ro_probe_delete()",
            "SELECT nextval('ro_probe_seq')",
            "DELETE FROM ro_probe",
            "UPDATE ro_probe SET note = 'x'",
            "INSERT INTO ro_probe VALUES (9,'z')",
            "TRUNCATE ro_probe",
            "SELECT * INTO ro_probe_copy FROM ro_probe",
            "CREATE TABLE ro_probe_new (id int)",
            "EXPLAIN ANALYZE DELETE FROM ro_probe",
            "SET TRANSACTION READ WRITE",
        ]
        for attack in attacks {
            // The keyword scan alone would have let several of these through. Run them without
            // that scan in the way: the server must be the one that says no (or the statement
            // must be a harmless no-op that changed nothing).
            _ = try? await run(reader, attack)
            #expect(try await count(writer, "ro_probe") == 3, "'\(attack)' changed the table")
        }
        // After all of that, the next statement is read-only again (state did not leak).
        await #expect(throws: DatabaseServerError.self) { try await self.run(reader, "DELETE FROM ro_probe") }
        let read = try await run(reader, "SELECT count(*) FROM ro_probe")
        #expect(read.rows[0][0] == "3")
        let sequenceValue = try await run(writer, "SELECT last_value, is_called FROM ro_probe_seq")
        #expect(sequenceValue.rows[0][1] == "false", "nextval must not have advanced the sequence")
        try await run(writer, "DROP FUNCTION ro_probe_delete()")
        try await run(writer, "DROP TABLE ro_probe")
        try await run(writer, "DROP SEQUENCE ro_probe_seq")
    }

    @Test func forceReadOnlyProtectsAWritableConnection() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        // A real table: PostgreSQL allows writes to TEMP tables even in a read-only transaction.
        try await run(session, "DROP TABLE IF EXISTS force_ro")
        try await run(session, "CREATE TABLE force_ro (id int)")
        defer { Task { _ = try? await self.run(session, "DROP TABLE IF EXISTS force_ro") } }
        await #expect(throws: DatabaseServerError.self) {
            try await self.run(session, "INSERT INTO force_ro VALUES (1)", options: ExecuteOptions(forceReadOnly: true))
        }
        #expect(try await count(session, "force_ro") == 0)
        // And the next, ordinary statement is writable again.
        try await run(session, "INSERT INTO force_ro VALUES (1)")
        #expect(try await count(session, "force_ro") == 1)
    }

    // MARK: F-07: cancellation

    @Test func cancellingARunningStatementReturnsPromptly() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        let start = ContinuousClock.now
        async let outcome = run(session, "SELECT pg_sleep(30)")
        try await Task.sleep(for: .milliseconds(300))
        let cancelRequestedAt = ContinuousClock.now
        await session.cancelRunning()
        let result = try await outcome
        let total = ContinuousClock.now - start
        let afterCancel = ContinuousClock.now - cancelRequestedAt
        print("PGCANCEL total=\(total) afterCancelRequest=\(afterCancel)")
        #expect(result.summary.wasCancelled)
        #expect(afterCancel < .seconds(2), "cancel took \(afterCancel)")
        // The session is still good afterwards.
        #expect(try await run(session, "SELECT 1").rows[0][0] == "1")
    }

    @Test func cancellingTheTaskCancelsTheStatement() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        let task = Task { try await self.run(session, "SELECT pg_sleep(30)") }
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        task.cancel()
        await session.cancelRunning()
        let result = try await task.value
        #expect(result.summary.wasCancelled)
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(try await run(session, "SELECT 1").rows[0][0] == "1")
    }

    // MARK: F-05: bounded, early-stopping results

    @Test func aRowLimitStopsATenMillionRowQueryEarly() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        let start = ContinuousClock.now
        // `generate_series` in the target list streams; in FROM the server materializes all ten
        // million rows before the first one, which would measure the server, not the client.
        let result = try await run(
            session, "SELECT g, md5(g::text) FROM (SELECT generate_series(1, 10000000) AS g) s", limit: 2_000
        )
        let elapsed = ContinuousClock.now - start
        print("PGLIMIT rows=\(result.rows.count) elapsed=\(elapsed)")
        #expect(result.summary.limitReached)
        #expect(result.rows.count == 2_000)
        #expect(result.rows.last?[0] == "2000")
        #expect(elapsed < .seconds(5), "stopping early must not read all ten million rows (took \(elapsed))")
        #expect(try await run(session, "SELECT 1").rows[0][0] == "1")
    }

    @Test func aMillionRowsStreamIntoABoundedStore() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        let store = ResultStore(columns: [], memoryLimitBytes: 16 * 1024 * 1024)
        let start = ContinuousClock.now
        let summary = try await session.execute(
            "SELECT g::text AS id, md5(g::text) AS hash, 'row ' || g AS label FROM generate_series(1, 1000000) g",
            into: store
        )
        let elapsed = ContinuousClock.now - start
        let stats = await store.stats
        print("PGSTREAM rows=\(summary.rowCount) elapsed=\(elapsed) residentBytes=\(stats.residentBytes) spilledBytes=\(stats.spilledBytes)")
        #expect(summary.rowCount == 1_000_000)
        #expect(stats.residentBytes < 16 * 1024 * 1024 + 8 * 1024 * 1024)
        #expect(stats.spilledBytes > 0)
        // Spilled rows come back intact.
        let middle = try await store.rows(in: 500_000..<500_003).map { $0.map(\.rawText) }
        #expect(middle[0][0] == "500001")
        await store.close()
    }

    // MARK: Results and errors

    @Test func affectedRowsAndCommandTagsAreReported() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        try await run(session, "CREATE TEMP TABLE aff (id int, v text)")
        let insert = try await run(session, "INSERT INTO aff VALUES (1,'a'),(2,'b'),(3,'c')")
        #expect(insert.summary.affectedRows == 3)
        let update = try await run(session, "UPDATE aff SET v = 'z' WHERE id < 3")
        #expect(update.summary.affectedRows == 2)
        let none = try await run(session, "UPDATE aff SET v = 'q' WHERE id = 99")
        #expect(none.summary.affectedRows == 0, "zero rows affected must be reported as 0, not as 'unknown'")
        let delete = try await run(session, "DELETE FROM aff WHERE id = 3")
        #expect(delete.summary.affectedRows == 1)
        let returning = try await run(session, "INSERT INTO aff VALUES (7,'r') RETURNING id, v")
        #expect(returning.rows == [["7", "r"]])
        #expect(returning.summary.affectedRows == 1)
    }

    @Test func anEmptyResultStillHasItsColumns() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        let store = ResultStore(columns: [])
        let summary = try await session.execute("SELECT 1::int AS a, 'x'::text AS b WHERE false", into: store)
        #expect(summary.rowCount == 0)
        #expect(summary.columns.map(\.name) == ["a", "b"])
        #expect(summary.columns.map(\.typeName) == ["int4", "text"])
        await store.close()
    }

    @Test func serverErrorsCarryAPositionAndSQLState() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        do {
            try await run(session, "SELECT * FROM table_that_is_not_there")
            Issue.record("expected an error")
        } catch let error as DatabaseServerError {
            #expect(error.code == "42P01")
            #expect(error.position == 15, "the server blames character 15 (the table name)")
            #expect(error.message.contains("table_that_is_not_there"))
        }
        // A syntax error likewise.
        do {
            try await run(session, "SELEC 1")
            Issue.record("expected an error")
        } catch let error as DatabaseServerError {
            #expect(error.code == "42601")
            #expect(error.position == 1)
        }
        #expect(try await run(session, "SELECT 1").rows[0][0] == "1", "the session survives errors")
    }

    @Test func aSecondStatementWhileOneRunsIsRefusedNotInterleaved() async throws {
        let session = try await connect()
        defer { Task { await session.close() } }
        async let slow = run(session, "SELECT pg_sleep(2)")
        try await Task.sleep(for: .milliseconds(300))
        await #expect(throws: DatabaseError.self) { try await self.run(session, "SELECT 1") }
        _ = try await slow
    }

    // MARK: F-04: TLS

    @Test func requiringTLSAgainstAServerWithoutTLSFailsInsteadOfDowngrading() async throws {
        var plain = try login()
        plain.requireTLS = true
        // The test container has no certificate configured, so a "prefer" fallback would have
        // connected in clear text. "Use TLS" must fail.
        do {
            let session = try await PostgresSession.connect(login: plain, readOnly: true)
            await session.close()
            Issue.record("connected without TLS although TLS was requested")
        } catch {
            print("PGTLS error=\(error)")
        }
    }

    @Test func serverFactsAndCapabilitiesAreDetectedNotAssumed() async throws {
        let session = try await connect(readOnly: true)
        defer { Task { await session.close() } }
        let info = await session.serverInfo
        #expect(info.engine == .postgres)
        #expect(info.majorVersion == 16)
        #expect(info.features.contains("postgis"), "the test image ships PostGIS")
        let capabilities = await session.capabilities
        #expect(capabilities.contains(.spatial))
        #expect(capabilities.contains(.serverEnforcedReadOnly))
        #expect(await session.currentDatabase == "umbra")
        // A read-only connection has no transactions to offer.
        await #expect(throws: DatabaseError.self) { try await session.begin() }
    }
}

extension Sequence {
    fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
