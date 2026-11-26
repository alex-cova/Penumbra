import Foundation
import Testing

@testable import DatabaseKit

private let liveEnabled = ProcessInfo.processInfo.environment["UMBRA_DB_INTEGRATION"] == "1"

/// A result is editable only when the server itself says which table and key it came from.
/// These run the real path on disposable PostgreSQL and MySQL servers: RowDescription OIDs,
/// `information_schema`, guarded UPDATEs, conflicts and the transaction they run in.
@Suite(.enabled(if: liveEnabled, "needs UMBRA_DB_INTEGRATION=1 and Scripts/db-test-env.sh up"), .serialized)
struct LiveSQLEditTargetTests {
    private func connect(_ variable: String) async throws -> SQLSession {
        guard let url = ProcessInfo.processInfo.environment[variable] else {
            throw DatabaseError.executionFailed("\(variable) is not set; run Scripts/db-test-env.sh env")
        }
        var login = try SQLURLs.parse(url)
        // The MySQL test container has a self-signed certificate; TLS is covered by its own tests.
        if login.engine == .mysql { login.useTLS = false; login.requireTLS = false }
        return try await SQLSession.connect(login: login, readOnly: false)
    }

    private func columns(_ session: SQLSession, _ sql: String) async throws -> [ResultColumn] {
        let store = ResultStore(columns: [])
        defer { Task { await store.close() } }
        return try await session.execute(sql, parameters: [], into: store).columns
    }

    private func update(
        key: (String, DatabaseValue), _ column: String, from original: DatabaseValue, to replacement: DatabaseValue
    ) -> SQLiteOptimisticUpdate {
        SQLiteOptimisticUpdate(keys: [.init(column: key.0, value: key.1)],
                               changes: [.init(column: column, original: original, replacement: replacement)])
    }

    // MARK: PostgreSQL

    @Test func postgresResolvesTheTableFromRowDescriptionAndEditsAtomically() async throws {
        let session = try await connect("UMBRA_TEST_PG_URL")
        defer { Task { await session.disconnect() } }
        _ = try await session.query("DROP TABLE IF EXISTS edit_pg")
        _ = try await session.query("""
        CREATE TABLE edit_pg (id int PRIMARY KEY, label text NOT NULL, amount numeric(10,2), flag boolean,
            seen timestamptz, tags text[], note text GENERATED ALWAYS AS (upper(label)) STORED)
        """)
        _ = try await session.query("""
        INSERT INTO edit_pg (id, label, amount, flag, seen) VALUES
            (1, 'one', 1.50, true, '2024-05-06 07:08:09+00'), (2, 'two', NULL, false, NULL)
        """)
        defer { Task { _ = try? await session.query("DROP TABLE IF EXISTS edit_pg") } }

        let resolution = await session.resolveEditTarget(columns: try await columns(session, "SELECT * FROM edit_pg"))
        guard case .editable(let target) = resolution else {
            Issue.record("expected an editable target, got \(resolution)")
            return
        }
        #expect(target.table == "edit_pg" && target.schema == "public")
        #expect(target.keys.map(\.name) == ["id"])
        #expect(target.column(named: "label")?.readOnlyReason == nil)
        #expect(target.column(named: "amount")?.readOnlyReason == nil)
        #expect(target.column(named: "id")?.readOnlyReason != nil)
        #expect(target.column(named: "tags")?.readOnlyReason?.contains("not editable") == true)
        #expect(target.column(named: "note")?.readOnlyReason?.contains("generated") == true)

        // Typed cells compare through casts: numeric, boolean and timestamptz originals.
        let changes = [
            update(key: ("id", .int(1)), "amount", from: .decimal("1.50"), to: .text("2.25")),
            update(key: ("id", .int(2)), "flag", from: .bool(false), to: .bool(true)),
        ]
        let result = try await session.applyUpdates(changes, target: target)
        #expect(result.rowsAffected == 2 && !result.leftTransactionOpen)
        #expect(try await session.query("SELECT amount::text, flag::text FROM edit_pg ORDER BY id").rows
                == [["2.25", "true"], [nil, "true"]])

