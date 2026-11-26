import AppKit
import DatabaseKit
import EditorIntelligence
import XCTest
@testable import Umbra

@MainActor
final class IDEDatabaseTests: XCTestCase {
    func testFilteredGridRevealsAndInspectsByOriginalRowNumber() async throws {
        let storage = IDEDatabaseResultStorage()
        try await storage.store.append((0..<10).map { [.int(Int64($0))] })
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let table = NSTableView(frame: scroll.bounds)
        let coordinator = IDEDatabaseResultGrid.Coordinator()
        table.dataSource = coordinator
        table.delegate = coordinator
        scroll.documentView = table
        coordinator.install(table: table, clip: scroll.contentView)
        defer { coordinator.detach() }
        let projection = IDEDatabaseLoadedFilter.Matches(indices: [3, 7], loadedRows: 10, reachedMatchLimit: false)
        var inspected: Int?
        coordinator.update(storage: storage, columns: ["number"], rowCount: 10, canSort: false,
                           onSort: { _ in }, onInspect: { row, _ in inspected = row }, rowProjection: projection)
        XCTAssertEqual(coordinator.numberOfRows(in: table), 2)
        coordinator.reveal(.init(row: 7))
        XCTAssertEqual(table.selectedRow, 1)
        XCTAssertTrue(coordinator.inspectSelectedValue())
        XCTAssertEqual(inspected, 7)
        XCTAssertTrue(coordinator.selectCell(row: 0, column: 1, extend: false))
        XCTAssertTrue(coordinator.inspectSelectedValue())
        XCTAssertEqual(inspected, 3)
        await storage.store.close()
    }
    func testGridViewportLoadsBothScrolledDimensions() async throws {
        let storage = IDEDatabaseResultStorage()
        let columnNames = (0..<40).map { "column_\($0)" }
        for start in stride(from: 0, to: 4_096, by: 256) {
            try await storage.store.append((start..<(start + 256)).map { row in
                columnNames.indices.map { .text("\(row):\($0)") }
            })
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
        let table = NSTableView(frame: scroll.bounds)
        let coordinator = IDEDatabaseResultGrid.Coordinator()
        table.dataSource = coordinator
        table.delegate = coordinator
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        coordinator.install(table: table, clip: scroll.contentView)
        defer { coordinator.detach() }
        coordinator.update(storage: storage, columns: columnNames, rowCount: 4_096, canSort: false,
                           onSort: { _ in XCTFail("Scrolling should use the store") }, onInspect: { _, _ in })
        scroll.layoutSubtreeIfNeeded()

        var times: [Double] = []
        for (row, column) in [(1024, 12), (2048, 28), (3072, 36), (32, 1), (4064, 20), (128, 5), (2400, 16), (600, 32)] {
            let start = ContinuousClock.now
            table.scrollRowToVisible(row)
            table.scrollColumnToVisible(column + 1)
            scroll.reflectScrolledClipView(scroll.contentView)
            let field = table.tableColumns[column + 1]
            let expected = "\(row):\(column)"
            var actual: String?
            repeat {
                actual = (coordinator.tableView(table, viewFor: field, row: row) as? NSTextField)?.stringValue
                if actual == expected { break }
                try await Task.sleep(for: .milliseconds(3))
            } while start.duration(to: .now) < .seconds(3)
            XCTAssertEqual(actual, expected)
            let duration = start.duration(to: .now).components
            times.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
        }
        let sorted = times.sorted()
        print("DATABASE_GRID_VIEWPORT cell-ready ms median=\(sorted[sorted.count / 2]) max=\(sorted.last ?? 0), jumps=\(times.count)")
        await storage.store.close()
    }

    func testGridLoadsADistantVisibleRowFromItsStore() async throws {
        let storage = IDEDatabaseResultStorage()
        try await storage.store.append((0..<500).map { [.int(Int64($0))] })
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        let table = NSTableView(frame: scroll.bounds)
        let coordinator = IDEDatabaseResultGrid.Coordinator()
        table.dataSource = coordinator
        table.delegate = coordinator
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        coordinator.install(table: table, clip: scroll.contentView)
        defer { coordinator.detach() }
        coordinator.update(storage: storage, columns: ["value"], rowCount: 500, canSort: false,
                           onSort: { _ in XCTFail("Scrolling must not sort or rerun") }, onInspect: { _, _ in })
        scroll.layoutSubtreeIfNeeded()
        coordinator.reveal(.init(row: 480))
        XCTAssertEqual(table.selectedRow, 480)
        scroll.reflectScrolledClipView(scroll.contentView)
        let column = try XCTUnwrap(table.tableColumns.first { $0.title == "value" })
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var cell = ""
        repeat {
            cell = (coordinator.tableView(table, viewFor: column, row: 480) as? NSTextField)?.stringValue ?? ""
            if cell == "480" { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(cell, "480")
        await storage.store.close()
    }

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
        XCTAssertEqual(commands, [
            "app.database.newDataSource", "app.database.newQuery", "app.database.execute", "app.database.executeAll",
            "app.database.cancel", "app.database.openSQLite", "app.database.newSQLite",
        ])
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

    /// A catalog in a scratch directory, so these tests never read the data sources saved on
    /// this Mac. Removed when the test ends.
    private func makeIsolatedCatalog() throws -> IDEDatabaseCatalog {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-database-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return IDEDatabaseCatalog(storeURL: directory.appendingPathComponent("database-connections.json"))
    }

    func testNewQueryConsoleFromWelcomeBindsTheFirstDataSource() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let catalog = try makeIsolatedCatalog()
        let first = DatabaseConnection(name: "first", engine: .postgres)
        catalog.upsert(first)
        catalog.upsert(DatabaseConnection(name: "second", engine: .postgres))
        let workspace = IDEWorkspace(
            databaseSupport: IDEDatabaseSupport(catalog: catalog, keychain: IDEDatabaseMemoryKeyStore())
        )
        defer { workspace.teardown() }
        // An editor view needs the adapter that `bootstrap()` wires, which the window
        // runs when it appears.
        workspace.bootstrap()
        XCTAssertEqual(workspace.databaseSupport.catalog.connections.map(\.id).first, first.id)
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
        XCTAssertNil(workspace.databaseSupport.editor, "With a data source there is nothing to create")
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        let session = workspace.makeSession()
        let restored = try JSONDecoder().decode(IDEWindowSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.databaseConsoles?[document.documentID.uuid]?.connectionID, first.id)
    }

    func testNewQueryConsoleWithoutDataSourcesOpensTheConnectionSheet() throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let catalog = try makeIsolatedCatalog()
        let workspace = IDEWorkspace(
            databaseSupport: IDEDatabaseSupport(catalog: catalog, keychain: IDEDatabaseMemoryKeyStore())
        )
        defer { workspace.teardown() }
        // An editor view needs the adapter that `bootstrap()` wires, which the window
        // runs when it appears.
        workspace.bootstrap()
        XCTAssertTrue(workspace.databaseSupport.catalog.connections.isEmpty)
        XCTAssertFalse(workspace.hasOpenProject)
        XCTAssertFalse(workspace.hasOpenDocuments)
        workspace.openDatabaseQueryConsole()
        XCTAssertNotNil(
            workspace.databaseSupport.editor,
            "With no data source the console offers to create one instead of doing nothing"
        )
        XCTAssertFalse(workspace.hasOpenDocuments, "No console opens without a data source")
    }

    /// Under XCTest the window's default catalog is the per-process scratch store, never the
    /// user's Application Support file.
    func testTheDefaultCatalogIsNotTheUsersFileUnderXCTest() throws {
        let directory = try XCTUnwrap(IDESharedServices.testStoreDirectory)
        XCTAssertEqual(
            IDESharedServices.shared.databases.storeURL,
            directory.appendingPathComponent("database-connections.json")
        )
        XCTAssertNotEqual(IDESharedServices.shared.databases.storeURL, IDEDatabaseCatalog.defaultStoreURL)
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

        await support.execute(statement: "SELECT 1", binding: binding, resetSort: true)
        XCTAssertEqual(support.result.columns, ["n"])
        XCTAssertEqual(support.result.rows, [["1"]])
        XCTAssertNil(support.result.error)
        XCTAssertEqual(catalog.connection(id: connection.id)?.lastStatement, "")
        XCTAssertEqual(fake.statements.count, 1)
        XCTAssertEqual(fake.statements[0], "SELECT 1")

        connection.readOnly = true
        catalog.upsert(connection)
        await support.execute(statement: "DELETE FROM users", binding: binding, resetSort: true)
        XCTAssertEqual(support.result.error, DatabaseError.readOnlyViolation.errorDescription)
        XCTAssertEqual(fake.statements.count, 1, "A refused statement is not sent")
    }

    func testAStatementIsRefusedWhileAnotherRunsAndTheFirstResultIsUndisturbed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-database-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = IDEDatabaseCatalog(storeURL: directory.appendingPathComponent("database-connections.json"))
        let support = IDEDatabaseSupport(catalog: catalog, keychain: IDEDatabaseMemoryKeyStore())
        let connection = DatabaseConnection(name: "local", engine: .postgres)
        catalog.upsert(connection)
        let gate = GatedSQL()
        support.installSQLSessionForTesting(gate, id: connection.id)
        let binding = IDEDatabaseConsoleBinding(connectionID: connection.id, mongoDatabase: nil, mongoCollection: nil)

        let first = Task { await support.execute(statement: "SELECT 1", binding: binding, resetSort: true) }
        await gate.waitUntilStarted()
        XCTAssertTrue(support.isRunning)
        XCTAssertEqual(support.runningConnectionID, connection.id)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while support.result.rowCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(support.result.rowCount, 1, "The first row is visible before the statement completes")

        await support.execute(statement: "SELECT 2", binding: binding, resetSort: true)
        XCTAssertEqual(support.result.statement, "SELECT 1", "the refused statement must not overwrite the running one's header")
        XCTAssertTrue(support.banner?.contains("already running") == true)
        let sent = await gate.statements.count
        XCTAssertEqual(sent, 1, "the refused statement is never sent")

        await gate.release()
        await first.value
        XCTAssertFalse(support.isRunning)
        XCTAssertNil(support.runningConnectionID)
        XCTAssertEqual(support.result.rows, [["1"]])
        // After it finishes, the next statement runs.
        let second = Task { await support.execute(statement: "SELECT 3", binding: binding, resetSort: true) }
        await gate.waitUntilStarted(count: 2)
        await gate.release()
        await second.value
        XCTAssertEqual(support.result.statement, "SELECT 3")
    }

