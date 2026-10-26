import AppKit
import DatabaseKit
import Foundation
import Penumbra

extension IDEWorkspace {
    /// Opens the Database sidebar and the connection sheet.
    func showNewDatabaseConnection() {
        showSidebarTab(.database)
        databaseSupport.beginNewConnection()
    }

    func showDatabaseResults() {
        databaseSupport.showsResultsTab = true
        showBottomTab(.databaseResults)
    }

    /// An untitled SQL or JSON tab bound to the selected data source.
    func openDatabaseQueryConsole() {
        // Without a project or a document the sidebar stays hidden, so asking the user
        // to select a data source there would do nothing visible. Fall back to the
        // first data source, or offer to create one when none exists yet.
        guard !databaseSupport.catalog.connections.isEmpty else {
            showNewDatabaseConnection()
            return
        }
        guard let connection = databaseSupport.connectionForNewConsole() else {
            databaseSupport.banner = "Select a data source first."
            showSidebarTab(.database)
            return
        }
        databaseSupport.selectedConnectionID = connection.id
        let id = connection.id
        let text: String
        let mongoDatabase: String?
        let mongoCollection: String?
        if connection.engine == .mongo {
            text = connection.lastStatement.isEmpty ? "{}" : connection.lastStatement
            mongoDatabase = databaseSupport.selectedMongoDatabase
            mongoCollection = databaseSupport.selectedMongoCollection
        } else {
            text = connection.lastStatement
            mongoDatabase = nil
            mongoCollection = nil
        }
        openConsole(
            title: connection.name,
            text: text,
            language: connection.engine.consoleLanguage,
            binding: IDEDatabaseConsoleBinding(
                connectionID: id, mongoDatabase: mongoDatabase, mongoCollection: mongoCollection
            ),
            run: false
        )
    }

    func openDatabaseTable(_ connection: DatabaseConnection, table: String) {
        let sql: String
        do {
            sql = try connection.selectAll(from: table)
        } catch {
            databaseSupport.banner = error.localizedDescription
            return
        }
        databaseSupport.selectedConnectionID = connection.id
        openConsole(
            title: table,
            text: sql,
            language: "sql",
            binding: IDEDatabaseConsoleBinding(connectionID: connection.id, mongoDatabase: nil, mongoCollection: nil),
            run: true
        )
    }

    func openDatabaseCollection(_ connection: DatabaseConnection, database: String, collection: String) {
        databaseSupport.selectedConnectionID = connection.id
        databaseSupport.selectedMongoDatabase = database
        databaseSupport.selectedMongoCollection = collection
        openConsole(
            title: collection,
            text: "{}",
            language: "json",
            binding: IDEDatabaseConsoleBinding(
                connectionID: connection.id, mongoDatabase: database, mongoCollection: collection
            ),
            run: true
        )
    }

    /// The schema picture of a data source. Reads live so it is fresh; connect first.
    func showSchemaDiagram(_ connection: DatabaseConnection) {
        guard connection.engine != .mongo else {
            databaseSupport.banner = "MongoDB has no schema diagram."
            return
        }
        openDiagram(IDEDatabaseDiagram.request(connection: connection))
    }

    /// Copies one table's `CREATE TABLE` to the clipboard.
    func copyCreateTable(_ connection: DatabaseConnection, table: String) {
        guard let session = databaseSupport.sqlSession(for: connection.id) else {
            databaseSupport.banner = "Connect to \(connection.name) first."
            return
        }
        Task {
            do {
                let sql = try await session.createTableStatement(table)
                copyDatabaseSQLToClipboard(sql)
                notifications.post("Copied CREATE TABLE \(table).", category: .general)
            } catch {
                databaseSupport.banner = error.localizedDescription
            }
        }
    }

    /// Copies every `CREATE TABLE` of the connected database to the clipboard.
    func copyDatabaseSQL(_ connection: DatabaseConnection) {
        guard let session = databaseSupport.sqlSession(for: connection.id) else {
            databaseSupport.banner = "Connect to \(connection.name) first."
            return
        }
        Task {
            do {
                let sql = try await session.createDatabaseSQL()
                copyDatabaseSQLToClipboard(sql)
                notifications.post("Copied the SQL of \(connection.name).", category: .general)
            } catch {
                databaseSupport.banner = error.localizedDescription
            }
        }
    }

    private func copyDatabaseSQLToClipboard(_ sql: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sql, forType: .string)
    }

    /// A `play.fill` button in the gutter on the first line of every statement in a query
    /// console. Clicking one runs that statement, wherever the caret is. Parsed off the keystroke
    /// on the same debounce as the HTTP send buttons; the click re-parses in case the buffer
    /// changed since the buttons were drawn.
    func refreshDatabaseGutter(from textView: TextView) {
        let stamp = DatabaseGutterStamp(
            view: ObjectIdentifier(textView),
            documentID: workbench.activePane.selectedDocument?.id,
            generation: textView.contentGeneration
        )
        guard stamp != databaseGutterStamp else { return }
        databaseGutterStamp = stamp
        let lines = SQLCompletion.statements(in: textView.text).map(\.startLine)
        var seen = Set<Int>()
        textView.setGutterDecorations(lines.filter { seen.insert($0).inserted }.map {
            GutterDecoration(
                line: $0, symbolName: "play.fill", accessibilityLabel: "Execute Query",
                placement: .lineMarkerColumn
            )
        })
        textView.gutterDecorationHandler = { [weak self, weak textView] line in
            guard let self, let textView else { return }
            self.executeDatabaseStatement(atLine: line, text: textView.text)
        }
        textView.gutterLineClickHandler = nil
        textView.gutterDecorationsDidMove = nil
    }

    /// Runs the statement enclosing `line` in a query console, from its gutter button.
    func executeDatabaseStatement(atLine line: Int, text: String) {
        guard let document = workbench.activePane.selectedDocument,
              document.contentKind == .text,
              let binding = databaseSupport.consoles[document.id],
              let statement = SQLCompletion.statement(atLine: line, in: text) else { return }
        databaseSupport.showsResultsTab = true
        showBottomTab(.databaseResults)
        Task { await databaseSupport.execute(statement: statement, binding: binding, page: 0, resetSort: true) }
    }

    func executeDatabaseConsole() {
        guard let document = workbench.activePane.selectedDocument,
              document.contentKind == .text,
              let binding = databaseSupport.consoles[document.id] else { return }
        let text = host(for: workbench.activePaneID).textView.text
        databaseSupport.showsResultsTab = true
        showBottomTab(.databaseResults)
        Task { await databaseSupport.execute(statement: text, binding: binding, page: 0, resetSort: true) }
    }

    var isDatabaseConsoleActive: Bool {
        guard let id = workbench.activePane.selectedDocument?.id else { return false }
        return databaseSupport.consoles[id] != nil
    }

    private func openConsole(
        title: String,
        text: String,
        language: String,
        binding: IDEDatabaseConsoleBinding,
        run: Bool
    ) {
        openUntitled(displayName: title.isEmpty ? "Query" : title, text: text, languageIdentifier: language)
        guard let selected = workbench.activePane.selectedDocument else { return }
        databaseSupport.bindConsole(workbenchID: selected.id, documentID: selected.documentID, binding: binding)
        guard run else { return }
        databaseSupport.showsResultsTab = true
        showBottomTab(.databaseResults)
        Task { await databaseSupport.execute(statement: text, binding: binding, page: 0, resetSort: true) }
    }
}