        // An original that no longer matches writes nothing, including rows that did match.
        _ = try await session.query("UPDATE edit_pg SET label = 'changed elsewhere' WHERE id = 2")
        let stale = [
            update(key: ("id", .int(1)), "label", from: .text("one"), to: .text("uno")),
            update(key: ("id", .int(2)), "label", from: .text("two"), to: .text("dos")),
        ]
        do {
            _ = try await session.applyUpdates(stale, target: target)
            Issue.record("a changed row must be a conflict")
        } catch let conflict as SQLiteOptimisticConflict {
            #expect(conflict.updateIndex == 1)
            #expect(conflict.current == [.text("changed elsewhere")])
        }
        #expect(try await session.query("SELECT label FROM edit_pg ORDER BY id").rows == [["one"], ["changed elsewhere"]])
        #expect(await session.transactionState() == .none)

        // NULL originals match with IS NOT DISTINCT FROM; a NOT NULL violation names its row.
        let nullEdit = update(key: ("id", .int(2)), "seen", from: .null, to: .temporal("2024-01-02 03:04:05+00", .timestampWithZone))
        _ = try await session.applyUpdates([nullEdit], target: target)
        let rejected = [update(key: ("id", .int(1)), "label", from: .text("one"), to: .null)]
        await #expect(throws: SQLiteMutationFailure.self) { _ = try await session.applyUpdates(rejected, target: target) }
        #expect(await session.transactionState() == .none)
    }

    @Test func postgresSubmitsInsideTheConsolesOwnTransactionAndRecoversFromAFailure() async throws {
        let session = try await connect("UMBRA_TEST_PG_URL")
        defer { Task { await session.disconnect() } }
        _ = try await session.query("DROP TABLE IF EXISTS edit_pg_tx")
        _ = try await session.query("CREATE TABLE edit_pg_tx (id int PRIMARY KEY, label text NOT NULL)")
        _ = try await session.query("INSERT INTO edit_pg_tx VALUES (1, 'a')")
        defer { Task { _ = try? await session.query("DROP TABLE IF EXISTS edit_pg_tx") } }
        guard case .editable(let target) = await session.resolveEditTarget(columns: try await columns(session, "SELECT id, label FROM edit_pg_tx")) else {
            Issue.record("expected an editable target")
            return
        }
        let observer = try await connect("UMBRA_TEST_PG_URL")
        defer { Task { await observer.disconnect() } }

        try await session.beginTransaction()
        let ok = try await session.applyUpdates([update(key: ("id", .int(1)), "label", from: .text("a"), to: .text("b"))], target: target)
        #expect(ok.leftTransactionOpen)
        #expect(await session.transactionState().isOpen)
        #expect(try await observer.query("SELECT label FROM edit_pg_tx").rows == [["a"]], "not committed")
        // A rejected batch rolls back to its savepoint and leaves the transaction usable.
        await #expect(throws: SQLiteMutationFailure.self) {
            _ = try await session.applyUpdates([update(key: ("id", .int(1)), "label", from: .text("b"), to: .null)], target: target)
        }
        #expect(await session.transactionState() == .active(readOnly: false))
        #expect(try await session.query("SELECT label FROM edit_pg_tx").rows == [["b"]])
        try await session.endTransaction(commit: true)
        #expect(try await observer.query("SELECT label FROM edit_pg_tx").rows == [["b"]])
    }

    @Test func postgresResultsWithoutAVerifiedTableOrKeyAreReadOnlyWithAReason() async throws {
        let session = try await connect("UMBRA_TEST_PG_URL")
        defer { Task { await session.disconnect() } }
        _ = try await session.query("DROP VIEW IF EXISTS edit_pg_view")
        _ = try await session.query("DROP TABLE IF EXISTS edit_pg_a")
        _ = try await session.query("DROP TABLE IF EXISTS edit_pg_b")
        _ = try await session.query("DROP TABLE IF EXISTS edit_pg_nokey")
        _ = try await session.query("CREATE TABLE edit_pg_a (id int PRIMARY KEY, v text)")
        _ = try await session.query("CREATE TABLE edit_pg_b (id int PRIMARY KEY, w text)")
        _ = try await session.query("CREATE TABLE edit_pg_nokey (v text)")
        _ = try await session.query("INSERT INTO edit_pg_a VALUES (1, 'x')")
        defer {
            Task {
                _ = try? await session.query("DROP VIEW IF EXISTS edit_pg_view")
                for table in ["edit_pg_a", "edit_pg_b", "edit_pg_nokey"] { _ = try? await session.query("DROP TABLE IF EXISTS \(table)") }
            }
        }
        _ = try await session.query("CREATE VIEW edit_pg_view AS SELECT id, v FROM edit_pg_a")

        func reason(_ sql: String) async throws -> String {
            guard case .readOnly(let reason) = await session.resolveEditTarget(columns: try await columns(session, sql)) else {
                return "editable"
            }
            return reason
        }
        #expect(try await reason("SELECT a.id, b.w FROM edit_pg_a a JOIN edit_pg_b b USING (id)").contains("several tables"))
        #expect(try await reason("SELECT v FROM edit_pg_a").contains("primary key"), "the key column is missing")
        #expect(try await reason("SELECT count(*) AS n FROM edit_pg_a").contains("come from a table"))
        #expect(try await reason("SELECT v FROM edit_pg_nokey").contains("primary key"))
        #expect(try await reason("SELECT id, v FROM edit_pg_view").contains("not an ordinary table"))
        #expect(try await reason("SELECT id, id AS again, v FROM edit_pg_a").contains("more than once"))
        #expect(try await reason("SELECT id, v FROM edit_pg_a") == "editable")
        // A read-only connection never resolves a target.
        let readOnly = try await SQLSession.connect(login: SQLURLs.parse(ProcessInfo.processInfo.environment["UMBRA_TEST_PG_URL"] ?? ""), readOnly: true)
        defer { Task { await readOnly.disconnect() } }
        #expect(await readOnly.resolveEditTarget(columns: try await columns(readOnly, "SELECT id, v FROM edit_pg_a")) == .readOnly("This connection is read-only."))
    }

    // MARK: MySQL

    @Test func mysqlUsesTheServersOriginMetadataAndComparesBytesNotCollations() async throws {
        let session = try await connect("UMBRA_TEST_MYSQL_URL")
        defer { Task { await session.disconnect() } }
        _ = try await session.query("DROP TABLE IF EXISTS edit_my")
        _ = try await session.query("""
        CREATE TABLE edit_my (id int PRIMARY KEY, label varchar(20) NOT NULL, amount decimal(10,2), seen datetime,
            blobby blob, ratio double, note varchar(30) GENERATED ALWAYS AS (upper(label)) STORED)
        """)
        _ = try await session.query("INSERT INTO edit_my (id, label, amount, seen, ratio) VALUES (1, 'Alpha', 1.50, '2024-05-06 07:08:09', 0.5), (2, 'beta', NULL, NULL, NULL)")
        defer { Task { _ = try? await session.query("DROP TABLE IF EXISTS edit_my") } }

        guard case .editable(let target) = await session.resolveEditTarget(columns: try await columns(session, "SELECT * FROM edit_my")) else {
            Issue.record("expected an editable MySQL target")
            return
        }
        #expect(target.table == "edit_my" && target.keys.map(\.name) == ["id"])
        #expect(target.column(named: "label")?.readOnlyReason == nil)
        #expect(target.column(named: "amount")?.readOnlyReason == nil)
        #expect(target.column(named: "blobby")?.readOnlyReason?.contains("not editable") == true)
        #expect(target.column(named: "ratio")?.readOnlyReason?.contains("not editable") == true)
        #expect(target.column(named: "note")?.readOnlyReason?.contains("generated") == true)

        let edits = [
            update(key: ("id", .int(1)), "amount", from: .decimal("1.50"), to: .text("3.75")),
            update(key: ("id", .int(1)), "seen", from: .temporal("2024-05-06 07:08:09", .timestamp), to: .text("2025-01-02 03:04:05")),
            update(key: ("id", .int(2)), "label", from: .text("beta"), to: .text("gamma")),
        ]
        // Three updates on two rows, grouped by the caller into one per row.
        let grouped = [
            SQLiteOptimisticUpdate(keys: edits[0].keys, changes: edits[0].changes + edits[1].changes),
            edits[2],
        ]
        let result = try await session.applyUpdates(grouped, target: target)
        #expect(result.rowsAffected == 2)
        #expect(try await session.query("SELECT amount, seen, label FROM edit_my ORDER BY id").rows
                == [["3.75", "2025-01-02 03:04:05", "Alpha"], [nil, nil, "gamma"]])

        // 'Alpha' and 'alpha' are equal under the default collation; the guard must not call them equal.
        _ = try await session.query("UPDATE edit_my SET label = 'ALPHA' WHERE id = 1")
        do {
            _ = try await session.applyUpdates([update(key: ("id", .int(1)), "label", from: .text("Alpha"), to: .text("x"))], target: target)
            Issue.record("a case-only change must still be a conflict")
        } catch let conflict as SQLiteOptimisticConflict {
            #expect(conflict.current == [.text("ALPHA")])
        }
        // A NULL original matches with <=>.
        _ = try await session.applyUpdates([update(key: ("id", .int(2)), "amount", from: .null, to: .text("9.00"))], target: target)
        #expect(try await session.query("SELECT amount FROM edit_my WHERE id = 2").rows == [["9.00"]])
        #expect(await session.transactionState() == .none)
    }

    @Test func mysqlRefusesViewsJoinsAndResultsWithoutTheKey() async throws {
        let session = try await connect("UMBRA_TEST_MYSQL_URL")
        defer { Task { await session.disconnect() } }
        _ = try await session.query("DROP TABLE IF EXISTS edit_my_a")
        _ = try await session.query("DROP TABLE IF EXISTS edit_my_b")
        _ = try await session.query("DROP VIEW IF EXISTS edit_my_view")
        _ = try await session.query("CREATE TABLE edit_my_a (id int PRIMARY KEY, v varchar(10))")
        _ = try await session.query("CREATE TABLE edit_my_b (id int PRIMARY KEY, w varchar(10))")
        _ = try await session.query("CREATE VIEW edit_my_view AS SELECT id, v FROM edit_my_a")
        _ = try await session.query("INSERT INTO edit_my_a VALUES (1, 'x')")
        defer {
            Task {
                _ = try? await session.query("DROP VIEW IF EXISTS edit_my_view")
                _ = try? await session.query("DROP TABLE IF EXISTS edit_my_a")
                _ = try? await session.query("DROP TABLE IF EXISTS edit_my_b")
            }
        }
        func reason(_ sql: String) async throws -> String {
            guard case .readOnly(let reason) = await session.resolveEditTarget(columns: try await columns(session, sql)) else {
                return "editable"
            }
            return reason
        }
        #expect(try await reason("SELECT a.id, b.w FROM edit_my_a a JOIN edit_my_b b USING (id)").contains("several tables"))
        #expect(try await reason("SELECT v FROM edit_my_a").contains("primary key"))
        #expect(try await reason("SELECT count(*) AS n FROM edit_my_a").contains("come from a table"))
        #expect(try await reason("SELECT id, id AS again, v FROM edit_my_a").contains("more than once"))
        #expect(try await reason("SELECT id, v FROM edit_my_a") == "editable")
        let view = try await reason("SELECT id, v FROM edit_my_view")
        #expect(view == "edit_my_view is a view, not a table.", "MySQL reports the view itself as the origin table: \(view)")
    }
}
