import DatabaseKit
import EditorIntelligence
import Foundation
import Observation

/// Which data source an untitled console tab runs against.
struct IDEDatabaseConsoleBinding: Codable, Equatable, Sendable {
    var connectionID: UUID
    var mongoDatabase: String?
    var mongoCollection: String?
    var sqliteBrowseTable: String?
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
    var pendingEdits: IDEDatabasePendingEdits?
    var sqliteBrowseTable: String?
    /// Why the result cannot be edited, when the app checked. Nil while it is editable or unchecked.
    var readOnlyReason: String?
    /// The table and key the server verified for this result's rows, whether or not they may be
    /// written. Reading a large value and following a foreign key need only this.
    var rowSource: IDEDatabaseEditTarget?
}

/// One step of following relationships in a console: the query that produced the result.
struct IDEDatabaseNavigationEntry: Equatable {
    let title: String
    let statement: IDEDatabaseStatement
    let binding: IDEDatabaseConsoleBinding
    let scopeRevision: UUID?
}

/// Back and forward through the results a console showed by following foreign keys. Going back
/// re-runs the earlier query: the history keeps statements, not rows.
struct IDEDatabaseNavigationHistory: Equatable {
    private(set) var entries: [IDEDatabaseNavigationEntry] = []
    private(set) var index = 0

