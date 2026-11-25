import Foundation
import Logging
import MySQLKit
import NIOPosix
import NIOSSL
import PostgresKit
import PostgresNIO

/// What `SQLSession` opens. The password stays here, never on ``DatabaseConnection``.
public struct SQLLogin: Equatable, Sendable {
    public var engine: DatabaseEngine
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var database: String
    /// Use TLS when the server offers it (PostgreSQL `sslmode=prefer`). This is the historical
    /// meaning of "Use TLS" and it can fall back to plain text.
    public var useTLS: Bool
    /// TLS is mandatory and the certificate and host name are verified; a server without TLS is
    /// an error, never a silent downgrade.
    public var requireTLS: Bool
    public var unixSocketPath: String?

    public init(
        engine: DatabaseEngine,
        host: String = "localhost",
        port: Int? = nil,
        username: String = "",
        password: String = "",
        database: String = "",
        useTLS: Bool = false,
        requireTLS: Bool = false,
        unixSocketPath: String? = nil
    ) {
        self.engine = engine == .mongo ? .postgres : engine
        self.host = host
        self.port = port ?? self.engine.defaultPort
        self.username = username
        self.password = password
        self.database = database
        self.useTLS = useTLS || requireTLS
        self.requireTLS = requireTLS
        self.unixSocketPath = unixSocketPath
    }
}

extension DatabaseConnection {
    public func sqlLogin(password: String) -> SQLLogin {
        SQLLogin(
            engine: engine == .mysql || engine == .sqlite ? engine : .postgres,
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            useTLS: useTLS,
            requireTLS: tlsRequired ?? false
        )
    }
}

extension SQLLogin {
    /// The database the handshake opens. The pool substitutes the username when none
    /// is configured, which points at a database that is not there
    /// (`Unknown database 'root'`), so an empty database opens the schema every
    /// server of that engine keeps: `information_schema` on MySQL and MariaDB,
    /// `postgres` on PostgreSQL. The saved connection keeps the empty database.
    public var handshakeDatabase: String {
        guard database.isEmpty else { return database }
        switch engine {
        case .mysql: return "information_schema"
        case .postgres: return "postgres"
        case .sqlite, .mongo: return database
        }
    }
}

enum SQLURLs {
    static func parse(_ urlString: String) throws -> SQLLogin {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DatabaseError.invalidURL(urlString) }
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("mysql://") || lowercased.hasPrefix("mysql+") {
            guard let mysql = MySQLConfiguration(url: trimmed) else {
                throw DatabaseError.invalidURL(urlString)
            }
            return SQLLogin(mysql: mysql, urlString: trimmed)
        }
        if lowercased.hasPrefix("postgres://") || lowercased.hasPrefix("postgresql://")
            || lowercased.hasPrefix("postgres+") || lowercased.hasPrefix("postgresql+")
        {
            let postgres = try SQLPostgresConfiguration(url: trimmed)
            return SQLLogin(postgres: postgres)
        }
        throw DatabaseError.invalidURL(urlString)
    }

    static func build(_ login: SQLLogin) -> String {
        var components = URLComponents()
        components.scheme = login.engine == .mysql ? "mysql" : "postgresql"
        components.host = login.host
        components.port = login.port
        components.user = login.username.isEmpty ? nil : login.username
        components.password = login.password.isEmpty ? nil : login.password
        // An empty path stays empty. Falling back to the username would point at a database
        // that is not there, for example "Unknown database 'root'".
        components.path = login.database.isEmpty ? "" : "/\(login.database)"
        return components.string ?? ""
    }
}

/// One MySQL or PostgreSQL connection. Queries run only when the caller asks.
public final class SQLSession: SQLExecuting, @unchecked Sendable {
    public let engine: DatabaseEngine
    public let readOnly: Bool

    /// MySQL likewise: one connection for statements, one for metadata (audit F-01).
    private var mysqlConsole: MySQLSession?
    private var mysqlMetadata: MySQLSession?
    private var mysqlLogin: SQLLogin?
    /// SQLite is a file on this Mac: one connection serves statements and schema reads (an
    /// in-memory database exists only inside that one connection).
    private var sqlite: SQLiteSession?
    private let mysqlMetadataGate = AsyncMutex()
    /// PostgreSQL runs on single-connection session actors (audit F-01): one for the user's
    /// statements, one for metadata reads so the explorer never waits behind a long query.
    private var postgresConsole: PostgresSession?
    private var postgresMetadata: PostgresSession?
    private var postgresLogin: SQLLogin?
    private let metadataGate = AsyncMutex()
    private let logger: Logger

