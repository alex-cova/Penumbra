import DatabaseKit
import EditorIntelligence
import Foundation
import Observation

/// Which data source an untitled console tab runs against.
struct IDEDatabaseConsoleBinding: Codable, Equatable, Sendable {
    var connectionID: UUID
    var mongoDatabase: String?
    var mongoCollection: String?
}

struct IDEDatabaseSQLScope: Codable, Equatable, Sendable {
    var database: String
    var schema: String?
}

struct IDEDatabaseSQLSchema: Equatable {
    var tables: [String] = []
    var columns: [String: [SQLColumn]] = [:]
    var views: Set<String> = []
}

struct IDEDatabaseExplorerState: Codable {
    var expanded: Set<String> = []
    var favorites: Set<String> = []
    var recents: [String] = []
}

struct IDEDatabaseMongoSchema: Equatable {
    var databases: [String] = []
    var collections: [String: [String]] = [:]
}

struct IDEDatabaseStatement: Equatable, Sendable {
    let text: String
    let sql: String
    let parameters: [DatabaseValue]
    let sourceOffset: Int?
    let parameterPlan: SQLParameterPlan?

    init(_ text: String, parameters: [DatabaseValue] = [], sourceOffset: Int? = nil,
         parameterPlan: SQLParameterPlan? = nil) {
        self.text = text
        self.sql = parameterPlan?.sql ?? text
        self.parameters = parameters
        self.sourceOffset = sourceOffset
        self.parameterPlan = parameterPlan
    }

    func errorRange(at position: Int, dialect: SQLDialect) -> NSRange? {
        guard let sourceOffset, let point = parameterPlan?.sourceRange(at: position) else { return nil }
        if point.length > 0 { return NSRange(location: sourceOffset + point.location, length: point.length) }
        let tokens = SQLLexer(text, dialect: dialect).tokenize()
        let token = tokens.first { $0.start <= point.location && point.location < $0.end }
            ?? tokens.first { $0.start >= point.location }
            ?? tokens.last
        guard let token else { return nil }
        return NSRange(location: sourceOffset + token.start, length: token.length)
    }
}

struct IDEDatabaseExecutionError: Equatable {
    let range: NSRange
    let message: String
    let code: String?
}

struct IDEDatabaseResultStorage: Equatable, Sendable {
    let store = ResultStore(columns: [])

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.store === rhs.store }
}

struct IDEDatabaseResult: Equatable {
    var columns: [String] = []
    var rows: [[String?]] = []
    var pageSize = DatabasePageSize.sql
    var canSort = false
    var storage: IDEDatabaseResultStorage?
    var rowCount = 0
    var hasCompleteRows = false
    var sortColumn: String?
    var sortAscending = true
    var error: String?
    var sourceError: IDEDatabaseExecutionError?
    var notices: [DatabaseNotice] = []
    var message: String?
    var duration: Duration?
    var statement = ""
    var preparedStatement: IDEDatabaseStatement?
    var connectionID: UUID?
    var mongoDatabase: String?
    var mongoCollection: String?
    var engine: DatabaseEngine = .postgres
    var scopeRevision: UUID?

}

struct IDEDatabaseResultSet {
    var result = IDEDatabaseResult()
    var scriptResults: [IDEDatabaseResult] = []
    var selection = 0
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
    /// PostgreSQL only: refuse to connect without TLS, and verify the certificate and host name.
    var requireTLS: Bool
    var readOnly: Bool
    var authSource: String
    var useSRV: Bool
    var replicaSet: String
    var directConnection: Bool
    var urlText = ""
    var status: String?
    var isTesting = false
    var portFollowsDefault: Bool
    /// SQLite: the file does not exist yet and saving should make it.
    var createsNewFile = false
    var isProduction = false
    var group = ""
    var sqliteBusyTimeoutMilliseconds = 5_000
    var testSucceeded = false

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
            requireTLS = existing.tlsRequired ?? false
            readOnly = existing.readOnly
            authSource = existing.authSource
            useSRV = existing.useSRV
            replicaSet = existing.replicaSet
            directConnection = existing.directConnection
            portFollowsDefault = existing.port == existing.engine.defaultPort
            isProduction = existing.isProduction == true
            group = existing.group ?? ""
            sqliteBusyTimeoutMilliseconds = existing.sqliteBusyTimeoutMilliseconds ?? 5_000
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
            requireTLS = false
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

    enum TLSChoice: Hashable {
        case off, prefer, require
    }

    /// The three states the PostgreSQL sheet offers, over the two stored flags.
    var tlsChoice: TLSChoice {
        get { requireTLS ? .require : (useTLS ? .prefer : .off) }
        set {
            useTLS = newValue != .off
            requireTLS = newValue == .require
        }
    }

