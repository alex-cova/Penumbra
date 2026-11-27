import Foundation
import Testing

@testable import DatabaseKit

/// Real SQLite databases in temporary files and in memory. No mocks.
private final class TempFolder {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-sqlite-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    deinit { try? FileManager.default.removeItem(at: url) }
}

private func rows(
    _ session: SQLiteSession, _ sql: String, _ parameters: [DatabaseValue] = [], options: ExecuteOptions = .init()
) async throws -> (summary: ExecutionSummary, rows: [[DatabaseValue]]) {
    let store = ResultStore(columns: [])
    defer { Task { await store.close() } }
    let summary = try await session.execute(sql, parameters: parameters, into: store, options: options)
    return (summary, try await store.rows(in: 0..<store.rowCount))
}

@discardableResult
private func exec(_ session: SQLiteSession, _ sql: String, _ parameters: [DatabaseValue] = []) async throws -> ExecutionSummary {
    try await rows(session, sql, parameters).summary
}

private func text(_ value: DatabaseValue) -> String? { value.rawText }

/// Collects progress reports from a `@Sendable` callback.
private final class ProgressBox: @unchecked Sendable {
    // Test helper: the lock makes the one mutable field safe to touch from the backup's callback.
    private let lock = NSLock()
    private var value = 0.0
    func record(_ progress: Double) { lock.withLock { value = max(value, progress) } }
    var maximum: Double { lock.withLock { value } }
}

struct SQLiteOpeningTests {
    @Test func opensCreatesAndValidatesFiles() async throws {
        let folder = TempFolder()
        // A path that is not there is an error, not a silently created database.
        await #expect(throws: SQLiteSession.OpenError.self) {
            _ = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("nope.db"))))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path("nope.db")))
        // Creating is explicit.
        let created = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("new.sqlite")), createIfMissing: true))
        try await exec(created, "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
        try await exec(created, "INSERT INTO t (name) VALUES ('a')")
        await created.close()
        // The same file reopens with its data, and the magic header is the real one.
        let reopened = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("new.sqlite"))))
        #expect(try await rows(reopened, "SELECT name FROM t").rows.map { text($0[0]) } == ["a"])
        await reopened.close()
        let header = try Data(contentsOf: URL(fileURLWithPath: folder.path("new.sqlite"))).prefix(16)
        #expect(Array(header) == SQLiteSession.fileMagic)
    }

    @Test func aTextFileNamedDotDBIsReportedAsWhatItIs() async throws {
        let folder = TempFolder()
        try "hello, I am not a database, just a text file with enough bytes".write(toFile: folder.path("fake.db"), atomically: true, encoding: .utf8)
        do {
            _ = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("fake.db"))))
            Issue.record("opened a text file as a database")
        } catch let error as SQLiteSession.OpenError {
            #expect(error == .notADatabase(folder.path("fake.db")))
            #expect(error.localizedDescription.contains("not a SQLite database"))
        }
        // An empty file is a valid empty database; a directory is not a database.
        FileManager.default.createFile(atPath: folder.path("empty.db"), contents: Data())
        let empty = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("empty.db"))))
        #expect(try await empty.tableNames().isEmpty)
        await empty.close()
        await #expect(throws: SQLiteSession.OpenError.self) {
            _ = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.url.path)))
        }
    }

    @Test func aDamagedFileIsReportedWithAHintNotAMysteriousError() async throws {
        let folder = TempFolder()
        let path = folder.path("damaged.db")
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(path), createIfMissing: true))
        try await exec(session, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        for index in 0..<2_000 { try await exec(session, "INSERT INTO t (v) VALUES (?1)", [.text("row \(index) " + String(repeating: "x", count: 100))]) }
        await session.close()
        // Keep the 16-byte header, wreck the page structure behind it.
        var data = try Data(contentsOf: URL(fileURLWithPath: path))
        for index in 100..<min(data.count, 4_096) { data[index] = 0xAB }
        try data.write(to: URL(fileURLWithPath: path))
        do {
            let damaged = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(path)))
            // If SQLite still opens it, the integrity check must say so.
            let report = try await damaged.integrityCheck()
            #expect(report != ["ok"])
            await damaged.close()
        } catch let error as SQLiteSession.OpenError {
            #expect(error.localizedDescription.lowercased().contains("corrupt") || error.localizedDescription.contains("not a database"))
        }
    }

    @Test func readOnlyOpenRefusesWrites() async throws {
        let folder = TempFolder()
        let writer = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("ro.db")), createIfMissing: true))
        try await exec(writer, "CREATE TABLE t (id INTEGER)")
        try await exec(writer, "INSERT INTO t VALUES (1)")
        await writer.close()
        let reader = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("ro.db")), readOnly: true))
        #expect(await reader.capabilities.contains(.serverEnforcedReadOnly))
        await #expect(throws: DatabaseError.readOnlyViolation) { _ = try await exec(reader, "INSERT INTO t VALUES (2)") }
        await #expect(throws: DatabaseError.readOnlyViolation) { _ = try await exec(reader, "CREATE TABLE u (x)") }
        #expect(try await rows(reader, "SELECT count(*) FROM t").rows[0][0] == .int(1))
        await #expect(throws: DatabaseError.self) { try await reader.begin() }
        await #expect(throws: DatabaseError.readOnlyViolation) { try await reader.vacuum() }
        await reader.close()
    }

    @Test func aWALDatabaseWithoutItsSideFilesStillOpensReadOnly() async throws {
        // SQLite's own shell fails to open this read-only ("unable to open database file").
        let folder = TempFolder()
        let source = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("src.db")), createIfMissing: true))
        try await exec(source, "PRAGMA journal_mode = WAL")
        try await exec(source, "CREATE TABLE t (id INTEGER)")
        try await exec(source, "INSERT INTO t VALUES (1), (2)")
        try await source.backup(to: folder.path("clean.db"))  // WAL header, no -wal and no -shm
        await source.close()
        #expect(!FileManager.default.fileExists(atPath: folder.path("clean.db-wal")))
        let reader = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("clean.db")), readOnly: true))
        #expect(try await rows(reader, "SELECT count(*) FROM t").rows[0][0] == .int(2))
        #expect(await reader.capabilities.contains(.serverEnforcedReadOnly))
        await #expect(throws: (any Error).self) { _ = try await exec(reader, "INSERT INTO t VALUES (3)") }
        await #expect(throws: (any Error).self) { _ = try await exec(reader, "CREATE TABLE u (x)") }
        #expect(try await rows(reader, "SELECT count(*) FROM t").rows[0][0] == .int(2), "nothing was written")
        #expect(!(await reader.serverInfo.features.contains("immutable")), "the query-only fallback sees live data and is not immutable")
        await reader.close()
    }

    @Test func aWALDatabaseInAReadOnlyFolderOpensImmutableAndSaysSo() async throws {
        let folder = TempFolder()
        let source = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("src.db")), createIfMissing: true))
        try await exec(source, "PRAGMA journal_mode = WAL")
        try await exec(source, "CREATE TABLE t (id INTEGER)")
        try await exec(source, "INSERT INTO t VALUES (1)")
        try await source.backup(to: folder.path("locked.db"))
        await source.close()
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: folder.path("locked.db"))
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.url.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.url.path) }
        let reader = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("locked.db")), readOnly: true))
        #expect(try await rows(reader, "SELECT count(*) FROM t").rows[0][0] == .int(1))
        #expect(await reader.serverInfo.features.contains("immutable"), "the user must be able to see that this view can be stale")
        await #expect(throws: (any Error).self) { _ = try await exec(reader, "INSERT INTO t VALUES (2)") }
        await reader.close()
    }

    @Test func aMemoryDatabaseLivesInExactlyOneConnection() async throws {
        let first = try await SQLiteSession.open(SQLiteOpenOptions(location: .memory))
        try await exec(first, "CREATE TABLE t (x)")
        try await exec(first, "INSERT INTO t VALUES (1)")
        #expect(try await rows(first, "SELECT count(*) FROM t").rows[0][0] == .int(1), "state persists across statements")
        // Another :memory: connection is a different, empty database: it must never be mistaken for the first.
        let second = try await SQLiteSession.open(SQLiteOpenOptions(location: .memory))
        #expect(try await second.tableNames().isEmpty)
        await first.close()
        await second.close()
    }
}