    private init(engine: DatabaseEngine, readOnly: Bool, logger: Logger) {
        self.engine = engine
        self.readOnly = readOnly
        self.logger = logger
    }

    public static func connect(login: SQLLogin, readOnly: Bool) async throws -> SQLSession {
        var logger = Logger(label: "com.umbra.editor.database")
        logger.logLevel = .warning
        let session = SQLSession(engine: login.engine, readOnly: readOnly, logger: logger)
        do {
            switch login.engine {
            case .mysql:
                try await session.connectMySQL(login: login)
            case .postgres:
                try await session.connectPostgres(login: login)
            case .sqlite:
            try await session.connectSQLite(login: login, readOnly: readOnly)
        case .mongo:
                throw DatabaseError.executionFailed("MongoDB is not a SQL connection.")
            }
        } catch {
            await session.disconnect()
            throw error
        }
        return session
    }

    public static func test(login: SQLLogin) async throws {
        let session = try await connect(login: login, readOnly: true)
        await session.disconnect()
    }

    public func disconnect() async {
        let sqliteSession = sqlite
        sqlite = nil
        await sqliteSession?.close()
        let mysqlConsoleSession = mysqlConsole, mysqlMetadataSession = mysqlMetadata
        mysqlConsole = nil
        mysqlMetadata = nil
        await mysqlConsoleSession?.close()
        await mysqlMetadataSession?.close()
        let console = postgresConsole, metadata = postgresMetadata
        postgresConsole = nil
        postgresMetadata = nil
        await console?.close()
        await metadata?.close()
    }

    /// Asks the server to stop the statement the console is running (`pg_cancel_backend` or
    /// `KILL QUERY` on a second connection). Returns when the request is sent.
    public func cancelRunning() async {
        await postgresConsole?.cancelRunning()
        await mysqlConsole?.cancelRunning()
        sqlite?.cancelRunning()  // nonisolated: works while the statement holds the session's queue
    }

    /// The SQLite session, for maintenance and attach (nil for every other engine).
    public var sqliteSession: SQLiteSession? { sqlite }

    public func transactionState() async -> TransactionState {
        if let postgresConsole { return await postgresConsole.transaction }
        if let mysqlConsole { return await mysqlConsole.transaction }
        if let sqlite { return await sqlite.transaction }
        return .none
    }

    /// Makes a new, empty SQLite database file. It never overwrites one.
    public static func createSQLiteDatabase(at path: String) async throws {
        guard !FileManager.default.fileExists(atPath: path) else { throw SQLiteSession.OpenError.alreadyExists(path) }
        let session = try await SQLiteSession.open(SQLiteOpenOptions(location: .file(path), createIfMissing: true))
        await session.close()
    }

    /// Tables and views with their kind, in name order.
    public func relations() async throws -> [SQLRelationInfo] {
        switch engine {
        case .mysql:
            let result = try await mysqlQuery("SHOW FULL TABLES WHERE Table_type IN ('BASE TABLE', 'VIEW')")
            return result.rows.compactMap { row in
                guard let name = row.first ?? nil else { return nil }
                return SQLRelationInfo(name: name, isView: row.count > 1 && row[1] == "VIEW")
            }
        case .postgres:
            let result = try await postgresQuery(
                """
                SELECT table_name, table_type
                FROM information_schema.tables
                WHERE table_schema = 'public' AND table_type IN ('BASE TABLE', 'VIEW')
                ORDER BY table_name
                """
            )
            return result.rows.compactMap { row in
                guard let name = row.first ?? nil else { return nil }
                return SQLRelationInfo(name: name, isView: row.count > 1 && row[1] == "VIEW")
            }
        case .sqlite:
            guard let sqlite else { throw DatabaseError.notConnected }
            return try await sqlite.tableNames().filter { $0.kind != .shadow }.map { SQLRelationInfo(name: $0.name, isView: $0.kind == .view) }
        case .mongo:
            return []
        }
    }

    /// The SQL language service's relations, columns, and foreign keys. A relation whose columns
    /// could not be read makes the catalog
    /// incomplete, which keeps "unknown table" diagnostics silent.
    public func sqlCatalog() async throws -> SQLCatalog {
        try await sqlCatalogMetadata().catalog
    }

