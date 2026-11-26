import DatabaseKit
import XCTest
@testable import Umbra

@MainActor
final class IDEDatabaseConsoleScopeTests: XCTestCase {
    func testPostgresScopeSwitchProtectsTransactionsAndOldResultReruns() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_DB_INTEGRATION"] == "1")
        let url = try XCTUnwrap(ProcessInfo.processInfo.environment["UMBRA_TEST_PG_URL"])
        let draft = try DatabaseURL.parse(url)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = IDEDatabaseCatalog(storeURL: folder.appendingPathComponent("connections.json"))
        let source = draft.connection
        catalog.upsert(source)
        let keychain = IDEDatabaseMemoryKeyStore()
        try keychain.save(draft.password, account: source.id.uuidString)
        let support = IDEDatabaseSupport(catalog: catalog, keychain: keychain)
        defer { support.closeAll() }
        try await support.connect(source.id)
        let binding = IDEDatabaseConsoleBinding(connectionID: source.id)
        let original = try XCTUnwrap(support.sqlSession(for: source.id))
        let schema = "phase4_app_\(UUID().uuidString.prefix(8))"
        let quoted = try SQLIdentifiers.quote(schema, engine: .postgres)
        let setup = try await SQLSession.connect(login: source.sqlLogin(password: draft.password), readOnly: false)
        defer { Task {
            _ = try? await setup.query("DROP SCHEMA IF EXISTS \(quoted) CASCADE")
            await setup.disconnect()
        } }
        _ = try await setup.query("CREATE SCHEMA \(quoted)")
        _ = try await setup.query("CREATE TABLE \(quoted).scope_item (id integer)")
        _ = try await setup.query("INSERT INTO \(quoted).scope_item VALUES (17)")
        let schemas = try await support.sqlScopeChoices(connectionID: source.id, schemas: true)
        XCTAssertTrue(schemas.contains(schema))

        await support.execute(statement: "BEGIN", binding: binding, resetSort: true)
        do {
            try await support.switchSQLScope(connectionID: source.id, schema: schema)
            XCTFail("Switching would have discarded the transaction")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Finish the transaction"))
        }
        XCTAssertTrue(support.sqlSession(for: source.id) === original)

        await support.execute(statements: ["ROLLBACK", "SELECT 3 AS id"], binding: binding)
        let previous = try XCTUnwrap(support.result.storage)
        try await support.switchSQLScope(connectionID: source.id, schema: schema)
        XCTAssertEqual(support.displayedSQLScope(source).schema, schema)
        await support.sort(by: "id")
        XCTAssertEqual(support.result.storage, previous)
        await support.execute(statement: "SELECT id FROM scope_item", binding: binding, resetSort: true)
        XCTAssertEqual(support.result.rows, [["17"]])
    }
}