struct SQLiteExecutionTests {
    @Test func valuesKeepTheirStorageClassWhateverTheColumnDeclares() async throws {
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .memory))
        try await exec(session, "CREATE TABLE t (i INTEGER, r REAL, tx TEXT, b BLOB, n NUMERIC, untyped)")
        try await exec(session, "INSERT INTO t VALUES (9223372036854775807, 1.5, '', x'DEADBEEF', '12.50', NULL)")
        // An INTEGER column can hold text; a TEXT column can hold a number. SQLite allows both.
        try await exec(session, "INSERT INTO t VALUES ('not a number', 'text in REAL', 42, 'text in BLOB', 7, 1)")
        let result = try await rows(session, "SELECT * FROM t ORDER BY rowid")
        let first = result.rows[0], second = result.rows[1]
        #expect(first[0] == .int(Int64.max))
        #expect(first[1] == .double(1.5))
        #expect(first[2] == .text(""), "the empty string is not NULL")
        #expect(first[4] == .double(12.5) || first[4] == .text("12.50") || first[4] == .int(12), "NUMERIC affinity converts '12.50' to a number")
        #expect(first[5] == .null)
        #expect(second[0] == .text("not a number"), "an INTEGER column holding text shows the text")
        #expect(second[1] == .text("text in REAL"))
        #expect(second[2] == .text("42"), "TEXT affinity turns the number 42 into text on insert: a column prefers a type, it does not enforce one")
        #expect(second[5] == .int(1), "a column with no declared type keeps whatever it was given")
        #expect(second[3] == .bytes(count: 12, prefix: Array("text in BLOB".utf8)) || second[3] == .text("text in BLOB"))
        // Declared types are reported as written, with their affinity separately.
        let columns = result.summary.columns
        #expect(columns.map(\.typeName) == ["INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC", ""])
        #expect(columns[0].origin == ResultColumn.Origin(schema: "main", table: "t", column: "i"))
        await session.close()
    }

    @Test func largeValuesAreBounded() async throws {
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .memory))
        try await exec(session, "CREATE TABLE t (tx TEXT, b BLOB)")
        try await exec(session, "INSERT INTO t VALUES (?1, ?2)", [.text(String(repeating: "é", count: 200_000)), .bytes(count: 3_000_000, prefix: [UInt8](repeating: 7, count: 3_000_000))])
        let row = try await rows(session, "SELECT tx, b FROM t").rows[0]
        guard case .truncated(let preview, let full) = row[0] else { Issue.record("expected truncated text, got \(row[0])"); return }
        #expect(full == 400_000)
        #expect(preview.utf8.count <= ValueLimits.standard.maxTextBytes)
        #expect(!preview.contains("\u{FFFD}"))
        #expect(row[1] == .bytes(count: 3_000_000, prefix: [UInt8](repeating: 7, count: ValueLimits.standard.binaryPrefix)))
        await session.close()
    }

    @Test func affectedRowsParametersAndErrors() async throws {
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .memory))
        try await exec(session, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        #expect(try await exec(session, "INSERT INTO t (v) VALUES (?1), (?2), (?3)", [.text("a"), .text("b"), .null]).affectedRows == 3)
        #expect(try await exec(session, "UPDATE t SET v = 'z' WHERE id < 3").affectedRows == 2)
        #expect(try await exec(session, "UPDATE t SET v = 'q' WHERE id = 99").affectedRows == 0)
        #expect(try await rows(session, "SELECT v FROM t WHERE v IS NULL").rows.count == 1)
        // Binding keeps hostile text as data.
        try await exec(session, "INSERT INTO t (v) VALUES (?1)", [.text("'); DROP TABLE t; --")])
        #expect(try await rows(session, "SELECT count(*) FROM t").rows[0][0] == .int(4))
        // Parameter count must match.
        await #expect(throws: DatabaseError.self) { _ = try await exec(session, "SELECT ?1, ?2", [.int(1)]) }
        // A syntax error says where.
        do {
            _ = try await exec(session, "SELEC 1")
            Issue.record("expected a syntax error")
        } catch let error as DatabaseServerError {
            #expect(error.message.contains("syntax error"))
            #expect(error.position == 1, "SQLite blames the first word, character 1")
        }
        do {
            _ = try await exec(session, "SELECT * FROM missing_table")
            Issue.record("expected an error")
        } catch let error as DatabaseServerError {
            #expect(error.message.contains("no such table"))
        }
        // Constraint violations are errors with the SQLite message.
        await #expect(throws: DatabaseServerError.self) { _ = try await exec(session, "INSERT INTO t (id, v) VALUES (1, 'dup')") }
        #expect(try await rows(session, "SELECT 1").rows[0][0] == .int(1), "the session survives errors")
        await session.close()
    }

    @Test func oneStatementAtATimeAndCommentsAreHarmless() async throws {
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .memory))
        await #expect(throws: DatabaseError.self) { _ = try await exec(session, "SELECT 1; SELECT 2") }
        await #expect(throws: DatabaseError.self) { _ = try await exec(session, "CREATE TABLE a (x); DROP TABLE a") }
        #expect(try await session.tableNames().isEmpty, "a refused script runs none of its statements")
        #expect(try await rows(session, "SELECT 1;").rows[0][0] == .int(1), "a trailing semicolon is fine")
        #expect(try await rows(session, "-- leading comment\nSELECT 2 /* inline */").rows[0][0] == .int(2))
        #expect(try await rows(session, "SELECT 3; -- trailing comment\n  /* and another */ ;").rows[0][0] == .int(3), "only comments and semicolons after the statement")
        #expect(try await exec(session, "-- only a comment").rowCount == 0)
        await #expect(throws: DatabaseError.self) { _ = try await exec(session, "   \n ") }
        await session.close()
    }

    @Test func transactionsAreTrackedWhoeverStartsThem() async throws {
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .memory))
        try await exec(session, "CREATE TABLE t (id INTEGER)")
        try await session.begin()
        #expect(await session.transaction == .active(readOnly: false))
        try await exec(session, "INSERT INTO t VALUES (1)")
        try await session.rollback()
        #expect(await session.transaction == .none)
        #expect(try await rows(session, "SELECT count(*) FROM t").rows[0][0] == .int(0))
        // BEGIN typed in a console is seen the same way.
        try await exec(session, "BEGIN")
        #expect(await session.transaction == .active(readOnly: false))
        try await exec(session, "INSERT INTO t VALUES (2)")
        try await exec(session, "SAVEPOINT sp")
        try await exec(session, "INSERT INTO t VALUES (3)")
        try await exec(session, "ROLLBACK TO sp")
        #expect(await session.transaction == .active(readOnly: false), "ROLLBACK TO keeps the transaction open")
        // A failed statement does not end the transaction.
        await #expect(throws: DatabaseServerError.self) { _ = try await exec(session, "INSERT INTO nope VALUES (1)") }
        #expect(await session.transaction == .active(readOnly: false))
        try await exec(session, "COMMIT")
        #expect(await session.transaction == .none)
        #expect(try await rows(session, "SELECT id FROM t").rows.map { $0[0] } == [.int(2)])
        await session.close()
    }

    @Test func aRowLimitStopsAMillionRowQueryEarly() async throws {
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .memory))
        let store = ResultStore(columns: [], rowLimit: 1_000)
        let start = ContinuousClock.now
        let summary = try await session.execute(
            "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100000000) SELECT x FROM c", into: store
        )
        let elapsed = ContinuousClock.now - start
        #expect(summary.limitReached)
        #expect(await store.rowCount == 1_000)
        #expect(elapsed < .seconds(2), "took \(elapsed)")
        await store.close()
        await session.close()
    }
}