    public func sqlCatalogMetadata() async throws -> (catalog: SQLCatalog, columnsByTable: [String: [SQLColumn]]) {
        async let relationList = relations()
        async let columnMap = allColumns()
        async let keyList = foreignKeys()
        let (relations, columnsByTable, keys) = try await (relationList, columnMap, keyList)
        var complete = true
        let schema: String? = switch engine {
        case .postgres: "public"
        case .sqlite: "main"
        case .mysql: mysqlLogin?.database.isEmpty == false ? mysqlLogin?.database : nil
        case .mongo: nil
        }
        let mapped = relations.map { relation -> SQLCatalog.Relation in
            guard let columns = columnsByTable[relation.name] else {
                complete = false
                return SQLCatalog.Relation(schema: schema, name: relation.name, kind: relation.isView ? .view : .table, columns: nil)
            }
            return SQLCatalog.Relation(
                schema: schema, name: relation.name, kind: relation.isView ? .view : .table,
                columns: columns.map {
                    SQLCatalog.Column(
                        name: $0.name, typeName: $0.declaredType, isNotNull: $0.isNotNull, isPrimaryKey: $0.isPrimaryKey,
                        hasDefault: !$0.defaultValue.isEmpty, isGenerated: $0.isGenerated, isIdentityAlways: $0.isIdentityAlways
                    )
                }
            )
        }
        // One key per constraint, its columns in key order. A key with no constraint name is one pair.
        var order: [String] = []
        var grouped: [String: [SQLForeignKey]] = [:]
        for (index, key) in keys.enumerated() {
            let id = key.constraint.map { "\(key.fromTable)\u{1}\($0)" } ?? "\(key.fromTable)\u{1}#\(index)"
            if grouped[id] == nil { order.append(id) }
            grouped[id, default: []].append(key)
        }
        let foreignKeys = order.compactMap { id -> SQLCatalog.ForeignKey? in
            guard let pairs = grouped[id]?.sorted(by: { $0.ordinal < $1.ordinal }), let first = pairs.first else { return nil }
            return SQLCatalog.ForeignKey(
                name: first.constraint, fromRelation: first.fromTable, fromColumns: pairs.map(\.fromColumn),
                toRelation: first.toTable, toColumns: pairs.map(\.toColumn)
            )
        }
        return (SQLCatalog(relations: mapped, foreignKeys: foreignKeys, defaultSchema: schema, isComplete: complete), columnsByTable)
    }

    public func tables() async throws -> [String] {
        switch engine {
        case .mysql:
            let result = try await mysqlQuery(
                """
                SHOW FULL TABLES
                WHERE Table_type IN ('BASE TABLE', 'VIEW')
                """
            )
            return result.rows.compactMap { $0.first ?? nil }
        case .postgres:
            let result = try await postgresQuery(
                """
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = 'public'
                  AND table_type IN ('BASE TABLE', 'VIEW')
                ORDER BY table_name
                """
            )
            return result.rows.compactMap { $0.first ?? nil }
        case .sqlite:
            guard let sqlite else { throw DatabaseError.notConnected }
            return try await sqlite.tableNames().filter { $0.kind != .shadow }.map(\.name)
        case .mongo:
            return []
        }
    }

    public func columns(of table: String) async throws -> [SQLColumn] {
        switch engine {
        case .mysql:
            let quoted = try SQLIdentifiers.quote(table, engine: .mysql)
            let result = try await mysqlQuery("SHOW COLUMNS FROM \(quoted)")
            return result.rows.compactMap { row -> SQLColumn? in
                guard row.count >= 4, let name = row[0] else { return nil }
                return SQLColumn(
                    name: name,
                    declaredType: row.count > 1 ? (row[1] ?? "") : "",
                    isPrimaryKey: row.count > 3 && row[3] == "PRI",
                    isNotNull: row.count > 2 && row[2] == "NO",
                    isGenerated: row.count > 5 && (row[5] ?? "").contains(" GENERATED")
                )
            }
        case .postgres:
            let literal = quoteSQLLiteral(table)
            let result = try await postgresQuery(
                """
                SELECT column_name, data_type, is_nullable, is_generated, identity_generation
                FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = \(literal)
                ORDER BY ordinal_position
                """
            )
            let primaryKeys = try await postgresPrimaryKeyColumns(table)
            return result.rows.compactMap { row -> SQLColumn? in
                guard row.count >= 3, let name = row[0] else { return nil }
                return SQLColumn(
                    name: name,
                    declaredType: row[1] ?? "",
                    isPrimaryKey: primaryKeys.contains(name),
                    isNotNull: row[2] == "NO",
                    isGenerated: row.count > 3 && row[3] == "ALWAYS",
                    isIdentityAlways: row.count > 4 && row[4] == "ALWAYS"
                )
            }
        case .sqlite:
            guard let sqlite else { throw DatabaseError.notConnected }
            return try await sqlite.tableInfo(table: table).columns.filter { !$0.isHidden }.map(Self.sqlColumn)
        case .mongo:
            return []
        }
    }

