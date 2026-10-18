import DatabaseKit
import EditorIntelligence
import Foundation
import Observation

/// Which data source an untitled console tab runs against.
struct IDEDatabaseConsoleBinding: Equatable {
    var connectionID: UUID
    var mongoDatabase: String?
    var mongoCollection: String?
}

struct IDEDatabaseSQLSchema: Equatable {
    var tables: [String] = []
    var columns: [String: [SQLColumn]] = [:]
}

struct IDEDatabaseMongoSchema: Equatable {
    var databases: [String] = []
    var collections: [String: [String]] = [:]
}

struct IDEDatabaseResult: Equatable {
    var columns: [String] = []
    var rows: [[String?]] = []
    var page = 0
    var pageSize = DatabasePageSize.sql
    var sortColumn: String?
    var sortAscending = true
    var error: String?
    var message: String?
    var statement = ""
    var connectionID: UUID?
    var mongoDatabase: String?
    var mongoCollection: String?
    var engine: DatabaseEngine = .postgres

    var canGoBack: Bool { page > 0 && error == nil }
    var canGoForward: Bool { error == nil && rows.count >= pageSize }
}

/// The connection sheet. Its identity is the presentation, not the data source, so editing the
/// same source twice still opens the sheet.
@MainActor
@Observable
final class IDEDatabaseConnectionEditor: Identifiable {
    let id = UUID()
    /// Nil for a data source that has not been saved yet.
    let existingID: UUID?
    private let connectionID: UUID
    var name: String
    var engine: DatabaseEngine
    var host: String
    var port: Int
    var username: String
    var password: String
    var database: String
    var useTLS: Bool
    var readOnly: Bool
    var authSource: String
    var useSRV: Bool
    var replicaSet: String
    var directConnection: Bool
    var urlText = ""
    var status: String?
    var isTesting = false
    var portFollowsDefault: Bool

    private init(existing: DatabaseConnection?, password: String) {
        if let existing {
            existingID = existing.id
            connectionID = existing.id
            name = existing.name
            engine = existing.engine
            host = existing.host
            port = existing.port
            username = existing.username
            self.password = password
            database = existing.database
            useTLS = existing.useTLS
            readOnly = existing.readOnly
            authSource = existing.authSource
            useSRV = existing.useSRV
            replicaSet = existing.replicaSet
            directConnection = existing.directConnection
            portFollowsDefault = existing.port == existing.engine.defaultPort
        } else {
            let fresh = DatabaseConnection()
            existingID = nil
            connectionID = fresh.id
            name = ""
            engine = fresh.engine
            host = fresh.host
            port = fresh.port
            username = ""
            self.password = ""
            database = ""
            useTLS = false
            readOnly = false
            authSource = fresh.authSource
            useSRV = false
            replicaSet = ""
            directConnection = true
            portFollowsDefault = true
        }
    }

    static func makeNew() -> IDEDatabaseConnectionEditor {
        IDEDatabaseConnectionEditor(existing: nil, password: "")
    }

    static func editing(_ connection: DatabaseConnection, password: String) -> IDEDatabaseConnectionEditor {
        IDEDatabaseConnectionEditor(existing: connection, password: password)
    }

    func connection() -> DatabaseConnection {
        var connection = DatabaseConnection(
            id: existingID ?? connectionID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            engine: engine,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username,
            database: database.trimmingCharacters(in: .whitespacesAndNewlines),
            useTLS: useTLS,
            readOnly: readOnly,
            authSource: authSource.trimmingCharacters(in: .whitespacesAndNewlines),
            useSRV: useSRV,
            replicaSet: replicaSet.trimmingCharacters(in: .whitespacesAndNewlines),
            directConnection: directConnection
        )
        if connection.name.isEmpty {
            connection.name = connection.database.isEmpty ? connection.host : connection.database
        }
        if connection.engine == .mongo, connection.database.isEmpty {
            connection.database = "admin"
        }
        return connection
    }

    func applyURL() {
        do {
            let draft = try DatabaseURL.parse(urlText)
            let parsed = draft.connection
            engine = parsed.engine
            host = parsed.host
            port = parsed.port
            username = parsed.username
            if !draft.password.isEmpty { password = draft.password }
            database = parsed.database
            useTLS = parsed.useTLS
            authSource = parsed.authSource
            useSRV = parsed.useSRV
            replicaSet = parsed.replicaSet
            directConnection = parsed.directConnection
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = parsed.name }
            portFollowsDefault = port == engine.defaultPort
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }
}