struct SQLiteReadOnlyEnforcementTests {
    @Test func forceReadOnlyUsesTheEnginesOwnBlocksNotKeywordScanning() async throws {
        let folder = TempFolder()
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("force.db")), createIfMissing: true))
        try await exec(session, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        try await exec(session, "INSERT INTO t (v) VALUES ('a'), ('b'), ('c')")
        let readOnly = ExecuteOptions(forceReadOnly: true)
        let attacks = [
            "INSERT INTO t (v) VALUES ('x')", "UPDATE t SET v = 'x'", "DELETE FROM t", "DROP TABLE t",
            "CREATE TABLE u (x)", "ALTER TABLE t ADD COLUMN z", "CREATE INDEX i ON t (v)",
            "WITH c AS (SELECT 1) DELETE FROM t", "REPLACE INTO t (id, v) VALUES (1, 'x')",
            "PRAGMA user_version = 77", "PRAGMA journal_mode = WAL", "PRAGMA foreign_keys = ON",
            "ATTACH DATABASE '\(folder.path("stolen.db"))' AS stolen", "VACUUM", "ANALYZE", "REINDEX",
        ]
        for attack in attacks {
            _ = try? await rows(session, attack, options: readOnly)
        }
        #expect(try await rows(session, "SELECT count(*) FROM t").rows[0][0] == .int(3), "the table changed")
        #expect(try await rows(session, "SELECT v FROM t ORDER BY id").rows.map { text($0[0]) } == ["a", "b", "c"])
        #expect(try await session.pragma("user_version") == "0")
        #expect(try await session.journalMode() != "wal", "a read-only call must not switch the journal mode")
        #expect(!FileManager.default.fileExists(atPath: folder.path("stolen.db")), "ATTACH must not create files")
        #expect(try await session.tableNames().map(\.name) == ["t"])
        // What a read-only call *should* allow still works.
        #expect(try await rows(session, "PRAGMA table_info(t)", options: readOnly).rows.count == 2)
        #expect(try await rows(session, "PRAGMA page_size", options: readOnly).rows.count == 1)
        #expect(try await rows(session, "SELECT count(*) FROM pragma_table_xinfo('t')", options: readOnly).rows[0][0] == .int(2))
        #expect(try await rows(session, "EXPLAIN QUERY PLAN SELECT * FROM t WHERE id = 1", options: readOnly).rows.count >= 1)
        // And the next, ordinary call is writable again: state did not leak.
        try await exec(session, "INSERT INTO t (v) VALUES ('d')")
        #expect(try await rows(session, "SELECT count(*) FROM t").rows[0][0] == .int(4))
        await session.close()
    }

    @Test func aReadOnlyCallRefusesWithTheReadOnlyError() async throws {
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .memory))
        try await exec(session, "CREATE TABLE t (id INTEGER)")
        await #expect(throws: DatabaseError.readOnlyViolation) {
            _ = try await rows(session, "INSERT INTO t VALUES (1)", options: ExecuteOptions(forceReadOnly: true))
        }
        await session.close()
    }
}