    /// Every table's columns in one query, so schema completion reads a cache filled once per
    /// connect instead of querying per keystroke or per expanded table.
    public func allColumns() async throws -> [String: [SQLColumn]] {
        switch engine {
        case .mysql:
            let result = try await mysqlQuery(
                """
                SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, EXTRA
                FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE()
                ORDER BY TABLE_NAME, ORDINAL_POSITION
                """
            )
            return SQLSchemaMapping.mysqlColumns(result)
        case .postgres:
            let result = try await postgresQuery(
                """
                SELECT table_name, column_name, data_type, character_maximum_length,
                       numeric_precision, numeric_scale, is_nullable, column_default,
                       is_generated, identity_generation
                FROM information_schema.columns
                WHERE table_schema = 'public'
                ORDER BY table_name, ordinal_position
                """
            )
            let primaryKeys = try await postgresAllPrimaryKeys()
            return SQLSchemaMapping.postgresColumns(result, primaryKeyColumns: primaryKeys)
        case .sqlite:
            guard let sqlite else { throw DatabaseError.notConnected }
            return try await sqlite.allColumns().mapValues { $0.filter { !$0.isHidden }.map(Self.sqlColumn) }
        case .mongo:
            return [:]
        }
    }

    /// Every foreign key in one query, for schema diagrams and generated SQL.
    public func foreignKeys() async throws -> [SQLForeignKey] {
        switch engine {
        case .mysql:
            let result = try await mysqlQuery(
                """
                SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME,
                       CONSTRAINT_NAME, ORDINAL_POSITION
                FROM information_schema.KEY_COLUMN_USAGE
                WHERE TABLE_SCHEMA = DATABASE()
                  AND REFERENCED_TABLE_NAME IS NOT NULL
                ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION
                """
            )
            return SQLSchemaMapping.foreignKeys(result)
        case .postgres:
            let result = try await postgresQuery(
                """
                SELECT cl.relname, a.attname, fcl.relname, fa.attname, con.conname, u.ord
                FROM pg_constraint con
                JOIN pg_class cl ON cl.oid = con.conrelid
                JOIN pg_namespace n ON n.oid = cl.relnamespace
                JOIN pg_class fcl ON fcl.oid = con.confrelid
                CROSS JOIN LATERAL unnest(con.conkey, con.confkey) WITH ORDINALITY AS u(attnum, fattnum, ord)
                JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = u.attnum
                JOIN pg_attribute fa ON fa.attrelid = con.confrelid AND fa.attnum = u.fattnum
                WHERE con.contype = 'f' AND n.nspname = 'public'
                ORDER BY cl.relname, con.conname, u.ord
                """
            )
            return SQLSchemaMapping.foreignKeys(result)
        case .sqlite:
            guard let sqlite else { throw DatabaseError.notConnected }
            return try await sqlite.allForeignKeys().flatMap { entry in
                entry.key.from.enumerated().map { offset, column in
                    SQLForeignKey(
                        fromTable: entry.table, fromColumn: column, toTable: entry.key.table,
                        toColumn: (entry.key.to.indices.contains(offset) ? entry.key.to[offset] : nil) ?? "",
                        constraint: "fk\(entry.key.id)", ordinal: offset + 1
                    )
                }
            }
        case .mongo:
            return []
        }
    }

    /// The `CREATE TABLE` statement for one table: exact from MySQL, composed for PostgreSQL.
    public func createTableStatement(_ table: String) async throws -> String {
        switch engine {
        case .mysql:
            let quoted = try SQLIdentifiers.quote(table, engine: .mysql)
            let result = try await mysqlQuery("SHOW CREATE TABLE \(quoted)")
            guard let ddl = result.rows.first?.dropFirst().compactMap({ $0 }).first else {
                throw DatabaseError.executionFailed("No CREATE TABLE for \(table).")
            }
            return ddl.hasSuffix(";") ? ddl : ddl + ";"
        case .postgres:
            let columns = try await allColumns()
            return SQLSchemaMapping.postgresCreateTable(
                table: table, columns: columns[table] ?? [], foreignKeys: try await foreignKeys()
            )
        case .sqlite:
            guard let sqlite else { throw DatabaseError.notConnected }
            guard let sql = try await sqlite.tableInfo(table: table).sql else {
                throw DatabaseError.executionFailed("No CREATE statement for \(table).")
            }
            return sql.hasSuffix(";") ? sql : sql + ";"
        case .mongo:
            throw DatabaseError.executionFailed("MongoDB is not a SQL connection.")
        }
    }

