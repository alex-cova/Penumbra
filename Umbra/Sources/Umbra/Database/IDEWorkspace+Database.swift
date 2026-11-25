import AppKit
import DatabaseKit
import EditorIntelligence
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

    func openDatabaseDeclaration(name: String, column: String?, documentID: DocumentID) {
        guard let binding = databaseSupport.consolesByDocumentID[documentID.uuid],
              let session = databaseSupport.sqlSession(for: binding.connectionID),
              let relation = databaseSupport.sqlRelation(name, connectionID: binding.connectionID) else { return }
        Task {
            do {
                let text = try await session.declaration(of: relation)
                guard workbench.activePane.selectedDocument?.documentID == documentID,
                      databaseSupport.sqlSession(for: binding.connectionID) === session else { return }
                openUntitled(displayName: "\(name) DDL", text: text, languageIdentifier: "sql")
                if let column, let dialect = SQLDialect(engine: session.engine) {
                    let source = text as NSString
                    let tokens = SQLLexer(text, dialect: dialect).tokenize()
                    if let token = tokens.first(where: { token in
                        guard token.kind == .word || token.kind == .quotedIdentifier else { return false }
                        let raw = source.substring(with: token.range)
                        return raw == column || raw == SQLQuoting.quote(column, dialect: dialect)
                    }) {
                        let textView = host(for: workbench.activePaneID).textView
                        textView.selectedRange = token.range
                        textView.scrollRangeToCenter(token.range)
                    }
                }
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
    func refreshDatabaseGutter(from textView: TextView) async {
        guard let document = workbench.activePane.selectedDocument,
              let binding = databaseSupport.consoles[document.id],
              let engine = databaseSupport.catalog.connection(id: binding.connectionID)?.engine else { return }
        let stamp = DatabaseGutterStamp(
            view: ObjectIdentifier(textView),
            documentID: document.id,
            generation: textView.contentGeneration
        )
        guard stamp != databaseGutterStamp else { return }
        guard textView.documentLength <= SQLDiagnosticProvider.maximumLength else {
            databaseGutterStamp = stamp
            textView.setGutterDecorations([])
            return
        }
        guard let snapshot = await textView.materializedText(), snapshot.generation == stamp.generation else { return }
        let lines = await runDetached {
            Self.databaseStatements(in: snapshot.text, engine: engine).map(\.startLine)
        }
        guard !Task.isCancelled, textView.contentGeneration == stamp.generation,
              workbench.activePane.selectedDocument?.id == document.id,
              databaseSupport.consoles[document.id] == binding,
              host(for: workbench.activePaneID).textView === textView else { return }
        databaseGutterStamp = stamp
        var seen = Set<Int>()
        textView.setGutterDecorations(lines.filter { seen.insert($0).inserted }.map {
            GutterDecoration(
                line: $0, symbolName: "play.fill", accessibilityLabel: "Execute Query",
                placement: .lineMarkerColumn
            )
        })
        textView.gutterDecorationHandler = { [weak self] line in
            self?.executeDatabaseConsole(line: line)
        }
        textView.gutterLineClickHandler = nil
        textView.gutterDecorationsDidMove = nil
    }

    /// The statements of a console's text. SQL consoles are split as SQL (strings, comments,
    /// `$$` bodies, trigger and procedure bodies and `DELIMITER` scripts stay whole); a MongoDB
    /// console holds one JSON filter, which is one statement.
    nonisolated private static func databaseStatements(in text: String, engine: DatabaseEngine) -> [SQLStatement] {
        if let dialect = SQLDialect(engine: engine) {
            return SQLStatementSplitter.split(text, dialect: dialect)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let start = (text as NSString).range(of: trimmed).location
        return [SQLStatement(
            range: NSRange(location: start, length: (trimmed as NSString).length), extendedEnd: start + (trimmed as NSString).length,
            startLine: 1, endLine: trimmed.split(separator: "\n", omittingEmptySubsequences: false).count, text: trimmed, isTerminated: false
        )]
    }

    func executeDatabaseConsole(all: Bool = false, line: Int? = nil) {
        let paneID = workbench.activePaneID
        guard databaseParameterPrompt == nil,
              let document = workbench.activePane.selectedDocument,
              document.contentKind == .text,
              let binding = databaseSupport.consoles[document.id],
              let connection = databaseSupport.catalog.connection(id: binding.connectionID) else { return }
        let textView = host(for: paneID).textView
        let selection = textView.selectedRange
        let generation = textView.contentGeneration
        let engine = connection.engine
        Task {
            guard let snapshot = await textView.materializedText(), snapshot.generation == generation else { return }
            let text = snapshot.text
            let statements = await runDetached {
                let source = text as NSString
                if !all, line == nil, let dialect = SQLDialect(engine: engine),
                   selection.length > 0, NSMaxRange(selection) <= source.length {
                    return SQLStatementSplitter.split(source.substring(with: selection), dialect: dialect).map {
                        var statement = $0
                        statement.range.location += selection.location
                        statement.extendedEnd += selection.location
                        return statement
                    }
                }
                let statements = Self.databaseStatements(in: text, engine: engine)
                if let line { return SQLStatementSplitter.statement(atLine: line, in: statements).map { [$0] } ?? [] }
                if all { return statements }
                return SQLStatementSplitter.statement(containing: selection.location, in: statements).map { [$0] } ?? []
            }
            guard !statements.isEmpty, textView.contentGeneration == generation,
                  workbench.activePaneID == paneID,
                  workbench.activePane.selectedDocument?.id == document.id,
                  databaseSupport.consoles[document.id] == binding else { return }
            let plans = await runDetached {
                statements.map { statement in
                    SQLDialect(engine: engine).map { SQLParameterPlan(statement.text, dialect: $0) }
                }
            }
            guard textView.contentGeneration == generation, workbench.activePaneID == paneID,
                  workbench.activePane.selectedDocument?.id == document.id,
                  databaseSupport.consoles[document.id] == binding, databaseParameterPrompt == nil else { return }
            let labels = plans.enumerated().flatMap { index, plan in
                (plan?.labels ?? []).map { label in
                    statements.count == 1 ? label : "\(index + 1) · \(label)"
                }
            }
            let launch: ([DatabaseValue]) -> Void = { [weak self = self, weak textView = textView] values in
                guard values.count == labels.count, let self, let textView, textView.contentGeneration == generation,
                      workbench.activePaneID == paneID, workbench.activePane.selectedDocument?.id == document.id,
                      databaseSupport.consoles[document.id] == binding else { return }
                var offset = 0
                let prepared = zip(statements, plans).map { statement, plan in
                    guard let plan else { return IDEDatabaseStatement(statement.text) }
                    let start = offset
                    offset += plan.labels.count
                    return IDEDatabaseStatement(statement.text, parameters: plan.bindingOrder.map { values[start + $0] },
                                                sourceOffset: statement.start, parameterPlan: plan)
                }
                showDatabaseResults()
                Task {
                    let accepted = !databaseSupport.isRunning
                    if accepted { hostCache.peek(paneID)?.intelligenceController?.setTransientDiagnostic(nil) }
                    await databaseSupport.execute(preparedStatements: prepared, binding: binding, consoleID: document.id)
                    guard accepted, textView.contentGeneration == generation,
                          workbench.layout.findPane(id: paneID)?.selectedDocument?.id == document.id,
                          databaseSupport.consoles[document.id] == binding,
                          let error = databaseSupport.resultSet(for: document.id).result.sourceError else { return }
                    publishDatabaseError(error, in: textView, paneID: paneID, documentID: document.documentID)
                }
            }
            if labels.isEmpty {
                launch([])
            } else {
                databaseParameterPrompt = IDEDatabaseParameterPrompt(labels: labels, onSubmit: launch)
            }
        }
    }

    private func publishDatabaseError(
        _ error: IDEDatabaseExecutionError, in textView: TextView, paneID: UUID, documentID: DocumentID
    ) {
        func position(at offset: Int) -> TextPosition? {
            textView.textLocation(at: offset).map {
                TextPosition(line: $0.lineNumber, column: $0.column, utf16Offset: offset)
            }
        }
        guard let start = position(at: error.range.location), let end = position(at: NSMaxRange(error.range)),
              let host = hostCache.peek(paneID), host.textView === textView else { return }
        host.intelligenceController?.setTransientDiagnostic(Diagnostic(
            severity: .error, message: error.message,
            range: EditorIntelligence.TextRange(start: start, end: end), source: "SQL Execution", code: error.code
        ), for: documentID)
    }

    /// A file that starts with SQLite's 16-byte header, unless the user forces its extension to hex.
    /// An empty file is not one (it could be anything), and an extension alone proves nothing.
    static func isSQLiteDatabase(_ url: URL) -> Bool {
        guard url.isFileURL, !IDEHexSettings.shared.forceHexExtensions.contains(url.pathExtension.lowercased()) else {
            return false
        }
        return Array(IDEHexRouting.readHead(url).prefix(SQLiteSession.fileMagic.count)) == SQLiteSession.fileMagic
    }

    /// Asks for a SQLite file and opens it as a data source.
    func openSQLiteFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // `.sqlite`, `.sqlite3`, `.db`, `.db3` and files with no extension are all common, and an
        // extension proves nothing: the file's header is checked instead.
        panel.allowsOtherFileTypes = true
        panel.message = "Choose SQLite database files"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.addSQLiteFiles(panel.urls)
        }
    }

    /// Asks where to create a new, empty SQLite database and opens it.
    func newSQLiteDatabase() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "database.sqlite"
        panel.message = "Create a new SQLite database"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.showSidebarTab(.database)
            Task {
                do {
                    // The panel has already asked about replacing; an existing file is opened,
                    // never overwritten.
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    try await self.databaseSupport.addSQLiteSource(path: url.path, create: !exists)
                } catch {
                    self.databaseSupport.banner = error.localizedDescription
                }
            }
        }
    }

    /// Opens files chosen, dropped or passed from Finder. A file that is not a SQLite database is
    /// reported by name and reason rather than skipped silently.
    func addSQLiteFiles(_ urls: [URL]) {
        showSidebarTab(.database)
        Task {
            for url in urls {
                do {
                    try await databaseSupport.addSQLiteSource(path: url.path)
                } catch {
                    databaseSupport.banner = error.localizedDescription
                }
            }
        }
    }

    func cancelDatabaseStatement() {
        Task { await databaseSupport.cancelRunning() }
    }

    var isDatabaseConsoleActive: Bool {
        guard let id = workbench.activePane.selectedDocument?.id else { return false }
        return databaseSupport.consoles[id] != nil
    }

    func refreshDatabaseConsoleBinding(in paneID: UUID) {
        let host = host(for: paneID)
        host.intelligenceController?.setTransientDiagnostic(nil)
        host.intelligenceController?.refreshDiagnostics()
        if paneID == workbench.activePaneID {
            databaseGutterStamp = nil
            host.textView.setGutterDecorations([])
            host.textView.gutterDecorationHandler = nil
            Task { await refreshDatabaseGutter(from: host.textView) }
        }
        saveSession()
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
        refreshDatabaseConsoleBinding(in: workbench.activePaneID)
        guard run else { return }
        databaseSupport.showsResultsTab = true
        showBottomTab(.databaseResults)
        Task { await databaseSupport.execute(statement: text, binding: binding, resetSort: true, consoleID: selected.id) }
    }
}