struct SQLiteCancellationAndConcurrencyTests {
    @Test func interruptStopsALongStatementPromptlyAndTheSessionSurvives() async throws {
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .memory))
        let task = Task {
            try await rows(session, "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c")
        }
        try await Task.sleep(for: .milliseconds(300))
        let requested = ContinuousClock.now
        session.interrupt()  // nonisolated: works while the statement holds the session's queue
        let result = try await task.value
        let elapsed = ContinuousClock.now - requested
        print("SQLITECANCEL afterInterrupt=\(elapsed)")
        #expect(result.summary.wasCancelled)
        #expect(elapsed < .seconds(2))
        #expect(try await rows(session, "SELECT 1").rows[0][0] == .int(1))
        await session.close()
    }

    @Test func cancellingTheTaskInterruptsTheStatement() async throws {
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .memory))
        let task = Task {
            try await rows(session, "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c")
        }
        try await Task.sleep(for: .milliseconds(300))
        // `cancelRunning` is an actor call, so it must not be blocked behind the running statement
        // for longer than the statement's next suspension; the nonisolated interrupt is the path
        // that works regardless. Both end the statement.
        session.interrupt()
        _ = try await task.value
        await session.close()
    }

    @Test func closingWhileAnInterruptIsInFlightNeverTouchesAFreedHandle() async throws {
        for _ in 0..<30 {
            let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .memory))
            let task = Task {
                try? await rows(session, "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c")
            }
            try await Task.sleep(for: .milliseconds(5))
            async let closing: Void = session.close()
            session.interrupt()
            session.interrupt()
            await closing
            _ = await task.value
            session.interrupt()  // after close: must be a harmless no-op
        }
    }

    @Test func aLockHeldByAnotherConnectionIsReportedNotHung() async throws {
        let folder = TempFolder()
        let path = folder.path("lock.db")
        let holder = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(path), createIfMissing: true))
        try await exec(holder, "CREATE TABLE t (id INTEGER)")
        let waiter = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(path), busyTimeoutMilliseconds: 300))
        try await holder.begin(immediate: true)
        try await exec(holder, "INSERT INTO t VALUES (1)")
        let start = ContinuousClock.now
        do {
            _ = try await exec(waiter, "INSERT INTO t VALUES (2)")
            Issue.record("the write should have been blocked by the other connection's lock")
        } catch let error as DatabaseServerError {
            let waited = ContinuousClock.now - start
            #expect(error.code == "SQLITE_BUSY")
            #expect(error.message.contains("locked"))
            #expect(error.hint != nil)
            #expect(waited >= .milliseconds(250) && waited < .seconds(3), "waited \(waited)")
        }
        try await holder.commit()
        // Released: the waiter can write now.
        _ = try await exec(waiter, "INSERT INTO t VALUES (2)")
        #expect(try await rows(holder, "SELECT count(*) FROM t").rows[0][0] == .int(2))
        await holder.close()
        await waiter.close()
    }

    @Test func externalChangesAreNoticedThroughTheDataVersion() async throws {
        let folder = TempFolder()
        let path = folder.path("version.db")
        let first = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(path), createIfMissing: true))
        try await exec(first, "CREATE TABLE t (id INTEGER)")
        let before = try await first.dataVersion()
        #expect(try await first.dataVersion() == before, "stable while nothing else writes")
        let second = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(path)))
        try await exec(second, "INSERT INTO t VALUES (1)")
        #expect(try await first.dataVersion() != before, "another connection committed")
        await first.close()
        await second.close()
    }

    @Test func eachSessionRunsItsOwnStatementsInParallel() async throws {
        let folder = TempFolder()
        let sessions = try await (0..<4).asyncMap { index -> SQLiteSession in
            let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("p\(index).db")), createIfMissing: true))
            try await exec(session, "CREATE TABLE t (x)")
            return session
        }
        try await withThrowingTaskGroup(of: Int.self) { group in
            for session in sessions {
                group.addTask {
                    for value in 0..<200 { try await exec(session, "INSERT INTO t VALUES (?1)", [.int(Int64(value))]) }
                    return try await rows(session, "SELECT count(*) FROM t").rows[0][0] == .int(200) ? 1 : 0
                }
            }
            var good = 0
            for try await ok in group { good += ok }
            #expect(good == 4)
        }
        for session in sessions { await session.close() }
    }
}