/// Per-window sessions, the schema tree, and the page of results. The connection list is shared.
@MainActor
@Observable
final class IDEDatabaseSupport {
    let catalog: IDEDatabaseCatalog
    private let keychain: any IDEDatabaseKeyStore

    var consoles: [UUID: IDEDatabaseConsoleBinding] = [:]
    /// The same bindings keyed by `WorkbenchDocument.documentID`, which is the id completion
    /// sees (`makeEIPDocument` publishes `documentID`, not `id`).
    var consolesByDocumentID: [UUID: IDEDatabaseConsoleBinding] = [:]
    /// Pushed `SQLCompletionSnapshot`s, so a keystroke reads memory instead of the database.
    var sqlCompletionProvider: SQLCompletionProvider?
    var selectedConnectionID: UUID?
    var selectedMongoDatabase: String?
    var selectedMongoCollection: String?
    var expanded: Set<String> = []
    var editor: IDEDatabaseConnectionEditor?
    var showsResultsTab = false
    var isRunning = false
    var result = IDEDatabaseResult()
    var banner: String?

    private var sqlSessions: [UUID: SQLSession] = [:]
    private var sqlTesting: [UUID: any SQLExecuting] = [:]
    private var mongoSessions: [UUID: MongoSession] = [:]
    var sqlSchemas: [UUID: IDEDatabaseSQLSchema] = [:]
    var mongoSchemas: [UUID: IDEDatabaseMongoSchema] = [:]

    init(
        catalog: IDEDatabaseCatalog = IDESharedServices.shared.databases,
        keychain: any IDEDatabaseKeyStore = IDEDatabaseKeychain()
    ) {
        self.catalog = catalog
        self.keychain = keychain
    }

    func isConnected(_ id: UUID) -> Bool {
        sqlSessions[id] != nil || sqlTesting[id] != nil || mongoSessions[id] != nil
    }

    /// The live SQL session, for user-initiated reads that may query (diagrams, generated SQL).
    /// Keystrokes never touch this; completion reads its pushed snapshot instead.
    func sqlSession(for connectionID: UUID) -> SQLSession? {
        sqlSessions[connectionID]
    }

    func beginNewConnection() {
        editor = IDEDatabaseConnectionEditor.makeNew()
    }

    func beginEdit(_ id: UUID) {
        guard let connection = catalog.connection(id: id) else { return }
        do {
            let password = try keychain.load(account: id.uuidString) ?? ""
            editor = IDEDatabaseConnectionEditor.editing(connection, password: password)
        } catch {
            banner = error.localizedDescription
        }
    }

    func saveEditor() {
        guard let editor else { return }
        let connection = editor.connection()
        let wasConnected = isConnected(connection.id)
        catalog.upsert(connection)
        do {
            try keychain.save(editor.password, account: connection.id.uuidString)
            banner = wasConnected ? "Saved. Connect again to use the new settings." : nil
        } catch {
            banner = error.localizedDescription
        }
        if wasConnected {
            Task { await disconnect(connection.id) }
        }
        selectedConnectionID = connection.id
        self.editor = nil
    }

    func testEditor() async {
        guard let editor else { return }
        editor.isTesting = true
        editor.status = nil
        defer { editor.isTesting = false }
        let connection = editor.connection()
        do {
            switch connection.engine {
            case .mysql, .postgres:
                try await SQLSession.test(login: connection.sqlLogin(password: editor.password))
            case .mongo:
                try await MongoSession.test(login: connection.mongoLogin(password: editor.password))
            }
            editor.status = "Connected."
        } catch {
            editor.status = error.localizedDescription
        }
    }

    func remove(_ id: UUID) {
        Task { await disconnect(id) }
        catalog.remove(id: id)
        try? keychain.delete(account: id.uuidString)
        if selectedConnectionID == id { selectedConnectionID = nil }
    }

    func connect(_ id: UUID) async throws {
        guard let connection = catalog.connection(id: id) else { return }
        await disconnect(id)
        let password = try keychain.load(account: id.uuidString) ?? ""
        switch connection.engine {
        case .mysql, .postgres:
            let session = try await SQLSession.connect(
                login: connection.sqlLogin(password: password), readOnly: connection.readOnly
            )
            sqlSessions[id] = session
            sqlSchemas[id] = IDEDatabaseSQLSchema(tables: try await session.tables())
            refreshSQLSnapshots(connectionID: id)
            Task { await loadAllColumns(connectionID: id) }
        case .mongo:
            let session = try await MongoSession.connect(
                login: connection.mongoLogin(password: password), readOnly: connection.readOnly
            )
            mongoSessions[id] = session
            mongoSchemas[id] = IDEDatabaseMongoSchema(databases: try await session.listDatabases())
        }
        selectedConnectionID = id
        expanded.insert(Self.connectionKey(id))
        banner = nil
    }