    static let limit = 50

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < entries.count }
    var current: IDEDatabaseNavigationEntry? { entries.indices.contains(index) ? entries[index] : nil }
    var backTitle: String? { canGoBack ? entries[index - 1].title : nil }
    var forwardTitle: String? { canGoForward ? entries[index + 1].title : nil }

    /// Starts the history at the query the console was showing.
    init(origin: IDEDatabaseNavigationEntry) { entries = [origin] }

    /// A new hop discards whatever was ahead, like a browser.
    mutating func visit(_ entry: IDEDatabaseNavigationEntry) {
        entries.removeSubrange((index + 1)...)
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        index = entries.count - 1
    }

    mutating func move(by offset: Int) -> IDEDatabaseNavigationEntry? {
        let target = index + offset
        guard entries.indices.contains(target) else { return nil }
        index = target
        return entries[target]
    }
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
    /// Batches applied inside a console's open transaction, per connection. A later statement
    /// replaces the result that showed them, so the outcome is tracked here, not on the result.
    @ObservationIgnored private var submittedBatches: [UUID: [IDEDatabasePendingEdits]] = [:]
    @ObservationIgnored private var sqliteMutationTask: Task<SQLMutationResult, Error>?
    private var resultOwner: UUID?
    /// Relationship hops per console, for Back and Forward. A statement the user runs ends it.
    private(set) var navigationHistories: [UUID: IDEDatabaseNavigationHistory] = [:]
    @ObservationIgnored private var isNavigating = false
    private static let anonymousConsole = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
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
    private(set) var databaseSavepoints: [UUID: [String]] = [:]

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
        guard !refuseDisconnecting(source: connection.id) else {
            editor.status = banner
            editor.testSucceeded = false
            return
        }
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
        guard !refuseDisconnecting(source: id) else { return }
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
        if isConnected(id), refuseDisconnecting(source: id) {
            throw DatabaseError.executionFailed(banner ?? Self.pendingEditMessage)
        }
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
        guard !refuseDisconnecting(source: id) else { return }
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
        if sqlTransactions[id]?.isOpen == true { noteTransactionBoundary(connectionID: id, .ended) }
        sqlTransactions[id] = nil
        databaseSavepoints[id] = nil
        mongoSchemas[id] = nil
        sourceNotes[id] = nil
        refreshSQLSnapshots(connectionID: id)
        return (sql, mongo, load)
    }

    func closeAll() {
        sqliteMutationTask?.cancel()
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
        databaseSavepoints.removeAll()
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
        if consoles[workbenchID] != binding {
            guard !refuseDiscardingEdits(consoleID: workbenchID) else { return }
            discardResults(for: workbenchID)
        }
        consoles[workbenchID] = binding
        consolesByDocumentID[documentID.uuid] = binding
        pushSnapshot(for: documentID, binding: binding)
    }

    func closeConsole(workbenchID: UUID, documentID: DocumentID) {
        guard !refuseDiscardingEdits(consoleID: workbenchID) else { return }
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
        guard !refuseDiscardingEdits(consoleID: consoleID) else { return }
        if resetSort, !isNavigating { navigationHistories[historyKey(consoleID)] = nil }
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
                let wasOpen = sqlTransactions[connection.id]?.isOpen == true
                sqlTransactions[connection.id] = transaction
                if !transaction.isOpen { databaseSavepoints[connection.id] = nil }
                if wasOpen, !transaction.isOpen { noteTransactionBoundary(connectionID: connection.id, .ended) }
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

    private static let pendingEditMessage = "Submit or revert the staged database edits first."

    func refuseDiscardingEdits(consoleID: UUID?) -> Bool {
        let current = resultSet(for: consoleID)
        let pending = ([current.result] + current.scriptResults).contains { $0.pendingEdits?.hasChanges == true }
        if pending { banner = Self.pendingEditMessage }
        return pending
    }

    var closeBlocker: String? {
        if storedResults.contains(where: { $0.pendingEdits?.hasChanges == true }) { return Self.pendingEditMessage }
        if sqlTransactions.values.contains(where: \.isOpen) { return "Commit or roll back the open database transaction first." }
        if isRunning { return "Wait for the running database operation or cancel it first." }
        return nil
    }

    private var storedResults: [IDEDatabaseResult] {
        [result] + scriptResults + consoleResults.values.flatMap { [$0.result] + $0.scriptResults }
    }

    private func refuseDisconnecting(source: UUID) -> Bool {
        if storedResults.contains(where: { $0.connectionID == source && $0.pendingEdits?.hasChanges == true }) {
            banner = Self.pendingEditMessage
        } else if runningConnectionID == source {
            banner = "Wait for the running database operation or cancel it first."
        } else if sqlTransactions[source]?.isOpen == true {
            banner = "Commit or roll back the transaction before changing the connection."
        } else {
            return false
        }
        return true
    }

    func performTransaction(_ action: IDEDatabaseTransactionAction, connectionID: UUID) async {
        guard !isRunning, switchingSQLSourceID == nil, productionPrompt == nil,
              let session = sqlSessions[connectionID],
              let source = catalog.connection(id: connectionID), !source.readOnly,
              sourceNotes[connectionID] == nil else { return }
        isRunning = true
        runningConnectionID = connectionID
        isCancelling = false
        defer {
            isRunning = false
            runningConnectionID = nil
            isCancelling = false
        }
        do {
            let state = await session.transactionState()
            switch action {
            case .begin(let options):
                guard !state.isOpen else { return }
                try await session.beginTransaction(options)
            case .commit, .rollback:
                guard state.isOpen else { return }
                let commit: Bool = if case .commit = action { true } else { false }
                guard !commit || state != .aborted else { return }
                try await session.endTransaction(commit: commit)
                noteTransactionBoundary(connectionID: connectionID, commit ? .committed : .rolledBack)
                databaseSavepoints[connectionID] = nil
                invalidateSQLCatalog(connectionID: connectionID)
                loadSQLCatalog(connectionID: connectionID)
            case .savepoint, .rollbackTo, .release:
                guard state.isOpen else { return }
                var names = databaseSavepoints[connectionID] ?? []
                var rolledBackTo: String?
                let sql: String
                switch action {
                case .savepoint:
                    guard state != .aborted, names.count < 32 else { return }
                    let name = "umbra_" + UUID().uuidString.prefix(8).lowercased()
                    sql = "SAVEPOINT \(name)"
                    names.append(name)
                case .rollbackTo(let name):
                    guard let index = names.firstIndex(of: name) else { return }
                    sql = "ROLLBACK TO SAVEPOINT \(name)"
                    names = Array(names[...index])
                    rolledBackTo = name
                case .release(let name):
                    guard state != .aborted, let index = names.firstIndex(of: name) else { return }
                    sql = "RELEASE SAVEPOINT \(name)"
                    if source.engine == .mysql { names.remove(at: index) }
                    else { names = Array(names[..<index]) }
                default: return
                }
                let store = ResultStore(columns: [])
                let summary = try await session.execute(sql, parameters: [], into: store)
                await store.close()
                guard !summary.wasCancelled else { return }
                databaseSavepoints[connectionID] = names
                if let rolledBackTo { noteTransactionBoundary(connectionID: connectionID, .rolledBackTo(rolledBackTo.lowercased())) }
            }
        } catch { banner = error.localizedDescription }
        if sqlSessions[connectionID] === session { sqlTransactions[connectionID] = await session.transactionState() }
    }

    /// Applies the staged batch. Without an open transaction it commits on its own. With one it
    /// runs under a savepoint and stays *submitted*: the user's Commit or Rollback decides it.
    /// Returns false when the batch stayed staged (a conflict or a rejected row); the pending
    /// object says which row.
    func submitEdits(
        _ pending: IDEDatabasePendingEdits, storage: IDEDatabaseResultStorage, consoleID: UUID?
    ) async throws -> Bool {
        let current = resultSet(for: consoleID).result
        guard !isRunning, switchingSQLSourceID == nil, productionPrompt == nil,
              current.storage == storage, current.pendingEdits === pending, pending.isLocal,
              let connectionID = current.connectionID,
              let source = catalog.connection(id: connectionID), !source.readOnly else {
            throw DatabaseError.executionFailed("The editable result or its writable connection is no longer available.")
        }
        let target = pending.target
        let work: @Sendable ([SQLiteRowMutation]) async throws -> SQLMutationResult
        let cancel: @Sendable () -> Void
        switch target.engine {
        case .sqlite:
            guard let session = sqlSessions[connectionID]?.sqliteSession,
                  session.options.location == source.sqliteOpenOptions().location else {
                throw DatabaseError.executionFailed("The editable result or its writable SQLite session is no longer available.")
            }
            work = { try await session.applyMutations($0, table: target.table, schemaVersion: target.schemaVersion) }
            cancel = { session.cancelRunning() }
        case .postgres, .mysql:
            guard let session = sqlSessions[connectionID], let sql = target.sql else {
                throw DatabaseError.executionFailed("The editable result or its writable connection is no longer available.")
            }
            work = { mutations in
                try await session.applyUpdates(mutations.compactMap { if case .update(let update) = $0 { update } else { nil } }, target: sql)
            }
            cancel = { Task { await session.cancelRunning() } }
        case .mongo:
            guard let session = mongoSessions[connectionID], let database = target.mongoDatabase else {
                throw DatabaseError.executionFailed("The editable result or its writable connection is no longer available.")
            }
            work = { mutations in
                let updates = mutations.compactMap { mutation -> MongoFieldUpdate? in
                    if case .update(let update) = mutation { target.mongoUpdate(update) } else { nil }
                }
                guard updates.count == mutations.count else {
                    throw DatabaseError.executionFailed("MongoDB edits are field updates only.")
                }
                return try await session.applyFieldUpdates(database: database, collection: target.table, updates: updates)
            }
            cancel = { Task { await session.cancelRunning() } }
        }
        let preview = pending.preview()
        guard !preview.isEmpty else { return false }
        isRunning = true
        isCancelling = false
        runningConnectionID = connectionID
        let mutations = preview.map(\.mutation)
        let task = Task { try await work(mutations) }
        sqliteMutationTask = task
        defer {
            sqliteMutationTask = nil
            isRunning = false
            isCancelling = false
            runningConnectionID = nil
        }
        do {
            let outcome = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                cancel()
            }
            if outcome.leftTransactionOpen {
                pending.markSubmitted(savepoints: databaseSavepoints[connectionID] ?? [])
                submittedBatches[connectionID, default: []].append(pending)
            } else {
                pending.markCommitted()
            }
            if target.engine != .mongo, sqlSessions[connectionID] != nil {
                sqlTransactions[connectionID] = await sqlSessions[connectionID]?.transactionState() ?? .none
            }
            return true
        } catch let conflict as SQLiteOptimisticConflict {
            pending.markConflict(conflict, in: preview)
            return false
        } catch let failure as SQLiteMutationFailure {
            pending.markRejected(failure, in: preview)
            return false
        }
    }

    /// Asks the server whether this result is editable and attaches the answer to whichever stored
    /// result still holds the storage. The console never waits for it, and a later query simply
    /// replaces the result it was for.
    private func resolveEditTarget(
        for session: SQLSession, columns: [ResultColumn], storage: IDEDatabaseResultStorage, connectionID: UUID,
        writable: Bool
    ) {
        Task { @MainActor [weak self] in
            let resolution = await session.resolveRowSource(columns: columns)
            guard let self, self.sqlSessions[connectionID] === session else { return }
            @MainActor func attach(_ result: inout IDEDatabaseResult) {
                guard result.storage == storage, result.pendingEdits == nil, result.rowSource == nil else { return }
                switch resolution {
                case .editable(let target):
                    if let editTarget = IDEDatabaseEditTarget(sql: target, columns: columns) {
                        result.rowSource = editTarget
                        if writable {
                            result.pendingEdits = IDEDatabasePendingEdits(target: editTarget)
                            result.readOnlyReason = nil
                        } else {
                            result.readOnlyReason = "This connection is read-only."
                        }
                    } else {
                        result.readOnlyReason = "The key could not be matched to the result."
                    }
                case .readOnly(let reason): result.readOnlyReason = reason
                }
            }
            attach(&self.result)
            for index in self.scriptResults.indices { attach(&self.scriptResults[index]) }
            for key in self.consoleResults.keys {
                guard var saved = self.consoleResults[key] else { continue }
                attach(&saved.result)
                for index in saved.scriptResults.indices { attach(&saved.scriptResults[index]) }
                self.consoleResults[key] = saved
            }
        }
    }

    /// The whole value of one cell, read from the database by the row's verified key. This is a
    /// live read, so it can differ from what the grid stored when the query ran.
    func fetchFullValue(in result: IDEDatabaseResult, row: Int, column: Int) async throws -> DatabaseValue {
        guard !isRunning, let id = result.connectionID, let target = result.rowSource, let storage = result.storage,
              scopeRevisions[id] == result.scopeRevision, let name = target.sourceNames[column] else {
            throw DatabaseError.executionFailed("This result's rows are not tied to a verified table and key, so the value cannot be re-read.")
        }
        guard let values = try await storage.store.mapRows(in: row..<(row + 1), { $0 }).first,
              let keys = target.keyValues(values: values) else {
            throw DatabaseError.executionFailed("This row has no complete key value to read it by.")
        }
        switch target.engine {
        case .sqlite:
            guard let session = sqlSessions[id] else { throw DatabaseError.notConnected }
            return try await session.fetchFullSQLiteValue(table: target.table, column: name, keys: keys)
        case .postgres, .mysql:
            guard let session = sqlSessions[id], let sql = target.sql else { throw DatabaseError.notConnected }
            return try await session.fetchFullValue(column: name, keys: keys, target: sql)
        case .mongo:
            guard let session = mongoSessions[id], let database = target.mongoDatabase, let key = keys.first?.value else {
                throw DatabaseError.notConnected
            }
            return try await session.fetchFullValue(database: database, collection: target.table, id: key, field: name)
        }
    }

    /// Tells every result of this connection that a transaction ended, so a batch that was
    /// submitted into it shows committed, rolled back, or unknown.
    private func noteTransactionBoundary(connectionID: UUID, _ boundary: IDEDatabasePendingEdits.Boundary) {
        guard let batches = submittedBatches[connectionID] else { return }
        for batch in batches { batch.noteBoundary(boundary) }
        let waiting = batches.filter { $0.phase == .submitted }
        submittedBatches[connectionID] = waiting.isEmpty ? nil : waiting
    }

    /// COMMIT / END, ROLLBACK and ROLLBACK TO, read from the statement's own words.
    nonisolated static func transactionBoundary(of statement: String, engine: DatabaseEngine) -> IDEDatabasePendingEdits.Boundary? {
        guard let dialect = SQLDialect(engine: engine) else { return nil }
        let source = statement as NSString
        let words = Array(SQLLexer(statement, dialect: dialect).tokenize().lazy.filter { $0.kind != .comment }
            .prefix(4).map { source.substring(with: $0.range).uppercased() })
        switch words.first {
        case "COMMIT", "END": return .committed
        case "ROLLBACK":
            guard words.count > 1, words[1] == "TO" else { return .rolledBack }
            let name = words.dropFirst(2).first { $0 != "SAVEPOINT" }
            return name.map { .rolledBackTo($0.trimmingCharacters(in: CharacterSet(charactersIn: "\"`[]")).lowercased()) } ?? .rolledBack
        default: return nil
        }
    }

    private func historyKey(_ consoleID: UUID?) -> UUID { consoleID ?? resultOwner ?? Self.anonymousConsole }

    func navigationHistory(for consoleID: UUID?) -> IDEDatabaseNavigationHistory? {
        navigationHistories[historyKey(consoleID)]
    }

    /// Runs a related-rows query in the console that holds the result, remembering where it came
    /// from so Back returns to it.
    func followRelation(_ query: IDEDatabaseResultQuery, consoleID: UUID?) async {
        let key = historyKey(consoleID)
        let current = resultSet(for: consoleID).result
        guard !isRunning, !refuseDiscardingEdits(consoleID: consoleID),
              let id = current.connectionID, id == query.binding.connectionID,
              scopeRevisions[id] == query.scopeRevision, current.scopeRevision == query.scopeRevision,
              let origin = current.preparedStatement else { return }
        let binding = consoleID.flatMap { consoles[$0] } ?? query.binding
        let entry = IDEDatabaseNavigationEntry(
            title: query.title, statement: IDEDatabaseStatement(query.sql, parameters: query.parameters),
            binding: binding, scopeRevision: query.scopeRevision)
        var history = navigationHistories[key] ?? IDEDatabaseNavigationHistory(origin: .init(
            title: "Original query", statement: origin, binding: binding, scopeRevision: current.scopeRevision))
        history.visit(entry)
        navigationHistories[key] = history
        await runNavigation(entry, consoleID: consoleID)
    }

    /// Back (-1) or forward (+1): the earlier query runs again, so what shows is current data.
    func navigateHistory(by offset: Int, consoleID: UUID?) async {
        let key = historyKey(consoleID)
        guard !isRunning, !refuseDiscardingEdits(consoleID: consoleID),
              var history = navigationHistories[key], let entry = history.move(by: offset) else { return }
        guard scopeRevisions[entry.binding.connectionID] == entry.scopeRevision else {
            banner = "The database scope changed since that result, so it cannot be re-run from the history."
            navigationHistories[key] = nil
            return
        }
        navigationHistories[key] = history
        await runNavigation(entry, consoleID: consoleID)
    }

    private func runNavigation(_ entry: IDEDatabaseNavigationEntry, consoleID: UUID?) async {
        isNavigating = true
        defer { isNavigating = false }
        await execute(preparedStatements: [entry.statement], binding: entry.binding, resetSort: true, consoleID: consoleID)
    }

    /// Foreign-key hops from one cell: the row it points at and the rows that point at its row.
    /// Only declared keys count, and only for a result whose table and key the server verified.
    func relatedRows(in result: IDEDatabaseResult, row: Int, columnIndex: Int) async throws -> [IDEDatabaseResultQuery] {
        guard let id = result.connectionID, let target = result.rowSource, let column = target.sourceNames[columnIndex],
              let storage = result.storage, scopeRevisions[id] == result.scopeRevision else { return [] }
        let table = target.table
        let keys = try await databaseDependencies(table, connectionID: id)
        guard !keys.isEmpty else { return [] }
        let sourceNames = target.sourceNames
        let values = try await storage.store.mapRows(in: row..<(row + 1)) { cells in
            var values: [String: DatabaseValue] = [:]
            for (index, name) in sourceNames where cells.indices.contains(index) { values[name] = cells[index] }
            return values
        }
        guard let values = values.first else { return [] }
        let binding = IDEDatabaseConsoleBinding(connectionID: id)
        switch target.engine {
        case .sqlite:
            return try IDEDatabaseResultQuery.make(table: table, column: column, values: values, keys: keys,
                                                   binding: binding, scopeRevision: result.scopeRevision)
        case .postgres, .mysql:
            guard let session = sqlSessions[id], let schema = target.schema else { throw DatabaseError.notConnected }
            var types: [String: [String: String]] = [:]
            for relation in Set(keys.flatMap { [$0.fromRelation, $0.toRelation] }) where relation != table || types[relation] == nil {
                types[relation] = Dictionary(try await session.columns(of: relation).map { ($0.name, $0.declaredType) },
                                             uniquingKeysWith: { first, _ in first })
            }
            guard scopeRevisions[id] == result.scopeRevision, sqlSessions[id] === session else { throw CancellationError() }
            return try IDEDatabaseResultQuery.make(
                engine: target.engine, schema: schema, table: table, column: column, values: values, keys: keys,
                typeOf: { types[$0]?[$1] }, binding: binding, scopeRevision: result.scopeRevision)
        case .mongo:
            return []
        }
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
        navigationHistories[consoleID] = nil
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
                if !summary.wasCancelled {
                    if let target = IDEDatabaseEditTarget(mongoDatabase: database, collection: collection, columns: summary.columns) {
                        result.rowSource = target
                        if connection.readOnly {
                            result.readOnlyReason = "This connection is read-only."
                        } else {
                            result.pendingEdits = IDEDatabasePendingEdits(target: target)
                        }
                    } else {
                        result.readOnlyReason = "The result has no _id column, so documents cannot be identified."
                    }
                }
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
                let browse = Self.sqliteBrowseTable(binding: binding, statement: statement, connection: connection)
                let sqlite = browse == nil ? nil : liveSession?.sqliteSession
                let version = try? await sqlite?.pragma("schema_version")
                // A table with no key is edited through its rowid, which has to be in the result.
                let info = browse == nil ? nil : try? await sqlite?.tableInfo(table: browse ?? "")
                let rowIDAlias = connection.readOnly ? nil : info.flatMap(IDEDatabaseSQLiteEditTarget.rowIDAlias(for:))
                let sql = rowIDAlias.flatMap { alias in
                    browse.flatMap { Self.rowIDSelect(table: $0, alias: alias, statement: statement.sql) }
                } ?? statement.sql
                summary = try await DatabaseQuery.execute(
                    statement: sql,
                    readOnly: connection.readOnly,
                    sortColumn: result.sortColumn,
                    sortAscending: result.sortAscending,
                    engine: connection.engine,
                    using: session,
                    parameters: statement.parameters,
                    into: store
                )
                if executionID == execution, !summary.wasCancelled { result.sqliteBrowseTable = browse }
                if let sqlite, let info, let version, let number = Int(version), !summary.wasCancelled,
                   (try? await sqlite.pragma("schema_version")) == version, executionID == execution,
                   sqlSessions[connection.id] === liveSession {
                    let rowIDColumn = rowIDAlias == nil ? nil : 0
                    if let target = IDEDatabaseSQLiteEditTarget(table: info, columns: summary.columns, schemaVersion: number,
                                                                rowIDColumn: rowIDColumn) {
                        result.rowSource = target
                        if connection.readOnly {
                            result.readOnlyReason = "This connection is read-only."
                        } else {
                            result.pendingEdits = IDEDatabasePendingEdits(target: target)
                        }
                    } else {
                        result.readOnlyReason = IDEDatabaseSQLiteEditTarget.readOnlyReason(
                            table: info, columns: summary.columns, rowIDColumn: rowIDColumn)
                    }
                }
                if !summary.wasCancelled, liveSession != nil,
                   let boundary = Self.transactionBoundary(of: statement.sql, engine: connection.engine) {
                    // PostgreSQL answers COMMIT on an aborted transaction with the tag ROLLBACK.
                    noteTransactionBoundary(connectionID: connection.id,
                                            summary.commandTag?.uppercased() == "ROLLBACK" ? .rolledBack : boundary)
                }
                if connection.engine != .sqlite, !summary.wasCancelled, !summary.columns.isEmpty {
                    if let liveSession {
                        resolveEditTarget(for: liveSession, columns: summary.columns, storage: storage,
                                          connectionID: connection.id, writable: !connection.readOnly)
                    }
                } else if connection.engine == .sqlite, browse == nil, !summary.columns.isEmpty {
                    result.readOnlyReason = "Open the table from the explorer to edit it."
                }
                if impact == .scope, !summary.wasCancelled,
                   let liveSession, sqlSessions[connection.id] === liveSession {
                    sqlUnindexedScopes.insert(connection.id)
                    scopeRevisions[connection.id] = UUID()
                }
                if !summary.wasCancelled,
                   ["SAVEPOINT", "RELEASE", "ROLLBACK"].contains(summary.commandTag?.uppercased() ?? "") {
                    databaseSavepoints[connection.id] = nil
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

    private static func rowIDSelect(table: String, alias: String) -> String? {
        guard let name = try? SQLIdentifiers.quote(table, engine: .sqlite),
              let column = try? SQLIdentifiers.quote(alias, engine: .sqlite) else { return nil }
        return "SELECT \(column) AS \(column), * FROM \"main\".\(name)"
    }

    /// The table an SQLite result's rows come from when the statement is the explorer's own
    /// `SELECT *` or a foreign-key hop Umbra generated. The origin check in the edit target still
    /// verifies every column, so this only says which table to look up.
    private static func sqliteBrowseTable(
        binding: IDEDatabaseConsoleBinding, statement: IDEDatabaseStatement, connection: DatabaseConnection
    ) -> String? {
        guard connection.engine == .sqlite else { return nil }
        if statement.parameters.isEmpty, let table = binding.sqliteBrowseTable,
           let name = try? SQLIdentifiers.quote(table, engine: .sqlite),
           statement.sql == "SELECT * FROM \"main\".\(name)" {
            return table
        }
        return IDEDatabaseResultQuery.navigatedTable(in: statement.sql)
    }

    private static func rowIDSelect(table: String, alias: String, statement: String) -> String? {
        guard let name = try? SQLIdentifiers.quote(table, engine: .sqlite),
              let column = try? SQLIdentifiers.quote(alias, engine: .sqlite) else { return nil }
        if statement == "SELECT * FROM \"main\".\(name)" { return "SELECT \(column) AS \(column), * FROM \"main\".\(name)" }
        for qualifier in ["parent", "child"] where statement.hasPrefix("SELECT \(qualifier).* FROM ") {
            return "SELECT \(qualifier).\(column) AS \(column), " + statement.dropFirst("SELECT ".count)
        }
        return nil
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
        sqliteMutationTask?.cancel()
        if let session = sqlSessions[id] { await session.cancelRunning() }
        if let session = mongoSessions[id] { await session.cancelRunning() }
    }

    func sort(by column: String, consoleID: UUID? = nil) async {
        guard !isRunning, switchingSQLSourceID == nil else { return }
        guard !refuseDiscardingEdits(consoleID: consoleID) else { return }
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
        let binding = resultOwner.flatMap { consoles[$0] } ?? IDEDatabaseConsoleBinding(
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
