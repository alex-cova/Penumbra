import DatabaseKit
import XCTest
@testable import Umbra

@MainActor
final class IDEDatabaseTests: XCTestCase {
    func testConnectionFileRoundTripsWithoutThePassword() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-database-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = IDEDatabaseCatalog(storeURL: directory.appendingPathComponent("database-connections.json"))
        let secret = "s3cret-db"
        var connection = DatabaseConnection(
            name: "shop", engine: .postgres, host: "db.example.com", port: 5432,
            username: "ada", database: "shop", useTLS: true
        )
        catalog.upsert(connection)
        connection.lastStatement = "SELECT 1"
        catalog.updateLastStatement(id: connection.id, connection.lastStatement)

        let data = try Data(contentsOf: catalog.storeURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("password"))
        let loaded = IDEDatabaseCatalog(storeURL: catalog.storeURL)
        let stored = try XCTUnwrap(loaded.connection(id: connection.id))
        XCTAssertEqual(stored.host, "db.example.com")
        XCTAssertEqual(stored.username, "ada")
        XCTAssertEqual(stored.database, "shop")
        XCTAssertEqual(stored.engine, .postgres)
        XCTAssertTrue(stored.useTLS)
        XCTAssertEqual(stored.lastStatement, "SELECT 1")
    }

    func testMemoryKeychainSaveLoadAndEmptyDelete() throws {
        let store = IDEDatabaseMemoryKeyStore()
        XCTAssertNil(try store.load(account: "connection"))
        try store.save("pw", account: "connection")
        XCTAssertEqual(try store.load(account: "connection"), "pw")
        try store.save("", account: "connection")
        XCTAssertNil(try store.load(account: "connection"), "An empty password removes the item")
        try store.save("pw", account: "connection")
        try store.delete(account: "connection")
        XCTAssertNil(try store.load(account: "connection"))
    }

    func testTheDatabaseToolIsRegistered() {
        IDEWorkspace.isSessionPersistenceEnabled = false
        XCTAssertNotNil(IDELanguageModules.module(id: IDEDatabaseModule.id))
        XCTAssertEqual(IDESidebarTabs.descriptor(for: .database)?.title, "Database")
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        XCTAssertTrue(workspace.sidebarTabs.contains(.database))
        XCTAssertFalse(workspace.databaseSupport.showsResultsTab)
        XCTAssertFalse(workspace.languageModuleBottomTabs().contains { $0.tab == .databaseResults })
        workspace.databaseSupport.showsResultsTab = true
        let tabs = workspace.languageModuleBottomTabs()
        XCTAssertTrue(tabs.contains { $0.tab == .databaseResults })
        XCTAssertEqual(tabs.first { $0.tab == .databaseResults }?.order, IDEBottomPanelTab.Order.databaseResults)
        _ = tabs.first { $0.tab == .databaseResults }?.content(workspace)
        XCTAssertTrue(workspace.languageModuleToolWindows().contains { $0.id == "databaseResults" })
        let commands = IDEDatabaseModule().commands(for: workspace).map(\.id)
        XCTAssertEqual(commands, ["app.database.newDataSource", "app.database.newQuery", "app.database.execute"])
    }

    func testNewConsoleFallsBackToTheFirstDataSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-database-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = IDEDatabaseCatalog(storeURL: directory.appendingPathComponent("database-connections.json"))
        let support = IDEDatabaseSupport(catalog: catalog, keychain: IDEDatabaseMemoryKeyStore())
        XCTAssertNil(support.connectionForNewConsole(), "No data source, no console target")

        let first = DatabaseConnection(name: "first", engine: .postgres)
        let second = DatabaseConnection(name: "second", engine: .postgres)
        catalog.upsert(first)
        catalog.upsert(second)

        // A fresh window has configured data sources but no selection yet.
        XCTAssertEqual(support.connectionForNewConsole()?.id, first.id)
        support.selectedConnectionID = UUID()
        XCTAssertEqual(
            support.connectionForNewConsole()?.id, first.id,
            "A stale selection falls back instead of leaving the console with nothing to bind"
        )
        support.selectedConnectionID = second.id
        XCTAssertEqual(support.connectionForNewConsole()?.id, second.id)
    }

    func testNewQueryConsoleFromWelcomeBindsTheFirstDataSource() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        // An editor view needs the adapter that `bootstrap()` wires, which the window
        // runs when it appears.
        workspace.bootstrap()
        guard let first = workspace.databaseSupport.catalog.connections.first else {
            throw XCTSkip("Requires at least one configured data source")
        }
        XCTAssertFalse(workspace.hasOpenProject)
        XCTAssertFalse(workspace.hasOpenDocuments)
        // A fresh window has configured data sources but no selection yet.
        workspace.databaseSupport.selectedConnectionID = nil
        workspace.openDatabaseQueryConsole()
        XCTAssertTrue(
            workspace.hasOpenDocuments,
            "The console opens as a document even with no project open"
        )
        XCTAssertEqual(workspace.databaseSupport.selectedConnectionID, first.id)
        XCTAssertEqual(workspace.databaseSupport.consoles.values.first?.connectionID, first.id)
    }

    func testNewQueryConsoleWithoutDataSourcesOpensTheConnectionSheet() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let workspace = IDEWorkspace()
        defer { workspace.teardown() }
        // An editor view needs the adapter that `bootstrap()` wires, which the window
        // runs when it appears.
        workspace.bootstrap()
        try XCTSkipUnless(
            workspace.databaseSupport.catalog.connections.isEmpty,
            "Requires no configured data sources"
        )
        XCTAssertFalse(workspace.hasOpenProject)
        XCTAssertFalse(workspace.hasOpenDocuments)
        workspace.openDatabaseQueryConsole()
        XCTAssertNotNil(
            workspace.databaseSupport.editor,
            "With no data source the console offers to create one instead of doing nothing"
        )
    }

    func testExecuteFillsResultsAndRefusesWritesWhenReadOnly() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-database-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = IDEDatabaseCatalog(storeURL: directory.appendingPathComponent("database-connections.json"))
        let support = IDEDatabaseSupport(catalog: catalog, keychain: IDEDatabaseMemoryKeyStore())
        var connection = DatabaseConnection(name: "local", engine: .postgres, readOnly: false)
        catalog.upsert(connection)
        let fake = RecordingSQL()
        support.installSQLSessionForTesting(fake, id: connection.id)
        let binding = IDEDatabaseConsoleBinding(connectionID: connection.id, mongoDatabase: nil, mongoCollection: nil)

        await support.execute(statement: "SELECT 1", binding: binding, page: 0, resetSort: true)
        XCTAssertEqual(support.result.columns, ["n"])
        XCTAssertEqual(support.result.rows, [["1"]])
        XCTAssertNil(support.result.error)
        XCTAssertEqual(catalog.connection(id: connection.id)?.lastStatement, "SELECT 1")
        XCTAssertEqual(fake.statements.count, 1)
        XCTAssertTrue(fake.statements[0].contains("LIMIT 200"))

        connection.readOnly = true
        catalog.upsert(connection)
        await support.execute(statement: "DELETE FROM users", binding: binding, page: 0, resetSort: true)
        XCTAssertEqual(support.result.error, DatabaseError.readOnlyViolation.errorDescription)
        XCTAssertEqual(fake.statements.count, 1, "A refused statement is not sent")
    }
}

private final class RecordingSQL: SQLExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var statements: [String] { lock.withLock { stored } }

    func query(_ sql: String) async throws -> QueryResult {
        lock.withLock { stored.append(sql) }
        return QueryResult(columns: ["n"], rows: [["1"]], rowsAffected: nil, isReadQuery: true)
    }
}