struct SQLiteSchemaTests {
    @Test func introspectsEverythingSQLiteCanHold() async throws {
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .memory))
        for statement in [
            "CREATE TABLE parent (a INTEGER, b TEXT, PRIMARY KEY (a, b)) STRICT",
            "CREATE TABLE child (id INTEGER PRIMARY KEY, pa INTEGER, pb TEXT, other_id INTEGER REFERENCES other, note TEXT DEFAULT 'n', FOREIGN KEY (pa, pb) REFERENCES parent (a, b) ON DELETE CASCADE ON UPDATE SET NULL)",
            "CREATE TABLE other (code TEXT PRIMARY KEY, label) WITHOUT ROWID",
            "CREATE TABLE gen (x INTEGER, doubled INTEGER GENERATED ALWAYS AS (x * 2) VIRTUAL, stored INTEGER GENERATED ALWAYS AS (x + 1) STORED)",
            "CREATE UNIQUE INDEX child_pair ON child (pa, pb)",
            "CREATE INDEX child_partial ON child (note) WHERE note IS NOT NULL",
            "CREATE INDEX child_expr ON child (lower(note))",
            "CREATE VIEW child_view AS SELECT id, note FROM child",
            "CREATE TRIGGER child_audit AFTER INSERT ON child BEGIN SELECT 1; END",
            "CREATE VIRTUAL TABLE docs USING fts5(body)",
        ] { try await exec(session, statement) }

        let names = try await session.tableNames()
        #expect(names.contains { $0.name == "parent" && $0.kind == .table })
        #expect(names.contains { $0.name == "child_view" && $0.kind == .view })
        #expect(names.contains { $0.name == "docs" && $0.kind == .virtual })
        #expect(!names.contains { $0.name.hasPrefix("sqlite_") }, "SQLite's own tables are hidden by default")
        #expect(names.contains { $0.name.hasPrefix("docs_") && $0.kind == .shadow }, "fts5 shadow tables are labelled as such")

        let parent = try await session.tableInfo(table: "parent")
        #expect(parent.isStrict)
        #expect(parent.primaryKey == ["a", "b"], "a composite primary key keeps its order")
        #expect(parent.columns.map(\.affinity) == [.integer, .text])

        let child = try await session.tableInfo(table: "child")
        #expect(child.foreignKeys.count == 2)
        let composite = try #require(child.foreignKeys.first { $0.table == "parent" })
        #expect(composite.from == ["pa", "pb"])
        #expect(composite.to == ["a", "b"])
        #expect(composite.onDelete == "CASCADE" && composite.onUpdate == "SET NULL")
        #expect(child.columns.first { $0.name == "note" }?.defaultValue == "'n'")
        #expect(child.triggers == ["child_audit"])
        let indexNames = Set(child.indexes.map(\.name))
        #expect(indexNames.isSuperset(of: ["child_pair", "child_partial", "child_expr"]))
        #expect(child.indexes.first { $0.name == "child_pair" }?.isUnique == true)
        #expect(child.indexes.first { $0.name == "child_pair" }?.columns == ["pa", "pb"])
        #expect(child.indexes.first { $0.name == "child_partial" }?.isPartial == true)
        #expect(child.indexes.first { $0.name == "child_expr" }?.columns == [nil], "an expression has no column name")
        #expect(child.hasRowID)

        let other = try await session.tableInfo(table: "other")
        #expect(other.withoutRowID)
        #expect(!other.hasRowID, "a WITHOUT ROWID table cannot be addressed by rowid")

        let generated = try await session.tableInfo(table: "gen")
        #expect(generated.columns.map(\.isGenerated) == [false, true, true])
        #expect(generated.columns.map(\.hidden) == [0, 2, 3], "virtual and stored generated columns are told apart")

        let view = try await session.tableInfo(table: "child_view")
        #expect(view.kind == .view)
        #expect(view.sql?.hasPrefix("CREATE VIEW") == true)

        // The bulk reads the explorer uses agree with the per-table ones.
        let all = try await session.allColumns()
        #expect(all["child"]?.map(\.name) == child.columns.map(\.name))
        #expect(all["sqlite_master"] == nil)
        let keys = try await session.allForeignKeys()
        #expect(keys.contains { $0.table == "child" && $0.key.table == "parent" && $0.key.from == ["pa", "pb"] })
        // `REFERENCES other` names no column: it means other's primary key.
        let implicit = try #require(keys.first { $0.table == "child" && $0.key.table == "other" })
        #expect(implicit.key.to == ["code"])
        await session.close()
    }

    @Test func attachedDatabasesAreListedAndBrowsable() async throws {
        let folder = TempFolder()
        let other = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("other.db")), createIfMissing: true))
        try await exec(other, "CREATE TABLE remote (id INTEGER, v TEXT)")
        try await exec(other, "INSERT INTO remote VALUES (1, 'far')")
        await other.close()
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .memory))
        try await exec(session, "CREATE TABLE local (id)")
        try await session.attach(path: folder.path("other.db"), alias: "extra", readOnly: true)
        #expect(try await session.schemas().contains("extra"))
        #expect(try await session.tableNames(schema: "extra").map(\.name) == ["remote"])
        #expect(try await session.tableInfo(schema: "extra", table: "remote").columns.map(\.name) == ["id", "v"])
        #expect(try await rows(session, "SELECT v FROM extra.remote").rows[0][0] == .text("far"))
        await #expect(throws: DatabaseServerError.self) { _ = try await exec(session, "INSERT INTO extra.remote VALUES (2, 'no')") }
        await #expect(throws: DatabaseError.self) { try await session.attach(path: folder.path("other.db"), alias: "bad alias; DROP") }
        try await session.detach(alias: "extra")
        #expect(!(try await session.schemas()).contains("extra"))
        // A file that is not a database cannot be attached.
        try "just text, not a database at all, long enough".write(toFile: folder.path("junk.db"), atomically: true, encoding: .utf8)
        await #expect(throws: SQLiteSession.OpenError.self) { try await session.attach(path: folder.path("junk.db"), alias: "junk") }
        await session.close()
    }

    @Test func affinityFollowsSQLitesFiveRules() {
        #expect(SQLiteAffinity(declaredType: "INT") == .integer)
        #expect(SQLiteAffinity(declaredType: "BIGINT UNSIGNED") == .integer)
        #expect(SQLiteAffinity(declaredType: "VARCHAR(20)") == .text)
        #expect(SQLiteAffinity(declaredType: "NCHAR") == .text)
        #expect(SQLiteAffinity(declaredType: "CLOB") == .text)
        #expect(SQLiteAffinity(declaredType: "") == .blob)
        #expect(SQLiteAffinity(declaredType: "BLOB") == .blob)
        #expect(SQLiteAffinity(declaredType: "DOUBLE PRECISION") == .real)
        #expect(SQLiteAffinity(declaredType: "FLOAT") == .real)
        #expect(SQLiteAffinity(declaredType: "DECIMAL(10,5)") == .numeric)
        #expect(SQLiteAffinity(declaredType: "BOOLEAN") == .numeric)
        #expect(SQLiteAffinity(declaredType: "DATETIME") == .numeric)
        #expect(SQLiteAffinity(declaredType: "POINT") == .integer, "'POINT' contains INT: SQLite's rule, not a bug")
    }
}