    public func declaration(of relation: SQLCatalog.Relation) async throws -> String {
        guard engine == .postgres, relation.kind == .view else {
            return try await createTableStatement(relation.name)
        }
        let name = try SQLIdentifiers.quote(relation.name, engine: .postgres)
        let qualified = "public.\(name)"
        let result = try await postgresQuery("SELECT pg_get_viewdef(\(quoteSQLLiteral(qualified))::regclass, true)")
        guard let body = result.rows.first?.first ?? nil else {
            throw DatabaseError.executionFailed("No CREATE statement for \(relation.name).")
        }
        return "CREATE VIEW \(qualified) AS\n\(body)"
    }

    /// The schema's `CREATE TABLE` statements, one per table, for copy-paste or a console.
    public func createDatabaseSQL() async throws -> String {
        let names = try await tables()
        var parts: [String] = []
        for name in names {
            parts.append(try await createTableStatement(name))
        }
        return parts.joined(separator: "\n\n")
    }

    public func indexes(of table: String) async throws -> [SQLIndex] {
        switch engine {
        case .mysql:
            let quoted = try SQLIdentifiers.quote(table, engine: .mysql)
            let result = try await mysqlQuery("SHOW INDEX FROM \(quoted)")
            return SQLSchemaMapping.mysqlIndexes(result)
        case .postgres:
            let literal = quoteSQLLiteral(table)
            let result = try await postgresQuery(
                """
                SELECT ic.relname AS index_name, i.indisunique AS is_unique, a.attname AS column_name,
                       array_position(i.indkey, a.attnum) AS column_position
                FROM pg_index i
                JOIN pg_class ic ON ic.oid = i.indexrelid
                JOIN pg_class tc ON tc.oid = i.indrelid
                JOIN pg_attribute a ON a.attrelid = tc.oid AND a.attnum = ANY(i.indkey)
                WHERE tc.relname = \(literal) AND tc.relnamespace = 'public'::regnamespace
                ORDER BY index_name, column_position
                """
            )
            return SQLSchemaMapping.postgresIndexes(result)
        case .sqlite:
            guard let sqlite else { throw DatabaseError.notConnected }
            // The index SQLite makes for the primary key is the key, not a separate index to show.
            return try await sqlite.tableInfo(table: table).indexes.filter { $0.origin != "pk" }.map {
                SQLIndex(name: $0.name, columns: $0.columns.compactMap { $0 }, isUnique: $0.isUnique)
            }
        case .mongo:
            return []
        }
    }

    public func query(_ sql: String) async throws -> QueryResult {
        try await query(sql, parameters: [])
    }

    public func query(_ sql: String, parameters: [DatabaseValue]) async throws -> QueryResult {
        try await Self.collect(rowLimit: Self.userRowLimit) { store in
            try await execute(sql, parameters: parameters, into: store)
        }
    }

