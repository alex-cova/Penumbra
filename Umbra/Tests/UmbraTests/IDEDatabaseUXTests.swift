import AppKit
import DatabaseKit
import SwiftUI
import XCTest
@testable import Umbra

@MainActor
final class IDEDatabaseUXTests: XCTestCase {
    func testExplorerKeyboardOpensDataInLightAndDark() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UMBRA_UI_TESTS"] == "1", "Requires the window server")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wasPersisting = IDEWorkspace.isSessionPersistenceEnabled
        IDEWorkspace.isSessionPersistenceEnabled = false
        defer {
            IDEWorkspace.isSessionPersistenceEnabled = wasPersisting
            try? FileManager.default.removeItem(at: directory)
        }
        let path = directory.appendingPathComponent("keyboard.sqlite").path
        let sqlite = try await SQLiteSession.open(.init(location: .file(path), createIfMissing: true))
        _ = try await self.sqlite("CREATE TABLE items (id INTEGER)", session: sqlite)
        _ = try await self.sqlite("INSERT INTO items VALUES (7)", session: sqlite)
        await sqlite.close()

        for scheme in [ColorScheme.light, .dark] {
            let catalog = IDEDatabaseCatalog(storeURL: directory.appendingPathComponent("\(scheme).json"))
            let source = DatabaseConnection(name: "Keyboard Check", engine: .sqlite, database: path)
            catalog.upsert(source)
            let support = IDEDatabaseSupport(catalog: catalog, keychain: IDEDatabaseMemoryKeyStore())
            let workspace = IDEWorkspace(databaseSupport: support)
            workspace.bootstrap()
            workspace.pendingSidebarFocusTab = .database
            workspace.sidebarFocusRequestID += 1

            let window = NSWindow(contentRect: NSRect(x: -4_000, y: -4_000, width: 400, height: 520),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: IDEDatabaseSidebar().environment(workspace).environment(\.colorScheme, scheme))
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            defer {
                window.close()
                workspace.teardown()
            }

            func send(_ characters: String, keyCode: UInt16) throws {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
                window.sendEvent(event)
            }
            func waitFor(_ predicate: () -> Bool, _ message: String) async throws {
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !predicate(), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(predicate(), message)
            }

            try await waitFor({ workspace.pendingSidebarFocusTab == nil }, "Sidebar acquires focus")
            try await Task.sleep(for: .milliseconds(120))
            try send("\u{F703}", keyCode: 124)
            try await waitFor({ support.expanded.contains(IDEDatabaseTree.connectionKey(source.id)) }, "Right arrow expands the source")
            try send("\r", keyCode: 36)
            try await waitFor({ support.isConnected(source.id) }, "Return connects the source")
            try await Task.sleep(for: .milliseconds(120))
            try send("\u{F701}", keyCode: 125)
            await Task.yield()
            try send("\u{F703}", keyCode: 124)
            try await waitFor({ support.expanded.contains(IDEDatabaseTree.schemaKey(source.id)) }, "Down and Right reach the schema")
            try await Task.sleep(for: .milliseconds(120))
            try send("\u{F701}", keyCode: 125)
            try await Task.sleep(for: .milliseconds(120))
            try send("\r", keyCode: 36)
            try await waitFor({ workspace.workbench.activePane.selectedDocument?.displayName == "items" }, "Return opens the table console")
            // `items` has no key, so a writable source selects its rowid first (the row's identity for editing).
            try await waitFor({ support.result.rows == [["1", "7"]] }, "Return opens the selected table and loads its rows")
        }
    }

    func testExplorerSearchFindsCollapsedObjectsAndKeepsViewTypesSeparate() throws {
        let source = DatabaseConnection(name: "App", group: "Staging")
        let schema = IDEDatabaseSQLSchema(tables: ["orders", "orders_summary"], views: ["orders_summary"])
        let catalog = [source.id: schema]
        let defaultRows = IDEDatabaseTree.flatten(connections: [source], connected: [source.id], sqlSchemas: catalog,
                                                  mongoSchemas: [:], expanded: [])
        XCTAssertEqual(defaultRows.map(\.title), ["Staging", "App"])
        let views = IDEDatabaseTree.flatten(connections: [source], connected: [source.id], sqlSchemas: catalog,
                                           mongoSchemas: [:], expanded: [], query: "orders", filter: .views)
        XCTAssertEqual(views.map(\.title), ["orders_summary"])
        let favorite = try XCTUnwrap(views.first?.id)
        let state = IDEDatabaseExplorerState(expanded: [defaultRows[0].id], favorites: [favorite], recents: [favorite])
        let decoded = try JSONDecoder().decode(IDEWindowSession.self,
            from: JSONEncoder().encode(IDEWindowSession(databaseExplorer: state)))
        XCTAssertEqual(decoded.databaseExplorer?.favorites, [favorite])
        XCTAssertEqual(decoded.databaseExplorer?.recents, [favorite])
        XCTAssertEqual(decoded.databaseExplorer?.expanded, state.expanded)
        XCTAssertNil(try JSONDecoder().decode(IDEWindowSession.self, from: Data("{}".utf8)).databaseExplorer)
    }

    func testProductionWriteRequiresApprovalBeforeAnyStatementInTheBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = IDEDatabaseCatalog(storeURL: directory.appendingPathComponent("connections.json"))
        let connection = DatabaseConnection(name: "Protected", engine: .sqlite, database: ":memory:", isProduction: true)
        catalog.upsert(connection)
        let support = IDEDatabaseSupport(catalog: catalog, keychain: IDEDatabaseMemoryKeyStore())
        defer { support.closeAll() }
        let binding = IDEDatabaseConsoleBinding(connectionID: connection.id)
        await support.execute(statement: "SELECT 10", binding: binding, resetSort: true)
        let original = support.result.storage

        func awaitPrompt() async throws -> IDEDatabaseProductionPrompt {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while support.productionPrompt == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            return try XCTUnwrap(support.productionPrompt)
        }
        let denied = Task { await support.execute(statements: ["SELECT 20", "CREATE TABLE items (id INTEGER)"], binding: binding) }
        let prompt = try await awaitPrompt()
        XCTAssertEqual(prompt.statements.count, 1)
        XCTAssertEqual(support.result.storage, original)
        XCTAssertFalse(support.isRunning)
        prompt.resolve(false)
        await denied.value
        XCTAssertEqual(support.result.rows, [["10"]])

        let allowed = Task { await support.execute(statements: ["CREATE TABLE items (id INTEGER)", "SELECT count(*) FROM items"], binding: binding) }
        try await awaitPrompt().resolve(true)
        await allowed.value
        XCTAssertEqual(support.result.rows, [["0"]])
    }

    func testSQLiteBusyTimeoutReachesTheConsoleSession() async throws {
        let connection = DatabaseConnection(engine: .sqlite, database: ":memory:", sqliteBusyTimeoutMilliseconds: 220)
        let editor = IDEDatabaseConnectionEditor.editing(connection, password: "")
        let login = editor.connection().sqlLogin(password: "")
        let session = try await SQLSession.connect(login: login, readOnly: false)
        let sqlite = try XCTUnwrap(session.sqliteSession)
        let busyTimeout = try await sqlite.pragma("busy_timeout")
        XCTAssertEqual(busyTimeout, "220")
        await session.disconnect()
    }

    func testSQLiteConstraintRebuildPreservesRowsIndexesTriggersAndForeignKeys() async throws {
        let session = try await SQLiteSession.open(.init(location: .memory))
        for statement in [
            "CREATE TABLE parent (id INTEGER PRIMARY KEY)",
            "INSERT INTO parent VALUES (7)",
            "CREATE TABLE audit (value INTEGER)",
            "CREATE TABLE child (k INTEGER, previous INTEGER REFERENCES parent(id))",
            "INSERT INTO child(rowid, k, previous) VALUES (99, 7, 7)",
            "CREATE INDEX child_k ON child(k)",
            "CREATE TRIGGER child_audit AFTER INSERT ON child BEGIN INSERT INTO audit VALUES (NEW.k); END",
        ] { _ = try await sqlite(statement, session: session) }
        var draft = IDEDatabaseSchemaDraft(connection: .init(engine: .sqlite), operation: .addForeignKey, table: "child")
        draft.name = "child_parent"
        draft.keys[0].name = "k"
        draft.referencesTable = "parent"
        draft.referencesColumn = "id"
        draft.sqliteRebuild = try await IDEDatabaseSQLiteRebuild.load("child", from: session)
        for statement in try SQLStatementSplitter.split(draft.statement(), dialect: .sqlite) {
            _ = try await sqlite(statement.text, session: session)
        }
        let info = try await session.tableInfo(table: "child")
        XCTAssertEqual(info.foreignKeys.count, 2)
        XCTAssertTrue(info.indexes.contains { $0.name == "child_k" })
        XCTAssertEqual(info.triggers, ["child_audit"])
        let rows = try await sqlite("SELECT rowid, k, previous FROM child", session: session)
        XCTAssertEqual(rows, [[.int(99), .int(7), .int(7)]])
        _ = try await sqlite("INSERT INTO child VALUES (7, 7)", session: session)
        let audit = try await sqlite("SELECT value FROM audit", session: session)
        XCTAssertEqual(audit, [[.int(7)]])
        do {
            _ = try await IDEDatabaseSQLiteRebuild.load("parent", from: session)
            XCTFail("Dropping a parent during the rebuild would risk incoming foreign keys")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("incoming foreign keys from child"))
        }
        await session.close()
    }

    func testSQLiteRebuildRejectsAStalePreviewBeforeDroppingTheOriginalTable() async throws {
        let session = try await SQLiteSession.open(.init(location: .memory))
        _ = try await sqlite("CREATE TABLE items (id INTEGER)", session: session)
        _ = try await sqlite("INSERT INTO items VALUES (7)", session: session)
        let rebuild = try await IDEDatabaseSQLiteRebuild.load("items", from: session)
        _ = try await sqlite("CREATE INDEX recent_idx ON items(id)", session: session)
        do {
            for statement in try SQLStatementSplitter.split(rebuild.statement(adding: "UNIQUE (id)", nonce: UUID()), dialect: .sqlite) {
                _ = try await sqlite(statement.text, session: session)
            }
            XCTFail("A stale schema version must abort the rebuild")
        } catch {
            let info = try await session.tableInfo(table: "items")
            XCTAssertEqual(info.indexes.map(\.name), ["recent_idx"])
            let rows = try await sqlite("SELECT id FROM items", session: session)
            XCTAssertEqual(rows, [[.int(7)]])
        }
        await session.close()
    }

    private func sqlite(_ sql: String, session: SQLiteSession) async throws -> [[DatabaseValue]] {
        let store = ResultStore(columns: [])
        do {
            _ = try await session.execute(sql, into: store)
            let snapshot = await store.snapshot
            let rows = try await store.mapRows(in: 0..<snapshot.rowCount) { $0 }
            await store.close()
            return rows
        } catch {
            await store.close()
            throw error
        }
    }
}