    func testACancelledResultSaysSoAndKeepsTheRowsThatArrived() {
        XCTAssertEqual(
            IDEDatabaseSupport.message(for: QueryResult(columns: [], rows: [], rowsAffected: nil, isReadQuery: true, wasCancelled: true)),
            "Cancelled"
        )
        XCTAssertEqual(
            IDEDatabaseSupport.message(for: QueryResult(columns: ["a"], rows: [["1"], ["2"]], rowsAffected: nil, isReadQuery: true, wasCancelled: true)),
            "Cancelled after 2 rows"
        )
    }

    func testConsolesKeepSeparateResultSets() async throws {
        let catalog = try makeIsolatedCatalog()
        let support = IDEDatabaseSupport(catalog: catalog, keychain: IDEDatabaseMemoryKeyStore())
        let connection = DatabaseConnection(name: "local", engine: .postgres)
        catalog.upsert(connection)
        support.installSQLSessionForTesting(RecordingSQL(), id: connection.id)
        let binding = IDEDatabaseConsoleBinding(connectionID: connection.id, mongoDatabase: nil, mongoCollection: nil)
        let first = UUID()
        let second = UUID()
        let firstDocument = DocumentID(UUID())
        support.bindConsole(workbenchID: first, documentID: firstDocument, binding: binding)
        support.bindConsole(workbenchID: second, documentID: DocumentID(UUID()), binding: binding)

        await support.execute(statements: ["SELECT 1", "SELECT 2"], binding: binding, consoleID: first)
        XCTAssertTrue(support.resultSet(for: second).result.statement.isEmpty)
        await support.execute(statements: ["SELECT 3"], binding: binding, consoleID: second)
        support.selectScriptResult(0, consoleID: first)

        XCTAssertEqual(support.resultSet(for: first).result.statement, "SELECT 1")
        XCTAssertEqual(support.resultSet(for: second).result.statement, "SELECT 3")
        support.closeConsole(workbenchID: first, documentID: firstDocument)
        XCTAssertTrue(support.resultSet(for: first).scriptResults.isEmpty)
        XCTAssertEqual(support.resultSet(for: second).result.statement, "SELECT 3")
    }

