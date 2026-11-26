import DatabaseKit
import EditorIntelligence
import XCTest

@testable import Umbra

/// SQLite needs no server, so these run the real path: catalog, session, facade, console.
@MainActor
final class IDESQLiteSourceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbra-sqlite-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSupport() -> IDEDatabaseSupport {
        let catalog = IDEDatabaseCatalog(storeURL: directory.appendingPathComponent("database-connections.json"))
        return IDEDatabaseSupport(catalog: catalog, keychain: IDEDatabaseMemoryKeyStore())
    }

    /// A database with a table and two rows, made with the library directly.
    private func makeDatabase(named name: String) async throws -> String {
        let path = directory.appendingPathComponent(name).path
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(path), createIfMissing: true))
        let store = ResultStore(columns: [])
        for statement in [
            "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT)",
            "INSERT INTO items (name, note) VALUES ('apple', NULL), ('pear', '')",
        ] {
            _ = try await session.execute(statement, into: store)
        }
        await store.close()
        await session.close()
        return path
    }

    private func binding(_ connection: DatabaseConnection) -> IDEDatabaseConsoleBinding {
        IDEDatabaseConsoleBinding(connectionID: connection.id, mongoDatabase: nil, mongoCollection: nil)
    }

    func testBrowseEditsRemainStagedOnConflictAndCommitAsOneBatch() async throws {
        let path = try await makeDatabase(named: "edits.sqlite")
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: path)
        let tableBinding = IDEDatabaseConsoleBinding(connectionID: connection.id, sqliteBrowseTable: "items")
        let select = #"SELECT * FROM "main"."items""#
        await support.execute(statement: select, binding: tableBinding, resetSort: true)
        let pending = try XCTUnwrap(support.result.pendingEdits)
        let storage = try XCTUnwrap(support.result.storage)
        let rows = try await storage.store.rows(in: 0..<2)
        let name = try XCTUnwrap(pending.target.draft(row: 0, column: 1, values: rows[0]))
        let note = try XCTUnwrap(pending.target.draft(row: 1, column: 2, values: rows[1]))
        XCTAssertNil(pending.target.draft(row: 0, column: 0, values: rows[0]))
        try pending.stage(name, replacement: .text("pear tree"))
        try pending.stage(note, replacement: .null)
        pending.undo()
        XCTAssertEqual(pending.edits.count, 1)
        pending.redo()
        XCTAssertEqual(pending.edits.count, 2)
        XCTAssertNotNil(support.closeBlocker)

        await support.execute(statement: "SELECT 100", binding: tableBinding, resetSort: true)
        XCTAssertEqual(support.result.storage, storage, "Replacing a result must preserve its staged edits")
        await support.disconnect(connection.id)
        XCTAssertTrue(support.isConnected(connection.id))

        let writer = try await SQLSession.connect(login: connection.sqlLogin(password: ""), readOnly: false)
        _ = try await writer.query("UPDATE items SET note = 'outside edit' WHERE id = 2")
        let first = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertFalse(first)
        XCTAssertEqual(pending.conflict?.current, [.text("outside edit")])
        let rolledBack = try await writer.query("SELECT name FROM items WHERE id = 1")
        XCTAssertEqual(rolledBack.rows, [["apple"]])
        XCTAssertEqual(pending.edits.count, 2)

        pending.rebaseConflict()
        let committed = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertTrue(committed)
        XCTAssertTrue(pending.committed)
        let actual = try await writer.query("SELECT name, note FROM items ORDER BY id")
        XCTAssertEqual(actual.rows, [["pear tree", nil], ["pear", nil]])
        XCTAssertNil(support.closeBlocker)

        await support.execute(statement: select, binding: tableBinding, resetSort: true)
        let stale = try XCTUnwrap(support.result.pendingEdits)
        let staleStorage = try XCTUnwrap(support.result.storage)
        let currentRows = try await staleStorage.store.rows(in: 0..<1)
        let staleDraft = try XCTUnwrap(stale.target.draft(row: 0, column: 1, values: currentRows[0]))
        try stale.stage(staleDraft, replacement: .text("should not write"))
        _ = try await writer.query("ALTER TABLE items ADD COLUMN extra TEXT")
        do {
            _ = try await support.submitEdits(stale, storage: staleStorage, consoleID: nil)
            XCTFail("A changed schema must reject the staged mutation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("table schema changed"))
        }
        XCTAssertEqual(stale.edits.count, 1)
        let unchanged = try await writer.query("SELECT name FROM items WHERE id = 1")
        XCTAssertEqual(unchanged.rows, [["pear tree"]])
        stale.revertAll()
        await writer.disconnect()
        await support.disconnect(connection.id)
    }

    func testFilteredClipboardPasteStagesAnAtomicUndoGroupAndSkipsHiddenRows() async throws {
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: try await makeDatabase(named: "paste.sqlite"))
        let console = IDEDatabaseConsoleBinding(connectionID: connection.id, sqliteBrowseTable: "items")
        await support.execute(statement: "INSERT INTO items(name, note) VALUES ('apple orchard', NULL)", binding: console, resetSort: true)
        await support.execute(statement: #"SELECT * FROM "main"."items""#, binding: console, resetSort: true)
        let storage = try XCTUnwrap(support.result.storage)
        let pending = try XCTUnwrap(support.result.pendingEdits)
        let matched = try await IDEDatabaseLoadedFilter(text: "apple", column: 1).apply(to: storage.store)
        XCTAssertEqual(matched.indices, [0, 2])

        let paste = IDEDatabaseGridPaste(text: "alpha\tfirst\nbeta\tsecond", delimiter: "\t",
                                        sourceRows: matched.indices, columns: [1, 2])
        let proposals = try await paste.edits(from: storage.store, target: pending.target)
        XCTAssertEqual(try pending.stage(proposals), 4)
        XCTAssertEqual(pending.preview().map(\.row), [0, 2])
        pending.undo()
        XCTAssertTrue(pending.edits.isEmpty)
        pending.redo()
        XCTAssertEqual(pending.edits.count, 4)

        let rejected = IDEDatabaseGridPaste(text: "new value\t5", delimiter: "\t", sourceRows: [0], columns: [1, 0])
        do {
            _ = try await rejected.edits(from: storage.store, target: pending.target)
            XCTFail("The clipboard rectangle crosses an identity column")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("identity"))
        }
        XCTAssertEqual(pending.edits.count, 4)
        let committed = try await support.submitEdits(pending, storage: storage, consoleID: nil)
        XCTAssertTrue(committed)
        await support.execute(statement: "SELECT name, note FROM items ORDER BY id", binding: console, resetSort: true)
        XCTAssertEqual(support.result.rows, [["alpha", "first"], ["pear", ""], ["beta", "second"]])
        await support.disconnect(connection.id)
    }

    func testServerFilterPreservesOriginalParametersAndBindsSearchValue() async throws {
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: try await makeDatabase(named: "server-filter.sqlite"))
        let session = try XCTUnwrap(support.sqlSession(for: connection.id))
        let quoted = "a'b; --"
        _ = try await session.query("INSERT INTO items(name) VALUES (?)", parameters: [.text(quoted)])
        let statement = IDEDatabaseStatement("SELECT id, name, note FROM items WHERE id >= ?; -- trailing comment", parameters: [.int(2)])
        let filter = IDEDatabaseServerFilter(statement: statement, columns: ["id", "name", "note"], engine: .sqlite,
                                            connectionID: connection.id, scopeRevision: nil)
        let query = try filter.query(column: 1, comparison: .equals, value: .text(quoted))
        XCTAssertFalse(query.sql.contains(quoted))
        XCTAssertEqual(query.parameters, [.int(2), .text(quoted)])
        let matching = try await session.query(query.sql, parameters: query.parameters)
        XCTAssertEqual(matching.rows, [["3", quoted, nil]])
        let nulls = try filter.query(column: 2, comparison: .equals, value: .null)
        XCTAssertTrue(nulls.sql.contains("IS NULL"))
        XCTAssertEqual(nulls.parameters, [.int(2)])
        let matchingNull = try await session.query(nulls.sql, parameters: nulls.parameters)
        XCTAssertEqual(matchingNull.rows, [["3", quoted, nil]])
        await support.disconnect(connection.id)
    }

    func testUnverifiedResultHasNoEditTargetAndTransactionsPreserveQueryResults() async throws {
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: try await makeDatabase(named: "tx-actions.sqlite"))
        let browse = IDEDatabaseConsoleBinding(connectionID: connection.id, sqliteBrowseTable: "items")
        await support.execute(statement: "SELECT name AS id, id AS name FROM items", binding: browse, resetSort: true)
        XCTAssertNil(support.result.pendingEdits)
        let stored = try XCTUnwrap(support.result.storage)
        await support.performTransaction(.begin(.init()), connectionID: connection.id)
        XCTAssertEqual(support.result.storage, stored)
        XCTAssertEqual(support.sqlTransactions[connection.id], .active(readOnly: false))
        await support.performTransaction(.savepoint, connectionID: connection.id)
        let savepoint = try XCTUnwrap(support.databaseSavepoints[connection.id]?.first)
        await support.execute(statement: "UPDATE items SET name = 'temporary' WHERE id = 1", binding: browse, resetSort: true)
        await support.performTransaction(.rollbackTo(savepoint), connectionID: connection.id)
        await support.performTransaction(.release(savepoint), connectionID: connection.id)
        XCTAssertEqual(support.databaseSavepoints[connection.id], [])
        await support.performTransaction(.commit, connectionID: connection.id)
        XCTAssertEqual(support.sqlTransactions[connection.id], TransactionState.none)
        await support.execute(statement: "SELECT name FROM items WHERE id = 1", binding: browse, resetSort: true)
        XCTAssertEqual(support.result.rows, [["apple"]])
        await support.disconnect(connection.id)
    }

    func testRelatedRowsUseAllComponentsOfTheDeclaredKey() async throws {
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: ":memory:")
        let binding = binding(connection)
        await support.execute(statements: [
            "CREATE TABLE parent (id INTEGER, code TEXT COLLATE NOCASE, PRIMARY KEY(id, code))",
            "CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER, parent_code TEXT, "
                + "FOREIGN KEY(parent_id, parent_code) REFERENCES parent(id, code))",
            "INSERT INTO parent VALUES (1, 'Key'), (1, 'Other')",
            "INSERT INTO child VALUES (1, 1, 'key'), (2, 1, 'Other')",
        ], binding: binding)
        let session = try XCTUnwrap(support.sqlSession(for: connection.id))
        for (table, index, expected) in [
            ("child", 1, [["1", "Key"]]),
            ("parent", 0, [["1", "1", "key"]]),
        ] {
            let browse = IDEDatabaseConsoleBinding(connectionID: connection.id, sqliteBrowseTable: table)
            await support.execute(statement: "SELECT * FROM \"main\".\"\(table)\"", binding: browse, resetSort: true)
            let storage = try XCTUnwrap(support.result.storage)
            let columns = await storage.store.snapshot.columns
            _ = columns
            let queries = try await support.relatedRows(in: support.result, row: 0, columnIndex: index)
            let query = try XCTUnwrap(queries.first)
            XCTAssertEqual(query.parameters.count, 2)
            let related = try await session.query(query.sql, parameters: query.parameters)
            XCTAssertEqual(related.rows, expected)
        }
        await support.disconnect(connection.id)
    }

    func testAddingAFileConnectsListsItsTablesAndRunsStatements() async throws {
        let path = try await makeDatabase(named: "shop.sqlite")
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: path)

        XCTAssertEqual(connection.engine, .sqlite)
        XCTAssertEqual(connection.name, "shop.sqlite")
        XCTAssertEqual(connection.database, URL(fileURLWithPath: path).standardizedFileURL.path)
        XCTAssertTrue(support.isConnected(connection.id))
        XCTAssertEqual(support.selectedConnectionID, connection.id)
        XCTAssertEqual(support.sqlSchemas[connection.id]?.tables, ["items"])

        await support.execute(statement: "SELECT * FROM items ORDER BY id", binding: binding(connection), resetSort: true)
        XCTAssertNil(support.result.error)
        XCTAssertEqual(support.result.columns, ["id", "name", "note"])
        XCTAssertEqual(support.result.rows, [["1", "apple", nil], ["2", "pear", ""]], "NULL and the empty string stay different")
        XCTAssertEqual(support.result.message, "2 rows")

        await support.execute(statement: "UPDATE items SET note = 'ripe'", binding: binding(connection), resetSort: true)
        XCTAssertEqual(support.result.message, "2 rows affected")

        // The explorer's lazily loaded columns come through the same facade.
        await support.ensureColumns(connectionID: connection.id, table: "items")
        XCTAssertEqual(support.sqlSchemas[connection.id]?.columns["items"]?.map(\.name), ["id", "name", "note"])
        await support.disconnect(connection.id)
        XCTAssertFalse(support.isConnected(connection.id))
    }

    func testScriptRefreshesCatalogAndKeepsResultsInStatementOrder() async throws {
        let support = makeSupport()
        let provider = SQLCompletionProvider()
        support.sqlCompletionProvider = provider
        let connection = try await support.addSQLiteSource(path: try await makeDatabase(named: "script.sqlite"))
        let documentID = DocumentID(UUID())
        support.bindConsole(workbenchID: UUID(), documentID: documentID, binding: binding(connection))

        func waitForCatalog(tables: [String]) async {
            let ready = expectation(description: "Published catalog for \(tables)")
            func check() {
                guard let catalog = provider.store.snapshot(for: documentID)?.catalog, catalog.isComplete,
                      catalog.relations.map(\.name) == tables else { return }
                support.onSQLCatalogChange = nil
                ready.fulfill()
            }
            support.onSQLCatalogChange = { _ in check() }
            check()
            await fulfillment(of: [ready], timeout: 3)
        }

        await waitForCatalog(tables: ["items"])
        await support.execute(statements: [
            "BEGIN",
            "CREATE TABLE discarded (id INTEGER PRIMARY KEY)",
            "ROLLBACK",
            "CREATE TABLE child (item_id INTEGER REFERENCES items(id))",
            "SELECT 41 AS first_value",
            "SELECT 42 AS last_value",
        ], binding: binding(connection))
        XCTAssertEqual(support.scriptResults.count, 6)
        XCTAssertTrue(support.scriptResults.allSatisfy { $0.error == nil && $0.duration != nil })
        XCTAssertEqual(support.result.rows, [["42"]])
        support.selectScriptResult(4)
        XCTAssertEqual(support.result.rows, [["41"]])

        await waitForCatalog(tables: ["child", "items"])
        let snapshot = try XCTUnwrap(provider.store.snapshot(for: documentID))
        XCTAssertEqual(snapshot.catalog.foreignKeys.first?.fromColumns, ["item_id"])
        XCTAssertEqual(snapshot.catalog.foreignKeys.first?.toColumns, ["id"])
        let findings = SQLDiagnosticsEngine.diagnose(
            text: "SELECT * FROM discarded; SELECT * FROM other.items;", dialect: .sqlite, catalog: snapshot.catalog
        )
        XCTAssertEqual(findings.map(\.code), ["unknown-table"])

        await support.execute(statements: [
            "SELECT 1", "SELECT * FROM missing", "CREATE TABLE should_not_exist (id INTEGER)",
        ], binding: binding(connection))
        XCTAssertEqual(support.scriptResults.count, 2)
        XCTAssertNotNil(support.result.error)
        let session = try XCTUnwrap(support.sqlSession(for: connection.id))
        let tables = try await session.tables()
        XCTAssertEqual(tables, ["child", "items"])

        await support.execute(statement: "CREATE TEMP TABLE scratch (id INTEGER)",
                              binding: binding(connection), resetSort: true)
        let partial = try XCTUnwrap(provider.store.snapshot(for: documentID))
        XCTAssertFalse(partial.catalog.isComplete)
        XCTAssertTrue(SQLDiagnosticsEngine.diagnose(
            text: "SELECT * FROM scratch", dialect: .sqlite, catalog: partial.catalog
        ).isEmpty)
        await support.disconnect(connection.id)
        XCTAssertEqual(provider.store.snapshot(for: documentID)?.catalog.isComplete, false)
    }

    func testBrowsingStoredSQLiteRowsKeepsTheOriginalResultAfterTheTableChanges() async throws {
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: try await makeDatabase(named: "stored.sqlite"))
        let session = try XCTUnwrap(support.sqlSession(for: connection.id))
        _ = try await session.query("""
            WITH RECURSIVE numbers(n) AS (SELECT 3 UNION ALL SELECT n + 1 FROM numbers WHERE n < 450)
            INSERT INTO items (id, name) SELECT n, 'original' FROM numbers
            """)
        let consoleID = UUID()
        let documentID = DocumentID(UUID())
        support.bindConsole(workbenchID: consoleID, documentID: documentID, binding: binding(connection))
        await support.execute(statements: ["SELECT id, name FROM items ORDER BY id"],
                              binding: binding(connection), consoleID: consoleID)
        let store = try XCTUnwrap(support.result.storage?.store)
        let original = try await store.row(at: 400)
        XCTAssertEqual(original, [.int(401), .text("original")])
        XCTAssertEqual(support.result.rowCount, 450)

        _ = try await session.query("UPDATE items SET name = 'changed'")
        let later = try await store.rows(in: 400..<450)
        XCTAssertEqual(later.first, [.int(401), .text("original")])
        XCTAssertTrue(support.result.storage?.store === store)

        support.closeConsole(workbenchID: consoleID, documentID: documentID)
        for _ in 0..<100 {
            do {
                _ = try await store.row(at: 0)
                try await Task.sleep(for: .milliseconds(10))
            } catch ResultStoreError.closed {
                await support.disconnect(connection.id)
                return
            }
        }
        XCTFail("Closing a console should close its result store")
        await support.disconnect(connection.id)
    }

    func testChartAggregationRunsInNewConsoleAndKeepsTheSourceResult() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: try await makeDatabase(named: "chart.sqlite"))
        let workspace = IDEWorkspace(databaseSupport: support)
        defer { workspace.teardown() }
        workspace.bootstrap()

        let sourceSQL = "SELECT 'a' AS category, :amount AS amount UNION ALL SELECT 'a', 2"
        let consoleBinding = binding(connection)
        workspace.openUntitled(displayName: "Source", text: sourceSQL, languageIdentifier: "sql")
        let source = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        support.bindConsole(workbenchID: source.id, documentID: source.documentID, binding: consoleBinding)
        await support.execute(statement: "SELECT 'source' AS value", binding: consoleBinding, resetSort: true, consoleID: source.id)
        let original = try XCTUnwrap(support.resultSet(for: source.id).result.storage)
        let query = IDEDatabaseChartQuery(statement: sourceSQL, engine: .sqlite, binding: consoleBinding)
        let sql = try XCTUnwrap(query.sql(columns: ["category", "amount"], settings: .init(x: 0, y: 1, aggregate: .sum)))
        workspace.runDatabaseChartQuery(sql, binding: consoleBinding)

        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while workspace.databaseParameterPrompt == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let console = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        XCTAssertNotEqual(console.id, source.id)
        let prompt = try XCTUnwrap(workspace.databaseParameterPrompt)
        XCTAssertEqual(prompt.labels, [":amount"])
        XCTAssertFalse(support.isRunning)
        workspace.databaseParameterPrompt = nil
        prompt.onSubmit([.int(5)])
        while support.resultSet(for: console.id).result.rows.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(support.resultSet(for: console.id).result.rows, [["a", "7"]])
        XCTAssertEqual(support.resultSet(for: source.id).result.storage, original)
        await support.disconnect(connection.id)
    }

    func testConsoleRunsSelectionAndPromptsBeforeRunningBoundScript() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        let support = makeSupport()
        let connection = try await support.addSQLiteSource(path: try await makeDatabase(named: "console.sqlite"))
        let workspace = IDEWorkspace(databaseSupport: support)
        defer { workspace.teardown() }
        workspace.bootstrap()
        let text = "SELECT 10; SELECT :value AS chosen; SELECT 30"
        workspace.openUntitled(displayName: "Console", text: text, languageIdentifier: "sql")
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        support.bindConsole(workbenchID: document.id, documentID: document.documentID, binding: binding(connection))
        let textView = workspace.host(for: workspace.workbench.activePaneID).textView

        func waitFor(_ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !predicate(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(predicate())
        }

        textView.selectedRange = (text as NSString).range(of: "SELECT 30")
        workspace.executeDatabaseConsole()
        try await waitFor { support.result.rows == [["30"]] && !support.isRunning }
        XCTAssertNil(workspace.databaseParameterPrompt)

        workspace.executeDatabaseConsole(all: true)
        try await waitFor { workspace.databaseParameterPrompt != nil }
        let prompt = try XCTUnwrap(workspace.databaseParameterPrompt)
        XCTAssertEqual(prompt.labels, ["2 · :value"])
        XCTAssertFalse(support.isRunning)
        workspace.databaseParameterPrompt = nil
        prompt.onSubmit([.text("a'b; --")])
        try await waitFor { support.scriptResults.count == 3 && !support.isRunning }
        XCTAssertEqual(support.scriptResults.map(\.rows), [[["10"]], [["a'b; --"]], [["30"]]])
        XCTAssertEqual(support.scriptResults[1].statement, "SELECT :value AS chosen")

        let badQuery = "SELECT 'e\u{301}😀', :placeholder, FROM items"
        textView.selectedRange = NSRange(location: textView.documentLength, length: 0)
        textView.insertText("; " + badQuery)
        let fullText = text + "; " + badQuery
        textView.selectedRange = (fullText as NSString).range(of: badQuery)
        workspace.executeDatabaseConsole()
        try await waitFor { workspace.databaseParameterPrompt != nil }
        let errorPrompt = try XCTUnwrap(workspace.databaseParameterPrompt)
        workspace.databaseParameterPrompt = nil
        errorPrompt.onSubmit([.text("bound")])
        try await waitFor { textView.diagnostics.contains { $0.source == "SQL Execution" } }
        let marker = try XCTUnwrap(textView.diagnostics.first { $0.source == "SQL Execution" })
        XCTAssertEqual(marker.range, (fullText as NSString).range(of: "FROM"))

        textView.selectedRange = NSRange(location: textView.documentLength, length: 0)
        textView.insertText(" ")
        XCTAssertFalse(textView.diagnostics.contains { $0.source == "SQL Execution" })
        await support.disconnect(connection.id)
    }

    func testAFileThatIsNotADatabaseIsRefusedWithTheReasonAndNotAdded() async throws {
        let path = directory.appendingPathComponent("notes.db").path
        try "this is plain text that happens to be named like a database".write(toFile: path, atomically: true, encoding: .utf8)
        let support = makeSupport()
        do {
            _ = try await support.addSQLiteSource(path: path)
            XCTFail("a text file was opened as a database")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not a SQLite database"), error.localizedDescription)
        }
        XCTAssertTrue(support.catalog.connections.isEmpty, "a refused file must not become a data source")
        // A path that does not exist is refused too, instead of creating an empty database.
        do {
            _ = try await support.addSQLiteSource(path: directory.appendingPathComponent("typo.sqlite").path)
            XCTFail("a missing file was opened")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("typo.sqlite").path))
        }
    }

    func testTheSameFileIsOneSourceNotTwo() async throws {
        let path = try await makeDatabase(named: "once.sqlite")
        let support = makeSupport()
        let first = try await support.addSQLiteSource(path: path)
        let second = try await support.addSQLiteSource(path: path + "/../once.sqlite")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(support.catalog.connections.count, 1)
    }

    func testCreatingANewDatabaseIsExplicitAndNeverOverwrites() async throws {
        let path = directory.appendingPathComponent("fresh.sqlite").path
        let support = makeSupport()
        let created = try await support.addSQLiteSource(path: path, create: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(support.isConnected(created.id))
        XCTAssertEqual(support.sqlSchemas[created.id]?.tables, [])
        await support.execute(statement: "CREATE TABLE t (x)", binding: binding(created), resetSort: true)
        XCTAssertNil(support.result.error)
        // Asking to create over an existing file fails; the data is still there.
        // A different window with its own catalog (so it does not already know the file).
        let otherCatalog = IDEDatabaseCatalog(storeURL: directory.appendingPathComponent("other-catalog.json"))
        let other = IDEDatabaseSupport(catalog: otherCatalog, keychain: IDEDatabaseMemoryKeyStore())
        do {
            _ = try await other.addSQLiteSource(path: path, create: true)
            XCTFail("overwrote an existing database")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already exists"), error.localizedDescription)
        }
        XCTAssertTrue(otherCatalog.connections.isEmpty)
        // The table made through the first source is still there.
        await support.execute(statement: "SELECT count(*) FROM t", binding: binding(created), resetSort: true)
        XCTAssertNil(support.result.error)
        await support.disconnect(created.id)
    }

    func testAnInMemoryDatabaseSurvivesAReconnectBecauseConnectLeavesItAlone() async throws {
        let support = makeSupport()
        let memory = try await support.addSQLiteSource(path: ":memory:")
        XCTAssertEqual(memory.name, "In-memory database")
        await support.execute(statement: "CREATE TABLE kept (x)", binding: binding(memory), resetSort: true)
        await support.execute(statement: "INSERT INTO kept VALUES (1)", binding: binding(memory), resetSort: true)
        // "Reconnect" (the sidebar's action, and what saving would do) must not swap in an empty database.
        try await support.connect(memory.id)
        await support.execute(statement: "SELECT x FROM kept", binding: binding(memory), resetSort: true)
        XCTAssertNil(support.result.error, "the table was lost: the in-memory database was recreated")
        XCTAssertEqual(support.result.rows, [["1"]])
        // Disconnect is the explicit way to discard it.
        await support.disconnect(memory.id)
        try await support.connect(memory.id)
        await support.execute(statement: "SELECT x FROM kept", binding: binding(memory), resetSort: true)
        XCTAssertNotNil(support.result.error, "after Disconnect it is a new, empty database")
    }

    func testAReadOnlySourceRefusesWritesAndLeavesTheFileAlone() async throws {
        let path = try await makeDatabase(named: "locked.sqlite")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let support = makeSupport()
        let source = try await support.addSQLiteSource(path: path, readOnly: true)
        await support.execute(statement: "SELECT count(*) FROM items", binding: binding(source), resetSort: true)
        XCTAssertEqual(support.result.rows, [["2"]])
        for attack in ["DELETE FROM items", "DROP TABLE items", "INSERT INTO items (name) VALUES ('x')", "WITH c AS (SELECT 1) DELETE FROM items"] {
            await support.execute(statement: attack, binding: binding(source), resetSort: true)
            XCTAssertNotNil(support.result.error, "\(attack) was not refused")
        }
        await support.execute(statement: "PRAGMA table_info(items)", binding: binding(source), resetSort: true)
        XCTAssertNil(support.result.error, "reading a pragma is allowed on a read-only SQLite source")
        XCTAssertEqual(support.result.rows.count, 3)
        await support.disconnect(source.id)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before, "the file's bytes changed")
    }

    func testCancelStopsARunningStatementAndTheResultsBarSaysSo() async throws {
        let path = try await makeDatabase(named: "slow.sqlite")
        let support = makeSupport()
        let source = try await support.addSQLiteSource(path: path)
        let longQuery = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c"
        let run = Task { await support.execute(statement: longQuery, binding: binding(source), resetSort: true) }
        for _ in 0..<100 where !support.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(support.isRunning)
        XCTAssertEqual(support.runningConnectionID, source.id)
        try await Task.sleep(for: .milliseconds(200))  // let SQLite get well into the statement

        let started = ContinuousClock.now
        await support.cancelRunning()  // what the stop button, the menu item and ⌃⌘. call
        await run.value
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        XCTAssertFalse(support.isRunning)
        XCTAssertNil(support.runningConnectionID)
        XCTAssertEqual(support.result.message, "Cancelled")
        XCTAssertNil(support.result.error, "a cancelled statement is not an error")
        // The window is usable again straight away.
        await support.execute(statement: "SELECT count(*) FROM items", binding: binding(source), resetSort: true)
        XCTAssertEqual(support.result.rows, [["2"]])
        await support.disconnect(source.id)
    }

    func testTheSheetCreatesANewFileOnSaveAndShowsNoNetworkSettings() async throws {
        let support = makeSupport()
        support.beginNewConnection()
        let editor = try XCTUnwrap(support.editor)
        let path = directory.appendingPathComponent("from-sheet.sqlite").path
        editor.engine = .sqlite
        editor.database = path
        editor.createsNewFile = true
        let connection = editor.connection()
        XCTAssertEqual(connection.engine, .sqlite)
        XCTAssertEqual(connection.host, "", "a file has no host")
        XCTAssertEqual(connection.name, "from-sheet.sqlite", "the name defaults to the file name")
        XCTAssertEqual(DatabaseURL.build(connection, password: "secret"), "sqlite://" + path)
        XCTAssertFalse(DatabaseURL.redacted(connection, password: "secret").contains("secret"))

        support.saveEditor()
        for _ in 0..<100 where support.editor != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(support.editor, "the sheet closes once the file exists and the source is saved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(support.catalog.connections.first?.database, path)
    }

    func testOnlyARealSQLiteHeaderRoutesAFileToTheDatabaseSidebar() async throws {
        let real = try await makeDatabase(named: "real.bin")  // no database-looking extension at all
        XCTAssertTrue(IDEWorkspace.isSQLiteDatabase(URL(fileURLWithPath: real)), "the header decides, not the extension")
        let text = directory.appendingPathComponent("lookalike.sqlite")
        try "just text pretending to be a database, long enough to matter".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertFalse(IDEWorkspace.isSQLiteDatabase(text), "the extension alone proves nothing")
        let empty = directory.appendingPathComponent("empty.db")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        XCTAssertFalse(IDEWorkspace.isSQLiteDatabase(empty), "an empty file could be anything")
        XCTAssertFalse(IDEWorkspace.isSQLiteDatabase(directory), "a folder is not a database")
    }

    /// A WAL-mode database with no -wal/-shm files, which SQLite cannot open strictly read-only.
    private func makeCleanWALDatabase(named name: String) async throws -> String {
        let source = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(directory.appendingPathComponent("wal-source-\(name)").path), createIfMissing: true))
        let store = ResultStore(columns: [])
        for statement in ["PRAGMA journal_mode = WAL", "CREATE TABLE items (id INTEGER)", "INSERT INTO items VALUES (1), (2)"] {
            _ = try await source.execute(statement, into: store)
        }
        await store.close()
        let path = directory.appendingPathComponent(name).path
        try await source.backup(to: path)
        await source.close()
        return path
    }

    func testAnOrdinaryReadOnlyOpenSaysNothing() async throws {
        let path = try await makeDatabase(named: "plain.sqlite")
        let support = makeSupport()
        let source = try await support.addSQLiteSource(path: path, readOnly: true)
        XCTAssertNil(support.sourceNotes[source.id], "nothing to warn about when the file opened normally")
        XCTAssertNil(support.banner)
        await support.disconnect(source.id)
    }

    func testTheQueryOnlyFallbackIsShownBecauseItCanCreateSideFiles() async throws {
        let path = try await makeCleanWALDatabase(named: "clean-wal.sqlite")
        let support = makeSupport()
        let source = try await support.addSQLiteSource(path: path, readOnly: true)
        let note = try XCTUnwrap(support.sourceNotes[source.id], "the fallback was used and must be visible")
        XCTAssertEqual(note.mode, .queryOnlyFallback)
        XCTAssertTrue(note.message.contains("-wal"))
        XCTAssertTrue(note.message.contains("may have created"))
        XCTAssertEqual(support.banner, note.message, "a banner says it when the source is connected")
        let rows = IDEDatabaseTree.flatten(
            connections: [source], connected: [source.id], sqlSchemas: [:], mongoSchemas: [:], expanded: [],
            notes: support.sourceNotes.mapValues(\.tag)
        )
        XCTAssertTrue(rows[0].detail.hasSuffix("read-only (query only)"), "the tree row says it for as long as it is connected")
        await support.execute(statement: "SELECT count(*) FROM items", binding: binding(source), resetSort: true)
        XCTAssertEqual(support.result.rows, [["2"]])
        await support.execute(statement: "DELETE FROM items", binding: binding(source), resetSort: true)
        XCTAssertNotNil(support.result.error, "writes are still refused")
        await support.disconnect(source.id)
        XCTAssertNil(support.sourceNotes[source.id], "the note ends with the connection")
    }

    func testAnImmutableOpenIsShownAsPossiblyOutOfDate() async throws {
        let path = try await makeCleanWALDatabase(named: "locked-wal.sqlite")
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let support = IDEDatabaseSupport(
            catalog: IDEDatabaseCatalog(storeURL: manager.temporaryDirectory.appendingPathComponent("immutable-\(UUID().uuidString).json")),
            keychain: IDEDatabaseMemoryKeyStore()
        )
        let source = try await support.addSQLiteSource(path: path, readOnly: true)
        let note = try XCTUnwrap(support.sourceNotes[source.id])
        XCTAssertEqual(note.mode, .immutable)
        XCTAssertTrue(note.message.contains("Do not rely on this view for current data"))
        let rows = IDEDatabaseTree.flatten(
            connections: [source], connected: [source.id], sqlSchemas: [:], mongoSchemas: [:], expanded: [],
            notes: support.sourceNotes.mapValues(\.tag)
        )
        XCTAssertTrue(rows[0].detail.hasSuffix("immutable, may be out of date"))
        await support.disconnect(source.id)
        try? manager.removeItem(at: support.catalog.storeURL)
    }

    func testTheTreeDescribesAFileNotAHost() {
        let file = DatabaseConnection(name: "shop", engine: .sqlite, host: "", database: "/Users/me/data/shop.sqlite")
        let memory = DatabaseConnection(name: "scratch", engine: .sqlite, host: "", database: ":memory:")
        let rows = IDEDatabaseTree.flatten(
            connections: [file, memory], connected: [], sqlSchemas: [:], mongoSchemas: [:], expanded: []
        )
        XCTAssertTrue(rows[0].detail.hasPrefix("SQLite · "))
        XCTAssertTrue(rows[0].detail.hasSuffix("shop.sqlite"))
        XCTAssertEqual(rows[1].detail, "SQLite · in memory")
    }

    func testSQLiteURLsRoundTrip() throws {
        let draft = try DatabaseURL.parse("sqlite:///Users/me/My%20Data/app.db?mode=ro")
        XCTAssertEqual(draft.connection.engine, .sqlite)
        XCTAssertEqual(draft.connection.database, "/Users/me/My Data/app.db")
        XCTAssertTrue(draft.connection.readOnly)
        XCTAssertEqual(draft.connection.name, "app.db")
        XCTAssertEqual(DatabaseURL.build(draft.connection, password: ""), "sqlite:///Users/me/My%20Data/app.db?mode=ro")
        XCTAssertEqual(try DatabaseURL.parse("sqlite://:memory:").connection.database, ":memory:")
        XCTAssertThrowsError(try DatabaseURL.parse("sqlite://"))
    }
}