    /// One query for every table's columns, filling the same cache the sidebar reads. Until it
    /// returns, completion still offers keywords and table names; the next keystroke sees columns.
    private func loadAllColumns(connectionID: UUID) async {
        guard let session = sqlSessions[connectionID] else { return }
        do {
            let grouped = try await session.allColumns()
            for (table, columns) in grouped {
                sqlSchemas[connectionID]?.columns[table] = columns
            }
            refreshSQLSnapshots(connectionID: connectionID)
        } catch {
            // The sidebar's per-table load stays as the fallback; a restricted login that cannot
            // read information_schema keeps keywords and table names.
        }
    }

    func disconnect(_ id: UUID) async {
        if let session = sqlSessions.removeValue(forKey: id) {
            await session.disconnect()
        }
        sqlTesting.removeValue(forKey: id)
        if let session = mongoSessions.removeValue(forKey: id) {
            await session.disconnect()
        }
        sqlSchemas[id] = nil
        mongoSchemas[id] = nil
        refreshSQLSnapshots(connectionID: id)
    }

    func closeAll() {
        let sql = Array(sqlSessions.values)
        let mongo = Array(mongoSessions.values)
        sqlSessions.removeAll()
        sqlTesting.removeAll()
        mongoSessions.removeAll()
        sqlSchemas.removeAll()
        mongoSchemas.removeAll()
        if let provider = sqlCompletionProvider {
            for key in consolesByDocumentID.keys {
                provider.removeSnapshot(for: DocumentID(key))
            }
        }
        Task {
            for session in sql { await session.disconnect() }
            for session in mongo { await session.disconnect() }
        }
    }

    /// Stores the binding under both the workbench id and the EIP document id, and pushes the
    /// console's first snapshot (tables, no columns yet when freshly connected).
    func bindConsole(workbenchID: UUID, documentID: DocumentID, binding: IDEDatabaseConsoleBinding) {
        consoles[workbenchID] = binding
        consolesByDocumentID[documentID.uuid] = binding
        pushSnapshot(for: documentID, binding: binding)
    }

    func closeConsole(workbenchID: UUID, documentID: DocumentID) {
        consoles.removeValue(forKey: workbenchID)
        consolesByDocumentID.removeValue(forKey: documentID.uuid)
        sqlCompletionProvider?.removeSnapshot(for: documentID)
    }

    /// Replaces the provider snapshots of every console bound to this connection. MongoDB
    /// consoles keep no snapshot and stay JSON filters.
    func refreshSQLSnapshots(connectionID: UUID) {
        for (uuid, binding) in consolesByDocumentID where binding.connectionID == connectionID {
            pushSnapshot(for: DocumentID(uuid), binding: binding)
        }
    }

    private func pushSnapshot(for documentID: DocumentID, binding: IDEDatabaseConsoleBinding) {
        guard let provider = sqlCompletionProvider else { return }
        guard let connection = catalog.connection(id: binding.connectionID),
              connection.engine != .mongo
        else {
            provider.removeSnapshot(for: documentID)
            return
        }
        let schema = sqlSchemas[binding.connectionID]
        provider.setSnapshot(
            SQLCompletionSnapshot(
                engine: connection.engine,
                tables: schema?.tables ?? [],
                columnsByTable: schema?.columns ?? [:]
            ),
            for: documentID
        )
    }

    func ensureColumns(connectionID: UUID, table: String) async {
        guard sqlSchemas[connectionID]?.columns[table] == nil else { return }
        guard let session = sqlSessions[connectionID] else { return }
        do {
            let columns = try await session.columns(of: table)
            sqlSchemas[connectionID]?.columns[table] = columns
            refreshSQLSnapshots(connectionID: connectionID)
        } catch {
            banner = error.localizedDescription
        }
    }

    func ensureCollections(connectionID: UUID, database: String) async {
        guard mongoSchemas[connectionID]?.collections[database] == nil else { return }
        guard let session = mongoSessions[connectionID] else { return }
        do {
            let names = try await session.listCollections(database: database)
            mongoSchemas[connectionID]?.collections[database] = names
        } catch {
            banner = error.localizedDescription
        }
    }