    func testTheResultsBarSaysHowManyRowsAStatementChanged() {
        XCTAssertEqual(
            IDEDatabaseSupport.message(for: QueryResult(columns: [], rows: [], rowsAffected: 4_812, isReadQuery: false)),
            "4,812 rows affected"
        )
        XCTAssertEqual(
            IDEDatabaseSupport.message(for: QueryResult(columns: [], rows: [], rowsAffected: 1, isReadQuery: false)),
            "1 row affected"
        )
        XCTAssertEqual(
            IDEDatabaseSupport.message(for: QueryResult(columns: [], rows: [], rowsAffected: 0, isReadQuery: false)),
            "0 rows affected"
        )
        XCTAssertEqual(
            IDEDatabaseSupport.message(for: QueryResult(columns: [], rows: [], rowsAffected: nil, isReadQuery: false)),
            "Statement completed."
        )
        XCTAssertEqual(
            IDEDatabaseSupport.message(for: QueryResult(columns: ["a"], rows: [["1"], ["2"]], rowsAffected: nil, isReadQuery: true)),
            "2 rows"
        )
    }

    func testADisconnectedSourceShowsAPlaceholderWhenExpanded() {
        let connection = DatabaseConnection(name: "shop", engine: .postgres, host: "db.example.com")
        let collapsed = IDEDatabaseTree.flatten(
            connections: [connection], connected: [], sqlSchemas: [:], mongoSchemas: [:], expanded: []
        )
        XCTAssertEqual(collapsed.map(\.kind), [.connection(connection.id)])
        XCTAssertTrue(collapsed[0].canDisclose)
        XCTAssertFalse(collapsed[0].isExpanded)

        let open = IDEDatabaseTree.flatten(
            connections: [connection], connected: [], sqlSchemas: [:], mongoSchemas: [:],
            expanded: [IDEDatabaseSupport.connectionKey(connection.id)]
        )
        XCTAssertEqual(open.map(\.kind), [.connection(connection.id), .placeholder(connection.id)])
        XCTAssertEqual(open[1].title, "Not connected")
        XCTAssertFalse(open[1].canDisclose)
    }

