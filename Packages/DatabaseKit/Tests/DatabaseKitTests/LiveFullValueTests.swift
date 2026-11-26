import Foundation
import Testing

@testable import DatabaseKit

private let liveEnabled = ProcessInfo.processInfo.environment["UMBRA_DB_INTEGRATION"] == "1"

/// A grid keeps a bounded preview of a large value. The inspector fetches the rest by the row's
/// verified key, on the same server, with the bound lifted for that one statement only.
@Suite(.enabled(if: liveEnabled, "needs UMBRA_DB_INTEGRATION=1 and Scripts/db-test-env.sh up"), .serialized)
struct LiveFullValueTests {
    private func connect(_ variable: String) async throws -> SQLSession {
        guard let url = ProcessInfo.processInfo.environment[variable] else {
            throw DatabaseError.executionFailed("\(variable) is not set; run Scripts/db-test-env.sh env")
        }
        var login = try SQLURLs.parse(url)
        if login.engine == .mysql { login.useTLS = false; login.requireTLS = false }
        return try await SQLSession.connect(login: login, readOnly: false)
    }

    private func read(_ session: SQLSession, _ sql: String) async throws -> (columns: [ResultColumn], rows: [[DatabaseValue]]) {
        let store = ResultStore(columns: [])
        defer { Task { await store.close() } }
        let summary = try await session.execute(sql, parameters: [], into: store)
        return (summary.columns, try await store.rows(in: 0..<store.rowCount))
    }

    @Test func postgresFetchesTheWholeValueByKeyAndTheGridKeepsItsPreview() async throws {
        let session = try await connect("UMBRA_TEST_PG_URL")
        defer { Task { await session.disconnect() } }
        _ = try await session.query("DROP TABLE IF EXISTS full_pg")
        _ = try await session.query("CREATE TABLE full_pg (id int PRIMARY KEY, body text, blob bytea)")
        _ = try await session.query("INSERT INTO full_pg SELECT 1, repeat('x', 200000), decode(repeat('ab', 100000), 'hex')")
        defer { Task { _ = try? await session.query("DROP TABLE IF EXISTS full_pg") } }

        let (columns, rows) = try await read(session, "SELECT id, body, blob FROM full_pg")
        guard case .truncated(_, let count) = rows[0][1] else { Issue.record("expected a preview, got \(rows[0][1])"); return }
        #expect(count == 200_000)
        guard case .bytes(let length, let prefix) = rows[0][2] else { Issue.record("expected bytes"); return }
        #expect(length == 100_000 && prefix.count < length)
        guard case .editable(let target) = await session.resolveEditTarget(columns: columns) else { Issue.record("no target"); return }

        let key = [SQLiteOptimisticUpdate.Key(column: "id", value: rows[0][0])]
        let body = try await session.fetchFullValue(column: "body", keys: key, target: target)
        #expect(body == .text(String(repeating: "x", count: 200_000)))
        let blob = try await session.fetchFullValue(column: "blob", keys: key, target: target)
        guard case .bytes(let fullLength, let fullPrefix) = blob else { Issue.record("expected bytes"); return }
        #expect(fullLength == 100_000 && fullPrefix.count == 100_000 && fullPrefix.allSatisfy { $0 == 0xAB })

        // A later ordinary query is back on the standard bound: the override was task-scoped.
        let again = try await read(session, "SELECT body FROM full_pg")
        if case .truncated = again.rows[0][0] {} else { Issue.record("the limit override leaked into a later statement") }

        // A row that is gone is an error, never another row's value.
        _ = try await session.query("DELETE FROM full_pg")
        await #expect(throws: DatabaseError.self) { _ = try await session.fetchFullValue(column: "body", keys: key, target: target) }
        await #expect(throws: DatabaseError.self) { _ = try await session.fetchFullValue(column: "ghost", keys: key, target: target) }
    }

    @Test func mysqlFetchesTheWholeValueByKey() async throws {
        let session = try await connect("UMBRA_TEST_MYSQL_URL")
        defer { Task { await session.disconnect() } }
        _ = try await session.query("DROP TABLE IF EXISTS full_my")
        _ = try await session.query("CREATE TABLE full_my (id int PRIMARY KEY, body longtext, blob_data longblob)")
        _ = try await session.query("INSERT INTO full_my VALUES (1, REPEAT('y', 200000), UNHEX(REPEAT('cd', 100000)))")
        defer { Task { _ = try? await session.query("DROP TABLE IF EXISTS full_my") } }

        let (columns, rows) = try await read(session, "SELECT id, body, blob_data FROM full_my")
        guard case .truncated(_, let count) = rows[0][1] else { Issue.record("expected a preview, got \(rows[0][1])"); return }
        #expect(count == 200_000)
        guard case .editable(let target) = await session.resolveEditTarget(columns: columns) else { Issue.record("no target"); return }
        let key = [SQLiteOptimisticUpdate.Key(column: "id", value: rows[0][0])]
        #expect(try await session.fetchFullValue(column: "body", keys: key, target: target) == .text(String(repeating: "y", count: 200_000)))
        guard case .bytes(let length, let prefix) = try await session.fetchFullValue(column: "blob_data", keys: key, target: target) else {
            Issue.record("expected bytes")
            return
        }
        #expect(length == 100_000 && prefix.count == 100_000 && prefix.allSatisfy { $0 == 0xCD })
        let after = try await read(session, "SELECT body FROM full_my")
        if case .truncated = after.rows[0][0] {} else { Issue.record("the limit override leaked into a later statement") }
    }

    @Test func mongoFetchesTheWholeFieldByExactID() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["UMBRA_TEST_MONGO_URL"])
        let session = try await MongoSession.connect(login: MongoURLs.parse(url), readOnly: false)
        defer { Task { await session.disconnect() } }
        let database = "umbra_full_value"
        try await session.console.dropCollection(database: database, collection: "docs")
        _ = try await session.console.insertOne(database: database, collection: "docs", document: BSONDocument([
            "_id": .string("k"), "body": .string(String(repeating: "z", count: 200_000)),
        ]))
        defer { Task { try? await session.console.dropCollection(database: database, collection: "docs") } }

        let stored = try await session.console.findDocuments(
            MongoFindRequest(database: database, collection: "docs", filter: BSONDocument(), limit: 1), limit: 1)
        guard case .truncated = MongoTable.typedCell(try #require(stored.first?["body"])) else {
            Issue.record("the grid cell should be a preview")
            return
        }
        let full = try await session.fetchFullValue(database: database, collection: "docs", id: .text("k"), field: "body")
        #expect(full == .text(String(repeating: "z", count: 200_000)))
        #expect(try await session.fetchFullValue(database: database, collection: "docs", id: .text("k"), field: "absent") == .missing)
        await #expect(throws: DatabaseError.self) {
            _ = try await session.fetchFullValue(database: database, collection: "docs", id: .text("gone"), field: "body")
        }
    }
}