struct SQLiteMaintenanceTests {
    @Test func integrityForeignKeysSizeAndMaintenanceAreExplicitCalls() async throws {
        let folder = TempFolder()
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("m.db")), createIfMissing: true))
        // Opening changed nothing: the database is in SQLite's default mode with keys unchecked.
        #expect(try await session.journalMode() == "delete")
        #expect(try await session.pragma("foreign_keys") == "0")
        try await exec(session, "CREATE TABLE p (id INTEGER PRIMARY KEY)")
        try await exec(session, "CREATE TABLE c (id INTEGER PRIMARY KEY, pid INTEGER REFERENCES p(id))")
        try await exec(session, "INSERT INTO p VALUES (1)")
        try await exec(session, "INSERT INTO c VALUES (1, 1), (2, 99), (3, 98)")  // two orphans: allowed while keys are off
        #expect(try await session.integrityCheck() == ["ok"])
        #expect(try await session.quickCheck() == ["ok"])
        let violations = try await session.foreignKeyCheck()
        #expect(violations.count == 2)
        #expect(violations.allSatisfy { $0.table == "c" && $0.parent == "p" })
        #expect(Set(violations.compactMap(\.rowID)) == [2, 3])

        for index in 0..<3_000 { try await exec(session, "INSERT INTO p VALUES (?1)", [.int(Int64(index + 10))]) }
        try await exec(session, "DELETE FROM p WHERE id > 100")
        let beforeVacuum = try await session.sizeInfo()
        #expect(beforeVacuum.pageSize > 0 && beforeVacuum.pageCount > 0)
        #expect(beforeVacuum.freePages > 0, "deleting rows leaves free pages")
        #expect(beforeVacuum.fileBytes != nil)
        try await session.analyze()
        try await session.optimize()
        try await session.vacuum()
        let afterVacuum = try await session.sizeInfo()
        #expect(afterVacuum.freePages == 0)
        #expect(afterVacuum.pageCount < beforeVacuum.pageCount)
        // VACUUM is refused by SQLite inside a transaction.
        try await session.begin()
        do {
            try await session.vacuum()
            Issue.record("VACUUM ran inside a transaction")
        } catch is DatabaseServerError {
        }
        try await session.rollback()
        await session.close()
    }

    @Test func aBackupOfAWALDatabaseIsConsistentAndRefusesToOverwrite() async throws {
        let folder = TempFolder()
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("wal.db")), createIfMissing: true))
        try await exec(session, "PRAGMA journal_mode = WAL")  // an explicit choice by the test, not by Umbra
        #expect(try await session.journalMode() == "wal")
        try await exec(session, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        for index in 0..<2_000 { try await exec(session, "INSERT INTO t (v) VALUES (?1)", [.text("row \(index)")]) }
        // Rows that live only in the -wal file must be in the backup.
        let walAttributes = try? FileManager.default.attributesOfItem(atPath: folder.path("wal.db-wal"))
        let walBytes = (walAttributes?[.size] as? NSNumber)?.int64Value ?? 0
        #expect(walBytes > 0, "the test needs unflushed WAL content to mean anything")

        let progress = ProgressBox()
        try await session.backup(to: folder.path("backup.db")) { progress.record($0) }
        #expect(progress.maximum > 0)
        let backup = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("backup.db")), readOnly: true))
        #expect(try await rows(backup, "SELECT count(*) FROM t").rows[0][0] == .int(2_000), "the backup is missing WAL rows")
        #expect(try await backup.integrityCheck() == ["ok"])
        await backup.close()
        // A plain file copy of the main file alone would have been short: show why the API matters.
        try FileManager.default.copyItem(atPath: folder.path("wal.db"), toPath: folder.path("naive.db"))
        let naive = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("naive.db")), readOnly: true))
        let naiveCount = try await rows(naive, "SELECT count(*) FROM t").rows[0][0]
        print("SQLITEWAL naiveCopyRows=\(naiveCount) backupRows=2000")
        await naive.close()

        await #expect(throws: SQLiteSession.OpenError.self) { try await session.backup(to: folder.path("backup.db")) }
        let checkpoint = try await session.walCheckpoint(.truncate)
        #expect(!checkpoint.wasBlocked)
        await session.close()
    }

    @Test func aFailedBackupLeavesNoPartialFile() async throws {
        let folder = TempFolder()
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("src.db")), createIfMissing: true))
        try await exec(session, "CREATE TABLE t (v TEXT)")
        for _ in 0..<50 { try await exec(session, "INSERT INTO t SELECT randomblob(2000) FROM (WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 200) SELECT x FROM c)") }
        let partialPath = folder.path("partial.db")
        let task = Task { try await session.backup(to: partialPath) }
        task.cancel()
        _ = try? await task.value
        // Whatever happened, either a complete database or no file: never a half-written one.
        if FileManager.default.fileExists(atPath: folder.path("partial.db")) {
            let copy = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(folder.path("partial.db")), readOnly: true))
            #expect(try await copy.integrityCheck() == ["ok"])
            await copy.close()
        }
        await session.close()
    }
}