    func testAnExpandedSQLSourceListsTablesThenColumns() {
        let connection = DatabaseConnection(name: "shop", engine: .postgres, database: "shop")
        let schema = IDEDatabaseSQLSchema(
            tables: ["users", "orders"],
            columns: ["users": [
                SQLColumn(name: "id", declaredType: "int", isPrimaryKey: true, isNotNull: true),
                SQLColumn(name: "email", declaredType: "text", isPrimaryKey: false, isNotNull: true),
            ]]
        )
        let connectionKey = IDEDatabaseSupport.connectionKey(connection.id)
        let schemaKey = IDEDatabaseSupport.schemaKey(connection.id)
        let usersKey = IDEDatabaseSupport.tableKey(connection.id, "users")
        let rows = IDEDatabaseTree.flatten(
            connections: [connection],
            connected: [connection.id],
            sqlSchemas: [connection.id: schema],
            mongoSchemas: [:],
            expanded: [connectionKey, schemaKey, usersKey]
        )
        XCTAssertEqual(rows.map(\.title), ["shop", "shop", "users", "id", "email", "orders"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 3, 3, 2])
        XCTAssertEqual(rows[3].detail, "int")
        XCTAssertEqual(rows[3].systemImage, "key.fill")
        XCTAssertEqual(rows[4].systemImage, "circle")
        XCTAssertTrue(rows[5].canDisclose)
        XCTAssertFalse(rows[5].isExpanded)

        let neighbor = IDEListNeighbor.move(usersKey, in: rows.map(\.id), by: 1)
        XCTAssertEqual(neighbor, IDEDatabaseTree.columnKey(connection.id, "users", "id"))
    }

    func testMongoListsDatabasesAndCollections() {
        let connection = DatabaseConnection(name: "local", engine: .mongo)
        let schema = IDEDatabaseMongoSchema(
            databases: ["app", "admin"],
            collections: ["app": ["users", "sessions"]]
        )
        let connectionKey = IDEDatabaseSupport.connectionKey(connection.id)
        let appKey = IDEDatabaseSupport.mongoDatabaseKey(connection.id, "app")
        let rows = IDEDatabaseTree.flatten(
            connections: [connection],
            connected: [connection.id],
            sqlSchemas: [:],
            mongoSchemas: [connection.id: schema],
            expanded: [connectionKey, appKey]
        )
        XCTAssertEqual(rows.map(\.title), ["local", "app", "users", "sessions", "admin"])
        XCTAssertEqual(rows[2].kind, .mongoCollection(connection.id, "app", "users"))
        XCTAssertFalse(rows[4].isExpanded)
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

/// A SQL session whose statements wait until the test lets them finish, so a test can look at the
/// window while a statement is running.
private actor GatedSQL: SQLExecuting {
    private(set) var statements: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var starters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    nonisolated func query(_ sql: String) async throws -> QueryResult {
        await run(sql)
    }

    func execute(_ sql: String, parameters: [DatabaseValue], into store: ResultStore) async throws -> ExecutionSummary {
        let columns = [ResultColumn(name: "n")]
        await store.setColumns(columns)
        try await store.append([[.int(Int64(statements.count + 1))]])
        _ = await run(sql)
        await store.finish()
        return ExecutionSummary(columns: columns, rowCount: 1)
    }

    private func run(_ sql: String) async -> QueryResult {
        statements.append(sql)
        for starter in starters.filter({ $0.count <= statements.count }) { starter.continuation.resume() }
        starters.removeAll { $0.count <= statements.count }
        await withCheckedContinuation { waiters.append($0) }
        // The nth statement the session was given answers with n.
        return QueryResult(columns: ["n"], rows: [[String(statements.count)]], rowsAffected: nil, isReadQuery: true)
    }

    func waitUntilStarted(count: Int = 1) async {
        if statements.count >= count { return }
        await withCheckedContinuation { starters.append((count, $0)) }
    }

    func release() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}