    func connection() -> DatabaseConnection {
        var connection = DatabaseConnection(
            id: existingID ?? connectionID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            engine: engine,
            host: engine == .sqlite ? "" : host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username,
            database: database.trimmingCharacters(in: .whitespacesAndNewlines),
            useTLS: useTLS || requireTLS,
            tlsRequired: requireTLS ? true : nil,
            readOnly: readOnly,
            authSource: authSource.trimmingCharacters(in: .whitespacesAndNewlines),
            useSRV: useSRV,
            replicaSet: replicaSet.trimmingCharacters(in: .whitespacesAndNewlines),
            directConnection: directConnection,
            isProduction: isProduction ? true : nil,
            group: group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : group.trimmingCharacters(in: .whitespacesAndNewlines),
            sqliteBusyTimeoutMilliseconds: engine == .sqlite ? sqliteBusyTimeoutMilliseconds : nil
        )
        if connection.name.isEmpty {
            if connection.engine == .sqlite {
                connection.name = connection.isInMemorySQLite
                    ? "In-memory database" : URL(fileURLWithPath: connection.database).lastPathComponent
            } else {
                connection.name = connection.database.isEmpty ? connection.host : connection.database
            }
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
            requireTLS = parsed.tlsRequired ?? false
            authSource = parsed.authSource
            useSRV = parsed.useSRV
            replicaSet = parsed.replicaSet
            directConnection = parsed.directConnection
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = parsed.name }
            portFollowsDefault = port == engine.defaultPort
            urlText = ""
            testSucceeded = false
            status = nil
        } catch {
            status = "Check the URL scheme, host, and percent-encoding."
            testSucceeded = false
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
    var onSQLCatalogChange: ((UUID) -> Void)?
    var selectedConnectionID: UUID?
    var selectedMongoDatabase: String?
    var selectedMongoCollection: String?
    var expanded: Set<String> = []
    var favoriteObjects: Set<String> = []
    var recentObjects: [String] = []
    var productionPrompt: IDEDatabaseProductionPrompt?
    var explorerState: IDEDatabaseExplorerState {
        get { .init(expanded: expanded, favorites: favoriteObjects, recents: recentObjects) }
        set {
            expanded = newValue.expanded
            favoriteObjects = newValue.favorites
            recentObjects = newValue.recents
        }
    }
    var editor: IDEDatabaseConnectionEditor?
    var showsResultsTab = false
    var isRunning = false
    /// The data source whose statement is running, so Cancel knows which connection to stop.
    private(set) var runningConnectionID: UUID?
    private(set) var isCancelling = false
    /// What a user must know about how a source was opened, by source id. Set when a SQLite file had
    /// to be opened through a fallback; cleared on disconnect.
    private(set) var sourceNotes: [UUID: IDEDatabaseSourceNote] = [:]
    var result = IDEDatabaseResult()
    private(set) var scriptResults: [IDEDatabaseResult] = []
    private(set) var selectedScriptResult = 0
    @ObservationIgnored private var executionID: UUID?
    private var resultOwner: UUID?
    private var consoleResults: [UUID: IDEDatabaseResultSet] = [:]
    var banner: String?

    private var sqlSessions: [UUID: SQLSession] = [:]
    private var sqlCatalogs: [UUID: SQLCatalog] = [:]
    private var sqlCatalogLoads: [UUID: Task<Void, Never>] = [:]
    private var sqlCatalogGenerations: [UUID: UUID] = [:]
    private var sqlUnindexedScopes: Set<UUID> = []
    private(set) var sqlScopes: [UUID: IDEDatabaseSQLScope] = [:]
    private(set) var scopeRevisions: [UUID: UUID] = [:]
    private(set) var switchingSQLSourceID: UUID?
    private var connectionAttempts: [UUID: UUID] = [:]
    var connectingIDs: Set<UUID> { Set(connectionAttempts.keys) }
    private var sqlTesting: [UUID: any SQLExecuting] = [:]
    private var mongoSessions: [UUID: MongoSession] = [:]
    var sqlSchemas: [UUID: IDEDatabaseSQLSchema] = [:]
    var mongoSchemas: [UUID: IDEDatabaseMongoSchema] = [:]
    private(set) var sqlTransactions: [UUID: TransactionState] = [:]

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

    func displayedSQLScope(_ source: DatabaseConnection) -> IDEDatabaseSQLScope {
        if let scope = sqlScopes[source.id] { return scope }
        return .init(database: source.sqlLogin(password: "").handshakeDatabase,
                     schema: source.engine == .postgres ? "public" : nil)
    }

    func scopeChangedInConsole(_ connectionID: UUID) -> Bool {
        sqlUnindexedScopes.contains(connectionID)
    }

    func sqlScopeChoices(connectionID: UUID, schemas: Bool) async throws -> [String] {
        guard let session = sqlSessions[connectionID] else { throw DatabaseError.notConnected }
        let names = try await (schemas ? session.schemaNames() : session.databaseNames())
        guard sqlSessions[connectionID] === session else { throw CancellationError() }
        return names
    }

    func mongoScopeChoices(connectionID: UUID, database: String?) async throws -> [String] {
        guard let session = mongoSessions[connectionID] else { throw DatabaseError.notConnected }
        let names: [String]
        if let database {
            if let cached = mongoSchemas[connectionID]?.collections[database] { return cached }
            names = try await session.listCollections(database: database)
            guard mongoSessions[connectionID] === session else { throw CancellationError() }
            mongoSchemas[connectionID]?.collections[database] = names
        } else {
            names = mongoSchemas[connectionID]?.databases ?? []
        }
        return names
    }

    func switchSQLScope(connectionID id: UUID, database: String? = nil, schema: String? = nil) async throws {
        guard let source = catalog.connection(id: id), let oldSession = sqlSessions[id],
              source.engine == .postgres || source.engine == .mysql else { throw DatabaseError.notConnected }
        guard !isRunning, productionPrompt == nil, switchingSQLSourceID == nil else {
            throw DatabaseError.executionFailed("Wait for the current database operation to finish.")
        }
        let current = displayedSQLScope(source)
        let target = IDEDatabaseSQLScope(database: database ?? current.database,
                                         schema: schema ?? (database == nil || database == current.database ? current.schema : nil))
        guard target != current || scopeChangedInConsole(id) else { return }
        switchingSQLSourceID = id
        defer { if switchingSQLSourceID == id { switchingSQLSourceID = nil } }
        guard await oldSession.transactionState() == .none else {
            throw DatabaseError.executionFailed("Finish the transaction before switching database or schema.")
        }
        let password = try keychain.load(account: id.uuidString) ?? ""
        var login = source.sqlLogin(password: password)
        login.database = target.database
        login.postgresSchema = target.schema
        let replacement = try await SQLSession.connect(login: login, readOnly: source.readOnly)
        do {
            let tables = try await replacement.tables()
            try Task.checkCancellation()
            guard sqlSessions[id] === oldSession, catalog.connection(id: id) == source else { throw CancellationError() }
            let previous = detachConnection(id)
            sqlSessions[id] = replacement
            sqlScopes[id] = target
            scopeRevisions[id] = UUID()
            sqlSchemas[id] = IDEDatabaseSQLSchema(tables: tables)
            refreshSQLSnapshots(connectionID: id)
            loadSQLCatalog(connectionID: id)
            await previous.load?.value
            await previous.sql?.disconnect()
        } catch {
            await replacement.disconnect()
            throw error
        }
    }

    func sqlRelation(_ name: String, connectionID: UUID) -> SQLCatalog.Relation? {
        sqlCatalogs[connectionID]?.relation(named: name)
    }

    func databaseDependencies(_ table: String, connectionID: UUID) async throws -> [SQLCatalog.ForeignKey] {
        guard let session = sqlSessions[connectionID] else { throw DatabaseError.notConnected }
        let catalog: SQLCatalog
        if let cached = sqlCatalogs[connectionID] {
            catalog = cached
        } else {
            catalog = try await session.sqlCatalogMetadata().catalog
        }
        guard sqlSessions[connectionID] === session else { throw CancellationError() }
        return catalog.foreignKeys.filter { $0.fromRelation == table || $0.toRelation == table }
    }

    func beginNewConnection() {
        editor = IDEDatabaseConnectionEditor.makeNew()
    }

    /// The data source a new query console binds to: the selection, or the first data
    /// source when a fresh window has none yet. Nil only when no data source exists.
    func connectionForNewConsole() -> DatabaseConnection? {
        if let id = selectedConnectionID, let connection = catalog.connection(id: id) {
            return connection
        }
        return catalog.connections.first
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
        if connection.engine == .sqlite, editor.createsNewFile, !connection.isInMemorySQLite,
           !FileManager.default.fileExists(atPath: connection.database)
        {
            // Making the file is the one thing a SQLite "save" can do that can fail, so say how.
            let path = connection.database
            Task {
                do {
                    try await SQLSession.createSQLiteDatabase(at: path)
                    commitEditor(connection)
                } catch {
                    editor.status = error.localizedDescription
                }
            }
            return
        }
        commitEditor(connection)
    }

    private func commitEditor(_ connection: DatabaseConnection) {
        guard let editor else { return }
        let wasConnected = isConnected(connection.id)
        sqlScopes[connection.id] = nil
        scopeRevisions[connection.id] = UUID()
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

    /// Adds a SQLite file as a data source and connects to it. A file that is already a source is
    /// selected instead of added twice. Existing files are validated (a text file renamed `.db` is
    /// refused with the reason); a new file is created only when `create` is true.
    @discardableResult
    func addSQLiteSource(path: String, readOnly: Bool = false, create: Bool = false) async throws -> DatabaseConnection {
        let standardized = path == ":memory:" ? path : URL(fileURLWithPath: path).standardizedFileURL.path
        if let existing = catalog.connections.first(where: { $0.engine == .sqlite && $0.database == standardized }) {
            selectedConnectionID = existing.id
            if !isConnected(existing.id) { try await connect(existing.id) }
            return existing
        }
        if standardized != ":memory:" {
            if create {
                try await SQLSession.createSQLiteDatabase(at: standardized)
            } else {
                try SQLiteSession.validate(path: standardized)
            }
        }
        let name = standardized == ":memory:" ? "In-memory database" : URL(fileURLWithPath: standardized).lastPathComponent
        let connection = DatabaseConnection(name: name, engine: .sqlite, host: "", database: standardized, readOnly: readOnly)
        catalog.upsert(connection)
        selectedConnectionID = connection.id
        try await connect(connection.id)
        return connection
    }

    func testEditor() async {
        guard let editor, !editor.isTesting else { return }
        editor.isTesting = true
        editor.status = nil
        editor.testSucceeded = false
        defer { editor.isTesting = false }
        let connection = editor.connection()
        do {
            switch connection.engine {
            case .mysql, .postgres:
                try await SQLSession.test(login: connection.sqlLogin(password: editor.password))
            case .sqlite:
                // Opening is the whole test: header check, schema read, and (for a new file) the
                // answer "it does not exist yet" is fine when Save is going to create it.
                if editor.createsNewFile, !FileManager.default.fileExists(atPath: connection.database) {
                    editor.status = "The file will be created when you save."
                    editor.testSucceeded = true
                    return
                }
                let session = try await SQLiteSession.open(connection.sqliteOpenOptions())
                let immutable = await session.serverInfo.features.contains("immutable")
                await session.close()
                editor.status = immutable
                    ? "Connected, read-only and immutable: changes made by other programs will not be seen."
                    : "Connected."
                editor.testSucceeded = true
                return
            case .mongo:
                try await MongoSession.test(login: connection.mongoLogin(password: editor.password))
            }
            editor.status = "Connected."
            editor.testSucceeded = true
        } catch {
            editor.status = IDEDatabaseConnectionDiagnostics.message(error.localizedDescription, engine: connection.engine)
        }
    }

    func remove(_ id: UUID) {
        sqlScopes[id] = nil
        scopeRevisions[id] = nil
        Task { await disconnect(id) }
        catalog.remove(id: id)
        try? keychain.delete(account: id.uuidString)
        if selectedConnectionID == id { selectedConnectionID = nil }
    }

    func connect(_ id: UUID) async throws {
        guard let connection = catalog.connection(id: id) else { return }
        guard switchingSQLSourceID != id else { throw DatabaseError.executionFailed("The source is switching scope.") }
        // An in-memory database exists only inside its one connection. Connecting again would
        // quietly replace it with an empty one, so an open in-memory source is left alone;
        // Disconnect is the explicit way to discard it.
        if connection.isInMemorySQLite, isConnected(id) { return }
        let previous = detachConnection(id)
        let attempt = UUID()
        connectionAttempts[id] = attempt
        defer {
            if connectionAttempts[id] == attempt { connectionAttempts[id] = nil }
        }
        await previous.load?.value
        await previous.sql?.disconnect()
        await previous.mongo?.disconnect()
        guard connectionAttempts[id] == attempt else { throw CancellationError() }
        let password = try keychain.load(account: id.uuidString) ?? ""
        switch connection.engine {
        case .mysql, .postgres, .sqlite:
            var login = connection.sqlLogin(password: password)
            if let scope = sqlScopes[id] {
                login.database = scope.database
                login.postgresSchema = scope.schema
            }
            let session = try await SQLSession.connect(
                login: login, readOnly: connection.readOnly
            )
            let tables: [String]
            let note: IDEDatabaseSourceNote?
            do {
                tables = try await session.tables()
                if let sqlite = session.sqliteSession {
                    note = IDEDatabaseSourceNote(mode: await sqlite.openMode, sourceName: connection.name)
                } else {
                    note = nil
                }
                guard connectionAttempts[id] == attempt, !Task.isCancelled else { throw CancellationError() }
            } catch {
                await session.disconnect()
                throw error
            }
            sqlSessions[id] = session
            sourceNotes[id] = note
            sqlSchemas[id] = IDEDatabaseSQLSchema(tables: tables)
            refreshSQLSnapshots(connectionID: id)
            loadSQLCatalog(connectionID: id)
        case .mongo:
            let session = try await MongoSession.connect(
                login: connection.mongoLogin(password: password), readOnly: connection.readOnly
            )
            let databases: [String]
            do {
                databases = try await session.listDatabases()
                guard connectionAttempts[id] == attempt, !Task.isCancelled else { throw CancellationError() }
            } catch {
                await session.disconnect()
                throw error
            }
            mongoSessions[id] = session
            mongoSchemas[id] = IDEDatabaseMongoSchema(databases: databases)
        }
        selectedConnectionID = id
        expanded.insert(Self.connectionKey(id))
        // A source that had to be opened in a way with a consequence says so, and keeps saying so
        // in the tree for as long as it is connected.
        banner = sourceNotes[id]?.message
    }

    private func loadSQLCatalog(connectionID: UUID, reportErrors: Bool = false) {
        guard let session = sqlSessions[connectionID] else { return }
        sqlCatalogLoads[connectionID]?.cancel()
        let generation = UUID()
        sqlCatalogGenerations[connectionID] = generation
        sqlCatalogLoads[connectionID] = Task { [weak self] in
            do {
                let metadata = try await session.sqlCatalogMetadata()
                guard let self, !Task.isCancelled, sqlCatalogGenerations[connectionID] == generation else { return }
                var catalog = metadata.catalog
                if sqlUnindexedScopes.contains(connectionID) { catalog.isComplete = false }
                sqlCatalogs[connectionID] = catalog
                sqlSchemas[connectionID] = IDEDatabaseSQLSchema(
                    tables: metadata.catalog.relations.map(\.name), columns: metadata.columnsByTable,
                    views: Set(metadata.catalog.relations.filter { $0.kind == .view }.map(\.name))
                )
                refreshSQLSnapshots(connectionID: connectionID)
            } catch {
                if let self, reportErrors, !Task.isCancelled, sqlCatalogGenerations[connectionID] == generation {
                    banner = error.localizedDescription
                }
            }
            if let self, sqlCatalogGenerations[connectionID] == generation { sqlCatalogLoads[connectionID] = nil }
        }
    }

    private func invalidateSQLCatalog(connectionID: UUID) {
        sqlCatalogLoads.removeValue(forKey: connectionID)?.cancel()
        sqlCatalogGenerations[connectionID] = UUID()
        sqlCatalogs[connectionID] = nil
        sqlSchemas[connectionID]?.columns.removeAll()
        refreshSQLSnapshots(connectionID: connectionID)
    }

    func disconnect(_ id: UUID) async {
        let previous = detachConnection(id)
        await previous.load?.value
        await previous.sql?.disconnect()
        await previous.mongo?.disconnect()
    }

    private func detachConnection(_ id: UUID) -> (sql: SQLSession?, mongo: MongoSession?, load: Task<Void, Never>?) {
        let sql = sqlSessions.removeValue(forKey: id)
        let mongo = mongoSessions.removeValue(forKey: id)
        sqlTesting.removeValue(forKey: id)
        let load = sqlCatalogLoads.removeValue(forKey: id)
        load?.cancel()
        connectionAttempts[id] = nil
        sqlCatalogGenerations[id] = nil
        if sqlUnindexedScopes.remove(id) != nil { scopeRevisions[id] = UUID() }
        sqlCatalogs[id] = nil
        sqlSchemas[id] = nil
        sqlTransactions[id] = nil
        mongoSchemas[id] = nil
        sourceNotes[id] = nil
        refreshSQLSnapshots(connectionID: id)
        return (sql, mongo, load)
    }

    func closeAll() {
        productionPrompt?.resolve(false)
        productionPrompt = nil
        executionID = nil
        isRunning = false
        isCancelling = false
        runningConnectionID = nil
        Self.releaseResults([result] + scriptResults + consoleResults.values.flatMap { [$0.result] + $0.scriptResults })
        result = IDEDatabaseResult()
        scriptResults.removeAll()
        consoleResults.removeAll()
        resultOwner = nil
        let sql = Array(sqlSessions.values)
        let mongo = Array(mongoSessions.values)
        let loads = Array(sqlCatalogLoads.values)
        sqlSessions.removeAll()
        for task in loads { task.cancel() }
        sqlCatalogLoads.removeAll()
        connectionAttempts.removeAll()
        sqlCatalogGenerations.removeAll()
        sqlUnindexedScopes.removeAll()
        sqlCatalogs.removeAll()
        sqlTesting.removeAll()
        mongoSessions.removeAll()
        sqlSchemas.removeAll()
        sqlTransactions.removeAll()
        mongoSchemas.removeAll()
        if let provider = sqlCompletionProvider {
            for key in consolesByDocumentID.keys {
                provider.removeSnapshot(for: DocumentID(key))
            }
        }
        Task {
            for load in loads { await load.value }
            for session in sql { await session.disconnect() }
            for session in mongo { await session.disconnect() }
        }
    }

    /// Stores the binding under both the workbench id and the EIP document id, and pushes the
    /// console's first snapshot (tables, no columns yet when freshly connected).
    func bindConsole(workbenchID: UUID, documentID: DocumentID, binding: IDEDatabaseConsoleBinding) {
        if consoles[workbenchID] != binding { discardResults(for: workbenchID) }
        consoles[workbenchID] = binding
        consolesByDocumentID[documentID.uuid] = binding
        pushSnapshot(for: documentID, binding: binding)
    }

    func closeConsole(workbenchID: UUID, documentID: DocumentID) {
        discardResults(for: workbenchID)
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
        onSQLCatalogChange?(connectionID)
    }

    private func pushSnapshot(for documentID: DocumentID, binding: IDEDatabaseConsoleBinding) {
        guard let provider = sqlCompletionProvider else { return }
        guard let connection = catalog.connection(id: binding.connectionID),
              connection.engine != .mongo
        else {
            provider.removeSnapshot(for: documentID)
            return
        }
        if let catalog = sqlCatalogs[binding.connectionID] {
            provider.setSnapshot(SQLCompletionSnapshot(engine: connection.engine, catalog: catalog), for: documentID)
            return
        }
        let schema = sqlSchemas[binding.connectionID]
        // A partial catalog: the tables, and the columns read so far. It is never marked complete
        // here, so the language service completes but does not report "unknown" names.
        let relations = (schema?.tables ?? []).map { table in
            SQLCatalog.Relation(
                name: table,
                columns: schema?.columns[table]?.map {
                    SQLCatalog.Column(
                        name: $0.name, typeName: $0.declaredType, isNotNull: $0.isNotNull, isPrimaryKey: $0.isPrimaryKey,
                        hasDefault: !$0.defaultValue.isEmpty, isGenerated: $0.isGenerated, isIdentityAlways: $0.isIdentityAlways
                    )
                }
            )
        }
        provider.setSnapshot(
            SQLCompletionSnapshot(engine: connection.engine, catalog: SQLCatalog(relations: relations, isComplete: false)),
            for: documentID
        )
    }

    func refreshSource(_ id: UUID) async {
        if let session = mongoSessions[id] {
            do {
                let names = try await session.listDatabases()
                guard mongoSessions[id] === session else { return }
                mongoSchemas[id] = IDEDatabaseMongoSchema(databases: names)
                for name in names where expanded.contains(Self.mongoDatabaseKey(id, name)) {
                    await ensureCollections(connectionID: id, database: name)
                }
            } catch { banner = error.localizedDescription }
        } else {
            loadSQLCatalog(connectionID: id, reportErrors: true)
        }
    }

    func ensureColumns(connectionID: UUID, table: String, refresh: Bool = false) async {
        guard refresh || sqlSchemas[connectionID]?.columns[table] == nil else { return }
        guard let session = sqlSessions[connectionID] else { return }
        let generation = sqlCatalogGenerations[connectionID]
        do {
            let columns = try await session.columns(of: table)
            guard sqlSessions[connectionID] === session, sqlCatalogGenerations[connectionID] == generation else { return }
            sqlSchemas[connectionID]?.columns[table] = columns
            if sqlCatalogs[connectionID] == nil { refreshSQLSnapshots(connectionID: connectionID) }
        } catch {
            banner = error.localizedDescription
        }
    }

    func ensureCollections(connectionID: UUID, database: String, refresh: Bool = false) async {
        guard refresh || mongoSchemas[connectionID]?.collections[database] == nil else { return }
        guard let session = mongoSessions[connectionID] else { return }
        do {
            let names = try await session.listCollections(database: database)
            guard mongoSessions[connectionID] === session else { return }
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
        resetSort: Bool,
        consoleID: UUID? = nil
    ) async {
        await execute(statements: [statement], binding: binding, resetSort: resetSort, consoleID: consoleID)
    }

    func execute(
        statements: [String],
        binding: IDEDatabaseConsoleBinding,
        resetSort: Bool = true,
        consoleID: UUID? = nil
    ) async {
        await execute(preparedStatements: statements.map { IDEDatabaseStatement($0) }, binding: binding,
                      resetSort: resetSort, consoleID: consoleID)
    }

    func execute(
        preparedStatements: [IDEDatabaseStatement],
        binding: IDEDatabaseConsoleBinding,
        resetSort: Bool = true,
        consoleID: UUID? = nil
    ) async {
        guard !preparedStatements.isEmpty, productionPrompt == nil, switchingSQLSourceID == nil else { return }
        showsResultsTab = true
        // One statement at a time per window: a second run would overwrite the first one's header
        // and result while it is still going (audit F-08), and a connection runs one statement at
        // once anyway. Say so instead of silently queueing or dropping it.
        guard !isRunning else {
            banner = "A statement is already running. Cancel it (Database ▸ Cancel Statement) or wait for it to finish."
            return
        }
        if let consoleID, consoles[consoleID] != binding { return }
        guard let connection = catalog.connection(id: binding.connectionID) else {
            if let consoleID { switchResultOwner(to: consoleID) }
            Self.releaseResults([result] + scriptResults)
            result = IDEDatabaseResult()
            scriptResults.removeAll()
            result.error = "That data source was removed."
            return
        }
        if connection.isProduction == true, connection.engine != .mongo, !connection.readOnly {
            let revision = scopeRevisions[connection.id]
            let writes = await runDetached { preparedStatements.filter { !DatabaseQuery.canPage($0.sql) }.map(\.text) }
            guard !Task.isCancelled, !isRunning, productionPrompt == nil, switchingSQLSourceID == nil,
                  scopeRevisions[connection.id] == revision,
                  catalog.connection(id: connection.id) == connection,
                  consoleID == nil || consoleID.flatMap({ consoles[$0] }) == binding else { return }
            if !writes.isEmpty {
                let (stream, decision) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let prompt = IDEDatabaseProductionPrompt(source: connection.name, statements: writes, decision: decision)
                productionPrompt = prompt
                var iterator = stream.makeAsyncIterator()
                let approved = await iterator.next() == true
                if productionPrompt?.id == prompt.id { productionPrompt = nil }
                guard approved, !Task.isCancelled, !isRunning, switchingSQLSourceID == nil,
                      scopeRevisions[connection.id] == revision, catalog.connection(id: connection.id) == connection,
                      consoleID == nil || consoleID.flatMap({ consoles[$0] }) == binding else { return }
            }
        }
        if let consoleID { switchResultOwner(to: consoleID) }
        let execution = UUID()
        executionID = execution
        isRunning = true
        isCancelling = false
        runningConnectionID = connection.id
        if resetSort {
            Self.releaseResults([result] + scriptResults)
            scriptResults.removeAll()
            selectedScriptResult = 0
        } else {
            Self.releaseResults([result])
        }
        defer {
            if executionID == execution {
                if let consoleID, consoles[consoleID] != binding || resultOwner != consoleID {
                    Self.releaseResults([result] + scriptResults)
                    result = IDEDatabaseResult()
                    scriptResults.removeAll()
                }
                executionID = nil
                isRunning = false
                isCancelling = false
                runningConnectionID = nil
            }
        }
        var history: [IDEDatabaseQueryHistory.Attempt] = []
        for statement in preparedStatements {
            guard executionID == execution, !isCancelling, !Task.isCancelled else { break }
            if let consoleID, consoles[consoleID] != binding { break }
            let finished = await executeOne(
                statement, binding: binding, connection: connection, resetSort: resetSort, execution: execution
            )
            guard executionID == execution else { return }
            if history.count == IDEDatabaseQueryHistory.limit { history.removeFirst() }
            history.append(.init(statement: statement.text,
                                 status: result.error != nil ? .failed : (finished ? .completed : .cancelled),
                                 duration: result.duration ?? .zero))
            if resetSort, preparedStatements.count > 1 {
                selectedScriptResult = scriptResults.count
                scriptResults.append(result)
            } else if !resetSort, scriptResults.indices.contains(selectedScriptResult) {
                scriptResults[selectedScriptResult] = result
            }
            if !finished { break }
        }
        if catalog.connection(id: connection.id) != nil {
            await catalog.history.record(history, source: connection.id, engine: connection.engine)
        }
        guard executionID == execution else { return }
        if let session = sqlSessions[connection.id] {
            let transaction = await session.transactionState()
            if executionID == execution, sqlSessions[connection.id] === session {
                sqlTransactions[connection.id] = transaction
                if sqlCatalogs[connection.id] == nil, sqlCatalogLoads[connection.id] == nil,
                   !transaction.isOpen || connection.engine == .sqlite {
                    loadSQLCatalog(connectionID: connection.id)
                }
            }
        }
    }

    func resultSet(for consoleID: UUID?) -> IDEDatabaseResultSet {
        if let consoleID, consoleID != resultOwner { return consoleResults[consoleID] ?? IDEDatabaseResultSet() }
        return IDEDatabaseResultSet(result: result, scriptResults: scriptResults, selection: selectedScriptResult)
    }

    private func switchResultOwner(to consoleID: UUID) {
        guard resultOwner != consoleID else { return }
        if let previous = resultOwner, consoles[previous] != nil { consoleResults[previous] = resultSet(for: previous) }
        let next = consoleResults.removeValue(forKey: consoleID) ?? IDEDatabaseResultSet()
        result = next.result
        scriptResults = next.scriptResults
        selectedScriptResult = next.selection
        resultOwner = consoleID
    }

    private func discardResults(for consoleID: UUID) {
        if let saved = consoleResults.removeValue(forKey: consoleID) {
            Self.releaseResults([saved.result] + saved.scriptResults)
        }
        guard resultOwner == consoleID else { return }
        resultOwner = nil
        if !isRunning {
            Self.releaseResults([result] + scriptResults)
            result = IDEDatabaseResult()
            scriptResults = []
            selectedScriptResult = 0
        } else {
            Task { await cancelRunning() }
        }
    }

    private static func releaseResults(_ results: [IDEDatabaseResult]) {
        var seen: Set<ObjectIdentifier> = []
        let stores = results.compactMap { $0.storage?.store }.filter { seen.insert(ObjectIdentifier($0)).inserted }
        if !stores.isEmpty {
            Task { for store in stores { await store.close() } }
        }
    }

    func selectScriptResult(_ index: Int, consoleID: UUID? = nil) {
        guard !isRunning else { return }
        if let consoleID { switchResultOwner(to: consoleID) }
        guard scriptResults.indices.contains(index) else { return }
        selectedScriptResult = index
        result = scriptResults[index]
    }

    private func executeOne(
        _ statement: IDEDatabaseStatement,
        binding: IDEDatabaseConsoleBinding,
        connection: DatabaseConnection,
        resetSort: Bool,
        execution: UUID
    ) async -> Bool {
        let sortColumn = resetSort ? nil : result.sortColumn
        let sortAscending = resetSort || result.sortAscending
        let storage = IDEDatabaseResultStorage()
        let store = storage.store
        result = IDEDatabaseResult(
            pageSize: connection.engine == .mongo ? DatabasePageSize.mongo : DatabasePageSize.sql,
            canSort: connection.engine == .mongo || DatabaseQuery.canPage(statement.sql), storage: storage,
            sortColumn: sortColumn, sortAscending: sortAscending, statement: statement.text,
            preparedStatement: statement, connectionID: connection.id,
            mongoDatabase: binding.mongoDatabase, mongoCollection: binding.mongoCollection, engine: connection.engine,
            scopeRevision: scopeRevisions[connection.id]
        )
        let started = ContinuousClock.now
        let updates = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await store.snapshot
                guard let self, !Task.isCancelled, executionID == execution, result.storage == storage else { return }
                publishResultSnapshot(snapshot)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer {
            updates.cancel()
            if executionID == execution { result.duration = started.duration(to: .now) }
        }
        do {
            try await ensureConnected(connection)
            guard executionID == execution else { return false }
            guard !isCancelling, !Task.isCancelled else {
                result.message = "Cancelled"
                return false
            }
            let summary: ExecutionSummary
            if connection.engine == .mongo {
                guard let database = binding.mongoDatabase, let collection = binding.mongoCollection else {
                    throw DatabaseError.executionFailed("Select a collection before running a filter.")
                }
                guard let session = mongoSessions[connection.id] else { throw DatabaseError.notConnected }
                summary = try await session.find(
                    database: database,
                    collection: collection,
                    filterJSON: statement.text,
                    sortKey: result.sortColumn,
                    sortAscending: result.sortAscending,
                    into: store
                )
            } else {
                let liveSession = sqlSessions[connection.id]
                let session: any SQLExecuting
                if let testing = sqlTesting[connection.id] {
                    session = testing
                } else if let liveSession {
                    session = liveSession
                } else {
                    throw DatabaseError.notConnected
                }
                let impact = Self.catalogImpact(of: statement.sql, engine: connection.engine)
                if impact != .none, liveSession != nil {
                    invalidateSQLCatalog(connectionID: connection.id)
                }
                summary = try await DatabaseQuery.execute(
                    statement: statement.sql,
                    readOnly: connection.readOnly,
                    sortColumn: result.sortColumn,
                    sortAscending: result.sortAscending,
                    engine: connection.engine,
                    using: session,
                    parameters: statement.parameters,
                    into: store
                )
                if impact == .scope, !summary.wasCancelled,
                   let liveSession, sqlSessions[connection.id] === liveSession {
                    sqlUnindexedScopes.insert(connection.id)
                    scopeRevisions[connection.id] = UUID()
                }
            }
            await store.finish()
            let snapshot = await store.snapshot
            guard executionID == execution else { return false }
            publishResultSnapshot(snapshot)
            result.notices = summary.notices
            result.hasCompleteRows = !summary.wasCancelled && !summary.limitReached
            result.message = Self.message(for: summary, engine: connection.engine)
            let size = result.pageSize
            let preview = try await Self.readPreview(from: store, range: 0..<size, engine: connection.engine)
            guard executionID == execution else { return false }
            result.rows = preview
            return !summary.wasCancelled
        } catch {
            guard executionID == execution else { return false }
            updates.cancel()
            result.storage = nil
            result.columns = []
            result.rowCount = 0
            await store.close()
            guard executionID == execution else { return false }
            result.error = error.localizedDescription
            if let error = error as? DatabaseServerError, let position = error.position,
               let dialect = SQLDialect(engine: connection.engine),
               let range = statement.errorRange(at: position, dialect: dialect) {
                result.sourceError = IDEDatabaseExecutionError(range: range, message: error.localizedDescription, code: error.code)
            }
            return false
        }
    }

    private func publishResultSnapshot(_ snapshot: ResultStore.Snapshot) {
        if snapshot.rowCount != result.rowCount { result.rowCount = snapshot.rowCount }
        let columns = snapshot.columns.map(\.name)
        if columns != result.columns { result.columns = columns }
    }

    nonisolated private static func readPreview(
        from store: ResultStore, range: Range<Int>, engine: DatabaseEngine
    ) async throws -> [[String?]] {
        try await store.mapRows(in: range) { row in
            row.map { value in engine == .mongo && value.isNull ? "null" : value.displayText() }
        }
    }

    private static func message(for summary: ExecutionSummary, engine: DatabaseEngine) -> String {
        if summary.wasCancelled {
            return summary.rowCount == 0 ? "Cancelled" : "Cancelled after \(summary.rowCount.formatted()) rows"
        }
        if summary.columns.isEmpty, engine != .mongo {
            return message(for: QueryResult(columns: [], rows: [], rowsAffected: summary.affectedRows, isReadQuery: false))
        }
        let unit = engine == .mongo ? "documents" : "rows"
        return "\(summary.rowCount.formatted()) \(unit)"
    }

    private enum CatalogImpact { case none, schema, scope }

    private static func catalogImpact(of statement: String, engine: DatabaseEngine) -> CatalogImpact {
        guard let dialect = SQLDialect(engine: engine) else { return .none }
        let tokens = SQLLexer(statement, dialect: dialect).tokenize().lazy.filter { $0.kind != .comment }
        guard tokens.first?.kind == .word else { return .none }
        let source = statement as NSString
        let words = tokens.prefix(5).map { source.substring(with: $0.range).uppercased() }
        switch words.first {
        case "CREATE" where words.dropFirst().prefix(3).contains(where: { $0 == "TEMP" || $0 == "TEMPORARY" }):
            return .scope
        case "ATTACH", "DETACH", "USE":
            return .scope
        case "SET" where dialect == .postgres, "RESET" where dialect == .postgres:
            return words.contains { ["SEARCH_PATH", "\"SEARCH_PATH\"", "ROLE", "AUTHORIZATION", "ALL"].contains($0) }
                ? .scope : .none
        case "SET" where dialect == .mysql && words.contains("ROLE"):
            return .scope
        case "CREATE", "ALTER", "DROP", "RENAME", "GRANT", "REVOKE",
             "COMMIT", "ROLLBACK", "END", "ABORT", "RELEASE", "RESET", "DISCARD":
            return .schema
        default:
            return .none
        }
    }

    /// What the results bar says about a finished statement. A statement that returns no columns
    /// reports how many rows it changed when the server said, which is what makes a stray
    /// `UPDATE` with the wrong `WHERE` visible ("4,812 rows affected") instead of "completed".
    static func message(for result: QueryResult) -> String {
        if result.wasCancelled {
            return result.rows.isEmpty ? "Cancelled" : "Cancelled after \(result.rows.count) rows"
        }
        if result.columns.isEmpty {
            guard let affected = result.rowsAffected else { return "Statement completed." }
            return "\(affected.formatted()) \(affected == 1 ? "row" : "rows") affected"
        }
        return "\(result.rows.count) rows"
    }

    /// Asks the server to stop the statement that is running. The statement's own call returns
    /// when it has stopped, with whatever rows had arrived; this returns once the request is sent.
    func cancelRunning() async {
        guard isRunning, !isCancelling, let id = runningConnectionID else { return }
        isCancelling = true
        if let session = sqlSessions[id] { await session.cancelRunning() }
        if let session = mongoSessions[id] { await session.cancelRunning() }
    }

    func sort(by column: String, consoleID: UUID? = nil) async {
        guard !isRunning, switchingSQLSourceID == nil else { return }
        if let consoleID { switchResultOwner(to: consoleID) }
        guard result.canSort, let id = result.connectionID, result.scopeRevision == scopeRevisions[id],
              let statement = result.preparedStatement else { return }
        if result.sortColumn == column {
            result.sortAscending.toggle()
        } else {
            result.sortColumn = column
            result.sortAscending = true
        }
        // Both engines sort on the server and reload from the first page: a sort of only the
        // rows on screen would show a different order than the data has.
        let binding = IDEDatabaseConsoleBinding(
            connectionID: id, mongoDatabase: result.mongoDatabase, mongoCollection: result.mongoCollection
        )
        await execute(preparedStatements: [statement], binding: binding, resetSort: false, consoleID: resultOwner)
    }

    func installSQLSessionForTesting(_ session: any SQLExecuting, id: UUID) {
        sqlTesting[id] = session
    }

    static func connectionKey(_ id: UUID) -> String { IDEDatabaseTree.connectionKey(id) }
    static func schemaKey(_ id: UUID) -> String { IDEDatabaseTree.schemaKey(id) }
    static func tableKey(_ id: UUID, _ table: String) -> String { IDEDatabaseTree.tableKey(id, table) }
    static func mongoDatabaseKey(_ id: UUID, _ name: String) -> String {
        IDEDatabaseTree.mongoDatabaseKey(id, name)
    }
}

/// How a SQLite source was opened, when that has a consequence. Shown in the tree and in a banner.
struct IDEDatabaseSourceNote: Equatable {
    let mode: SQLiteSession.OpenMode
    let sourceName: String

    /// Nil for an ordinary open: there is nothing to say.
    init?(mode: SQLiteSession.OpenMode, sourceName: String) {
        guard mode != .normal else { return nil }
        self.mode = mode
        self.sourceName = sourceName
    }

    /// The short tag after the source's name in the tree.
    var tag: String {
        switch mode {
        case .normal: ""
        case .queryOnlyFallback: "read-only (query only)"
        case .immutable: "immutable, may be out of date"
        }
    }

    var message: String {
        switch mode {
        case .normal:
            ""
        case .queryOnlyFallback:
            "\(sourceName) is in WAL mode and has no -wal or -shm files, which SQLite needs to open it read-only. It was opened with every write blocked instead; SQLite may have created those two files next to the database. No data is written."
        case .immutable:
            "\(sourceName) was opened immutable because its folder is read-only: only the main file is read, so changes another program makes (or has not yet merged from its WAL) are not shown, and a write in progress can show inconsistent data. Do not rely on this view for current data."
        }
    }
}