    public func execute(
        _ sql: String, parameters: [DatabaseValue], into store: ResultStore
    ) async throws -> ExecutionSummary {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DatabaseError.executionFailed("Query is empty")
        }
        // SQLite refuses writes itself (a read-only file, `query_only`, an authorizer), and its
        // read-only pragmas would fail a keyword check, so only the server engines get the hint.
        if readOnly, engine != .sqlite, !SQLShaping.isReadOnlyStatement(trimmed) {
            throw DatabaseError.readOnlyViolation
        }
        switch engine {
        case .mysql:
            guard let mysqlConsole else { throw DatabaseError.notConnected }
            return try await mysqlConsole.execute(trimmed, parameters: parameters, into: store,
                                                  options: ExecuteOptions(collectNotices: true))
        case .postgres:
            guard let postgresConsole else { throw DatabaseError.notConnected }
            return try await postgresConsole.execute(trimmed, parameters: parameters, into: store)
        case .sqlite:
            guard let sqlite else { throw DatabaseError.notConnected }
            return try await sqlite.execute(trimmed, parameters: parameters, into: store)
        case .mongo:
            throw DatabaseError.executionFailed("MongoDB is not a SQL connection.")
        }
    }

    private func postgresAllPrimaryKeys() async throws -> [String: Set<String>] {
        let result = try await postgresQuery(
            """
            SELECT tc.table_name, kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY'
              AND tc.table_schema = 'public'
            """
        )
        return SQLSchemaMapping.postgresPrimaryKeys(result)
    }

    private func postgresPrimaryKeyColumns(_ table: String) async throws -> Set<String> {
        let literal = quoteSQLLiteral(table)
        let result = try await postgresQuery(
            """
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY'
              AND tc.table_schema = 'public'
              AND tc.table_name = \(literal)
            """
        )
        return Set(result.rows.compactMap { $0.first ?? nil })
    }

    private func connectSQLite(login: SQLLogin, readOnly: Bool) async throws {
        let location: SQLiteLocation = login.database == ":memory:" ? .memory : .file(login.database)
        sqlite = try await SQLiteSession.open(SQLiteOpenOptions(location: location, readOnly: readOnly))
    }

    private static func sqlColumn(_ column: SQLiteColumnInfo) -> SQLColumn {
        SQLColumn(
            name: column.name, declaredType: column.declaredType, isPrimaryKey: column.primaryKeyPosition > 0,
            isNotNull: column.isNotNull, defaultValue: column.defaultValue ?? "", isGenerated: column.isGenerated
        )
    }

    private func connectMySQL(login: SQLLogin) async throws {
        mysqlLogin = login
        mysqlConsole = try await MySQLSession.connect(login: login, readOnly: readOnly)
    }

    /// A schema read, on the metadata connection (created on first use, read-only, one at a time).
    private func mysqlQuery(_ sql: String) async throws -> QueryResult {
        guard let login = mysqlLogin, mysqlConsole != nil else { throw DatabaseError.notConnected }
        await mysqlMetadataGate.lock()
        do {
            let session: MySQLSession
            if let existing = mysqlMetadata {
                session = existing
            } else {
                session = try await MySQLSession.connect(login: login, readOnly: true)
                mysqlMetadata = session
            }
            let result = try await Self.collect(rowLimit: Self.metadataRowLimit) { store in
                try await session.execute(sql, into: store)
            }
            await mysqlMetadataGate.unlock()
            return result
        } catch {
            await mysqlMetadataGate.unlock()
            throw error
        }
    }

    private func connectPostgres(login: SQLLogin) async throws {
        postgresLogin = login
        postgresConsole = try await PostgresSession.connect(login: login, readOnly: readOnly)
    }

    /// A schema read, on the metadata connection (created on first use, always read-only, and
    /// used one statement at a time).
    private func postgresQuery(_ sql: String) async throws -> QueryResult {
        guard let login = postgresLogin, postgresConsole != nil else { throw DatabaseError.notConnected }
        await metadataGate.lock()
        do {
            let session: PostgresSession
            if let existing = postgresMetadata {
                session = existing
            } else {
                session = try await PostgresSession.connect(login: login, readOnly: true)
                postgresMetadata = session
            }
            let result = try await Self.collect(rowLimit: Self.metadataRowLimit) { store in
                try await session.execute(sql, into: store)
            }
            await metadataGate.unlock()
            return result
        } catch {
            await metadataGate.unlock()
            throw error
        }
    }

    /// Rows a user statement may return through this string-based facade. The paged UI asks for
    /// a page at a time; this is a backstop against an unbounded `SELECT` run unpaged.
    static let userRowLimit = 100_000
    static let metadataRowLimit = 2_000_000

    private static func collect(
        rowLimit: Int, _ execute: (ResultStore) async throws -> ExecutionSummary
    ) async throws -> QueryResult {
        let store = ResultStore(columns: [], rowLimit: rowLimit)
        let summary: ExecutionSummary
        let rows: [[DatabaseValue]]
        do {
            summary = try await execute(store)
            rows = try await store.rows(in: 0..<store.rowCount)
        } catch {
            await store.close()
            throw error
        }
        await store.close()
        return QueryResult(
            columns: summary.columns.map(\.name),
            rows: rows.map { $0.map(\.rawText) },
            rowsAffected: summary.affectedRows,
            isReadQuery: !summary.columns.isEmpty,
            wasCancelled: summary.wasCancelled,
            notices: summary.notices
        )
    }

    /// One cell as text for the current string-based `QueryResult`. The value comes from the
    /// typed decoder (binary results are not UTF-8: reading them as a string is what showed
    /// integers and dates as garbage), and NULL stays distinct from an empty string.
    private static func formatPostgresCell(_ cell: PostgresCell) -> String? {
        decodePostgresCell(cell).rawText
    }

    static func decodePostgresCell(_ cell: PostgresCell) -> DatabaseValue {
        PostgresValueDecoder.decode(
            oid: cell.dataType.rawValue,
            isBinary: cell.format == .binary,
            bytes: cell.bytes.map { Array($0.readableBytesView) }
        )
    }
}

