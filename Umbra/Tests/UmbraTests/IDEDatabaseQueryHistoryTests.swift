import DatabaseKit
import XCTest
@testable import Umbra

@MainActor
final class IDEDatabaseQueryHistoryTests: XCTestCase {
    func testRedactsLiteralsCommentsParametersAndMongoFilters() throws {
        let postgres = "SELECT 'secretLiteral', $$secretDollar$$, 928170, :privateLabel, \"sensitive identifier\" -- private comment"
        let preview = IDEDatabaseQueryHistory.preview(postgres, engine: .postgres)
        XCTAssertEqual(preview, "SELECT ? , ? , ? , ? , ?")
        XCTAssertEqual(IDEDatabaseQueryHistory.preview("ALTER USER test PASSWORD 'private'", engine: .postgres), "ALTER · sensitive statement")
        XCTAssertEqual(IDEDatabaseQueryHistory.preview("{\"secret\":\"hidden\"}", engine: .mongo), "MongoDB filter")
        XCTAssertFalse(IDEDatabaseQueryHistory.preview("SELECT 'part\\\\private'", engine: .mysql).contains("private"))
    }

    func testHistoryIsBoundedAndReloadsOnlyRedactedValues() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let source = UUID()
        let history = IDEDatabaseQueryHistory(url: url)
        let attempts = (0..<110).map { index in
            IDEDatabaseQueryHistory.Attempt(statement: "SELECT 'never-on-disk' FROM table_\(index)",
                                            status: .completed, duration: .milliseconds(index))
        }
        await history.record(attempts, source: source, engine: .sqlite)
        let disk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(disk.contains("never-on-disk"))
        let reopened = IDEDatabaseQueryHistory(url: url)
        let entries = await reopened.entries(source: source)
        XCTAssertEqual(entries.count, 100)
        XCTAssertEqual(entries.first?.preview, "SELECT ? FROM table_109")
        XCTAssertEqual(entries.last?.preview, "SELECT ? FROM table_10")
        let other = await reopened.entries(source: UUID())
        XCTAssertTrue(other.isEmpty)
    }

    func testExecutionRecordsTheOutcomeWithoutParametersOrServerErrors() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = IDEDatabaseCatalog(storeURL: folder.appendingPathComponent("connections.json"))
        let source = DatabaseConnection(engine: .sqlite, database: ":memory:")
        catalog.upsert(source)
        let support = IDEDatabaseSupport(catalog: catalog, keychain: IDEDatabaseMemoryKeyStore())
        defer { support.closeAll() }
        let binding = IDEDatabaseConsoleBinding(connectionID: source.id)
        await support.execute(preparedStatements: [.init("SELECT ?", parameters: [.text("private parameter")])], binding: binding)
        XCTAssertEqual(support.result.rows, [["private parameter"]])
        await support.execute(statement: "SELECT * FROM missing_table WHERE id = 42", binding: binding, resetSort: true)
        XCTAssertNotNil(support.result.error)
        let entries = await catalog.history.entries(source: source.id)
        XCTAssertEqual(entries.map(\.status), [.failed, .completed])
        XCTAssertEqual(entries.map(\.preview), ["SELECT * FROM missing_table WHERE id = ?", "SELECT ?"])
    }
}