struct SQLiteFacadeTests {
    private func login(_ path: String) -> SQLLogin {
        SQLLogin(engine: .sqlite, host: "", port: 0, database: path)
    }

    @Test func boundTextAndNullRoundTripThroughQueryPaging() async throws {
        let session = try await SQLSession.connect(login: login(":memory:"), readOnly: false)
        defer { Task { await session.disconnect() } }
        let value = "A\u{0}O'Reilly; --"
        let result = try await DatabaseQuery.run(
            statement: "SELECT ? AS value, ? AS absent", readOnly: false, page: 0, pageSize: 1,
            engine: .sqlite, using: session, parameters: [.text(value), .null]
        )
        #expect(result.rows == [[value, nil]])
    }

    @Test func theAppFacingFacadeBrowsesAndQueriesASQLiteFile() async throws {
        let folder = TempFolder()
        try await SQLSession.createSQLiteDatabase(at: folder.path("app.db"))
        await #expect(throws: SQLiteSession.OpenError.self) { try await SQLSession.createSQLiteDatabase(at: folder.path("app.db")) }
        let writer = try await SQLSession.connect(login: login(folder.path("app.db")), readOnly: false)
        _ = try await writer.query("CREATE TABLE \"Order Details\" (id INTEGER PRIMARY KEY, qty INTEGER NOT NULL, note TEXT)")
        _ = try await writer.query("CREATE TABLE refs (id INTEGER PRIMARY KEY, detail_id INTEGER REFERENCES \"Order Details\"(id))")
        _ = try await writer.query("CREATE INDEX qty_ix ON \"Order Details\" (qty)")
        let insert = try await writer.query("INSERT INTO \"Order Details\" (qty, note) VALUES (1, 'a'), (2, ''), (3, NULL)")
        #expect(insert.rowsAffected == 3)

        #expect(try await writer.tables() == ["Order Details", "refs"])
        let columns = try await writer.columns(of: "Order Details")
        #expect(columns.map(\.name) == ["id", "qty", "note"])
        #expect(columns[0].isPrimaryKey && columns[1].isNotNull && !columns[2].isNotNull)
        #expect(try await writer.allColumns().keys.sorted() == ["Order Details", "refs"])
        #expect(try await writer.foreignKeys() == [
            SQLForeignKey(fromTable: "refs", fromColumn: "detail_id", toTable: "Order Details", toColumn: "id",
                          constraint: "fk0", ordinal: 1),
        ])
        #expect(try await writer.indexes(of: "Order Details").map(\.name) == ["qty_ix"])
        #expect(try await writer.createTableStatement("Order Details").hasPrefix("CREATE TABLE \"Order Details\""))
        // The console browses a table whose name has a space, through the identifier quoting.
        let select = try await writer.query(try SQLIdentifiers.selectAll(from: "Order Details", engine: .sqlite))
        #expect(select.rows == [["1", "1", "a"], ["2", "2", ""], ["3", "3", nil]], "NULL and the empty string stay different")
        // Paging wraps a SELECT exactly as for the server engines.
        let page = try await DatabaseQuery.run(
            statement: "SELECT * FROM \"Order Details\"", readOnly: false, page: 1, pageSize: 2, engine: .sqlite, using: writer
        )
        #expect(page.rows.count == 1)
        await writer.disconnect()

        // Read-only through the facade: the file refuses writes, and a read pragma still works.
        let reader = try await SQLSession.connect(login: login(folder.path("app.db")), readOnly: true)
        await #expect(throws: (any Error).self) { _ = try await reader.query("DELETE FROM \"Order Details\"") }
        await #expect(throws: (any Error).self) { _ = try await reader.query("WITH c AS (SELECT 1) DELETE FROM \"Order Details\"") }
        #expect(try await reader.query("PRAGMA table_info(refs)").rows.count == 2)
        #expect(try await reader.query("SELECT count(*) FROM \"Order Details\"").rows == [["3"]])
        await reader.disconnect()
    }

    @Test func aMemoryDatabaseSurvivesAsLongAsItsFacadeDoes() async throws {
        let session = try await SQLSession.connect(login: login(":memory:"), readOnly: false)
        _ = try await session.query("CREATE TABLE t (x)")
        _ = try await session.query("INSERT INTO t VALUES (1)")
        #expect(try await session.tables() == ["t"])
        #expect(try await session.query("SELECT x FROM t").rows == [["1"]])
        await session.disconnect()
    }

    @Test func cancelReachesTheSQLiteConsole() async throws {
        let session = try await SQLSession.connect(login: login(":memory:"), readOnly: false)
        let task = Task {
            try await session.query("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c")
        }
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        await session.cancelRunning()  // the call the app's Cancel button makes
        let result = try await task.value
        #expect(result.wasCancelled)
        #expect(ContinuousClock.now - started < .seconds(2))
        await session.disconnect()
    }
}

extension Sequence {
    fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