public enum SQLSchemaMapping {
    /// Groups one `information_schema.COLUMNS` page (`TABLE_NAME, COLUMN_NAME, COLUMN_TYPE,
    /// `IS_NULLABLE`, `COLUMN_KEY` for `DATABASE()`) by table.
    public static func mysqlColumns(_ result: QueryResult) -> [String: [SQLColumn]] {
        var grouped: [String: [SQLColumn]] = [:]
        for row in result.rows {
            guard row.count >= 5, let table = row[0], let name = row[1] else { continue }
            grouped[table, default: []].append(SQLColumn(
                name: name,
                declaredType: row[2] ?? "",
                isPrimaryKey: row[4] == "PRI",
                isNotNull: row[3] == "NO",
                isGenerated: row.count > 5 && (row[5] ?? "").contains(" GENERATED")
            ))
        }
        return grouped
    }

    /// Groups one `information_schema.columns` page (`table_name, column_name, data_type,
    /// `character_maximum_length`, `numeric_precision`, `numeric_scale`, `is_nullable`,
    /// `column_default` for `public`) by table. `primaryKeyColumns` maps a table to its primary
    /// key columns (see `postgresPrimaryKeys`).
    public static func postgresColumns(
        _ result: QueryResult, primaryKeyColumns: [String: Set<String>] = [:]
    ) -> [String: [SQLColumn]] {
        var grouped: [String: [SQLColumn]] = [:]
        for row in result.rows {
            guard row.count >= 8, let table = row[0], let name = row[1] else { continue }
            grouped[table, default: []].append(SQLColumn(
                name: name,
                declaredType: postgresDeclaredType(dataType: row[2] ?? "", maximumLength: row[3], precision: row[4], scale: row[5]),
                isPrimaryKey: primaryKeyColumns[table]?.contains(name) ?? false,
                isNotNull: row[6] == "NO",
                defaultValue: row[7] ?? "",
                isGenerated: row.count > 8 && row[8] == "ALWAYS",
                isIdentityAlways: row.count > 9 && row[9] == "ALWAYS"
            ))
        }
        return grouped
    }

    private static func postgresDeclaredType(dataType: String, maximumLength: String?, precision: String?, scale: String?) -> String {
        switch dataType {
        case "character varying", "character":
            guard let maximumLength, let length = Int(maximumLength) else { return dataType }
            return "\(dataType)(\(length))"
        case "numeric":
            guard let precision, let intPrecision = Int(precision) else { return dataType }
            if let scale, let intScale = Int(scale) {
                return "numeric(\(intPrecision),\(intScale))"
            }
            return "numeric(\(intPrecision))"
        default:
            return dataType
        }
    }

    /// Maps a foreign-key page (`table_name, column_name, referenced table, referenced column`)
    /// to keys. Both engines' `foreignKeys()` queries return these four columns in this order.
    public static func foreignKeys(_ result: QueryResult) -> [SQLForeignKey] {
        result.rows.compactMap { row in
            guard row.count >= 4, let fromTable = row[0], let fromColumn = row[1],
                  let toTable = row[2], let toColumn = row[3]
            else { return nil }
            return SQLForeignKey(
                fromTable: fromTable, fromColumn: fromColumn, toTable: toTable, toColumn: toColumn,
                constraint: row.count > 4 ? row[4] : nil, ordinal: row.count > 5 ? Int(row[5] ?? "") ?? 0 : 0
            )
        }
    }

    /// A `CREATE TABLE` statement for PostgreSQL from cached columns. MySQL reads its exact text
    /// from `SHOW CREATE TABLE` instead.
    public static func postgresCreateTable(
        table: String, columns: [SQLColumn], foreignKeys: [SQLForeignKey] = []
    ) -> String {
        var lines = columns.map { column -> String in
            var line = "  \(quotePostgres(column.name)) \(column.declaredType)"
            if column.isNotNull {
                line += " NOT NULL"
            }
            if !column.defaultValue.isEmpty {
                line += " DEFAULT \(column.defaultValue)"
            }
            return line
        }
        let keys = columns.filter(\.isPrimaryKey).map(\.name)
        if !keys.isEmpty {
            lines.append("  PRIMARY KEY (\(keys.map(quotePostgres).joined(separator: ", ")))")
        }
        for key in foreignKeys where key.fromTable == table {
            lines.append(
                "  FOREIGN KEY (\(quotePostgres(key.fromColumn))) REFERENCES \(quotePostgres(key.toTable)) (\(quotePostgres(key.toColumn)))"
            )
        }
        return "CREATE TABLE \(quotePostgres(table)) (\n\(lines.joined(separator: ",\n"))\n);"
    }