    private func ensureConnected(_ connection: DatabaseConnection) async throws {
        if connection.engine == .mongo {
            if mongoSessions[connection.id] != nil { return }
        } else if sqlTesting[connection.id] != nil || sqlSessions[connection.id] != nil {
            return
        }
        try await connect(connection.id)
    }

    func execute(
        statement: String,
        binding: IDEDatabaseConsoleBinding,
        page: Int,
        resetSort: Bool
    ) async {
        showsResultsTab = true
        guard let connection = catalog.connection(id: binding.connectionID) else {
            result.error = "That data source was removed."
            result.columns = []
            result.rows = []
            return
        }
        isRunning = true
        result.error = nil
        result.connectionID = connection.id
        result.engine = connection.engine
        result.statement = statement
        result.mongoDatabase = binding.mongoDatabase
        result.mongoCollection = binding.mongoCollection
        if page == 0, resetSort {
            result.sortColumn = nil
            result.sortAscending = true
        }
        result.page = page
        result.pageSize = connection.engine == .mongo ? DatabasePageSize.mongo : DatabasePageSize.sql
        defer { isRunning = false }
        do {
            try await ensureConnected(connection)
            if connection.engine == .mongo {
                guard let database = binding.mongoDatabase, let collection = binding.mongoCollection else {
                    throw DatabaseError.executionFailed("Select a collection before running a filter.")
                }
                guard let session = mongoSessions[connection.id] else { throw DatabaseError.notConnected }
                let pageResult = try await session.find(
                    database: database,
                    collection: collection,
                    filterJSON: statement,
                    skip: page * result.pageSize,
                    limit: result.pageSize
                )
                result.columns = pageResult.columns
                result.rows = pageResult.rows
                result.message = "\(pageResult.rows.count) documents"
            } else {
                let session: any SQLExecuting
                if let testing = sqlTesting[connection.id] {
                    session = testing
                } else if let live = sqlSessions[connection.id] {
                    session = live
                } else {
                    throw DatabaseError.notConnected
                }
                let pageResult = try await DatabaseQuery.run(
                    statement: statement,
                    readOnly: connection.readOnly,
                    page: page,
                    pageSize: result.pageSize,
                    sortColumn: result.sortColumn,
                    sortAscending: result.sortAscending,
                    engine: connection.engine,
                    using: session
                )
                result.columns = pageResult.columns
                result.rows = pageResult.rows
                result.message = pageResult.columns.isEmpty
                    ? "Statement completed."
                    : "\(pageResult.rows.count) rows"
            }
            result.error = nil
            catalog.updateLastStatement(id: connection.id, statement)
        } catch {
            result.columns = []
            result.rows = []
            result.error = error.localizedDescription
            result.message = nil
        }
    }

    func goToPage(_ page: Int) async {
        guard let id = result.connectionID, page >= 0 else { return }
        let binding = IDEDatabaseConsoleBinding(
            connectionID: id,
            mongoDatabase: result.mongoDatabase,
            mongoCollection: result.mongoCollection
        )
        await execute(statement: result.statement, binding: binding, page: page, resetSort: false)
    }

    func sort(by column: String) async {
        if result.sortColumn == column {
            result.sortAscending.toggle()
        } else {
            result.sortColumn = column
            result.sortAscending = true
        }
        if result.engine == .mongo {
            let index = result.columns.firstIndex(of: column) ?? 0
            let ascending = result.sortAscending
            result.rows.sort { lhs, rhs in
                let left = lhs.indices.contains(index) ? (lhs[index] ?? "") : ""
                let right = rhs.indices.contains(index) ? (rhs[index] ?? "") : ""
                let order = left.localizedStandardCompare(right)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            return
        }
        await goToPage(0)
    }

    func installSQLSessionForTesting(_ session: any SQLExecuting, id: UUID) {
        sqlTesting[id] = session
    }

    static func connectionKey(_ id: UUID) -> String { "connection:\(id.uuidString)" }
    static func schemaKey(_ id: UUID) -> String { "schema:\(id.uuidString)" }
    static func tableKey(_ id: UUID, _ table: String) -> String { "table:\(id.uuidString):\(table)" }
    static func mongoDatabaseKey(_ id: UUID, _ name: String) -> String { "mongo:\(id.uuidString):\(name)" }
}