    private static func quotePostgres(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Maps a primary-key page (`table_name, column_name`) to each table's key columns.
    public static func postgresPrimaryKeys(_ result: QueryResult) -> [String: Set<String>] {
        var grouped: [String: Set<String>] = [:]
        for row in result.rows {
            guard row.count >= 2, let table = row[0], let column = row[1] else { continue }
            grouped[table, default: []].insert(column)
        }
        return grouped
    }

    static func mysqlIndexes(_ result: QueryResult) -> [SQLIndex] {
        guard let keyNameIndex = result.columns.firstIndex(of: "Key_name"),
              let nonUniqueIndex = result.columns.firstIndex(of: "Non_unique"),
              let columnNameIndex = result.columns.firstIndex(of: "Column_name")
        else { return [] }
        let seqIndex = result.columns.firstIndex(of: "Seq_in_index")
        var order: [String] = []
        var columnsByName: [String: [(Int, String)]] = [:]
        var uniqueByName: [String: Bool] = [:]
        for row in result.rows {
            guard let keyName = row.value(at: keyNameIndex), let columnName = row.value(at: columnNameIndex) else { continue }
            if columnsByName[keyName] == nil {
                order.append(keyName)
                columnsByName[keyName] = []
            }
            let seq = seqIndex.flatMap { row.value(at: $0) }.flatMap(Int.init) ?? (columnsByName[keyName]?.count ?? 0) + 1
            columnsByName[keyName]?.append((seq, columnName))
            uniqueByName[keyName] = row.value(at: nonUniqueIndex) == "0"
        }
        return order.compactMap { name in
            guard let columns = columnsByName[name] else { return nil }
            return SQLIndex(
                name: name,
                columns: columns.sorted { $0.0 < $1.0 }.map(\.1),
                isUnique: uniqueByName[name] ?? false
            )
        }
    }

    static func postgresIndexes(_ result: QueryResult) -> [SQLIndex] {
        guard let nameIndex = result.columns.firstIndex(of: "index_name"),
              let uniqueIndex = result.columns.firstIndex(of: "is_unique"),
              let columnIndex = result.columns.firstIndex(of: "column_name")
        else { return [] }
        var order: [String] = []
        var columnsByName: [String: [String]] = [:]
        var uniqueByName: [String: Bool] = [:]
        for row in result.rows {
            guard let name = row.value(at: nameIndex), let column = row.value(at: columnIndex) else { continue }
            if columnsByName[name] == nil {
                order.append(name)
                columnsByName[name] = []
            }
            columnsByName[name]?.append(column)
            uniqueByName[name] = row.value(at: uniqueIndex) == "true"
        }
        return order.compactMap { name in
            guard let columns = columnsByName[name] else { return nil }
            return SQLIndex(name: name, columns: columns, isUnique: uniqueByName[name] ?? false)
        }
    }
}

private extension Array where Element == String? {
    func value(at index: Int) -> String? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

private func quoteSQLLiteral(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
}

private extension SQLLogin {
    init(mysql: MySQLConfiguration, urlString: String) {
        let url = URL(string: urlString)
        let engine = DatabaseEngine.mysql
        self.engine = engine
        host = url?.host ?? "localhost"
        port = url?.port ?? engine.defaultPort
        username = mysql.username
        password = mysql.password
        database = mysql.database ?? ""
        if database == "/" { database = "" }
        useTLS = mysql.tlsConfiguration != nil
        requireTLS = false
        if url?.scheme?.lowercased() == "mysql+uds" {
            unixSocketPath = url?.path
        } else {
            unixSocketPath = nil
        }
    }

    init(postgres: SQLPostgresConfiguration) {
        let core = postgres.coreConfiguration
        engine = .postgres
        if let host = core.host, let port = core.port {
            self.host = host
            self.port = port
            unixSocketPath = nil
        } else {
            host = "localhost"
            port = DatabaseEngine.postgres.defaultPort
            unixSocketPath = core.unixSocketPath
        }
        username = core.username
        password = core.password ?? ""
        database = core.database ?? ""
        useTLS = core.tls.isAllowed
        requireTLS = core.tls.isEnforced
    }
}
