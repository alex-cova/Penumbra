import AsyncKit
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
    public var useTLS: Bool
    public var unixSocketPath: String?

    public init(
        engine: DatabaseEngine,
        host: String = "localhost",
        port: Int? = nil,
        username: String = "",
        password: String = "",
        database: String = "",
        useTLS: Bool = false,
        unixSocketPath: String? = nil
    ) {
        self.engine = engine == .mongo ? .postgres : engine
        self.host = host
        self.port = port ?? self.engine.defaultPort
        self.username = username
        self.password = password
        self.database = database
        self.useTLS = useTLS
        self.unixSocketPath = unixSocketPath
    }
}

extension DatabaseConnection {
    public func sqlLogin(password: String) -> SQLLogin {
        SQLLogin(
            engine: engine == .mysql ? .mysql : .postgres,
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            useTLS: useTLS
        )
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

    private var mysqlPool: EventLoopGroupConnectionPool<MySQLConnectionSource>?
    private var postgresClient: PostgresClient?
    private var postgresRunTask: Task<Void, Never>?
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
        if let mysqlPool {
            try? await mysqlPool.shutdownAsync()
            self.mysqlPool = nil
        }
        if let postgresRunTask {
            postgresRunTask.cancel()
            self.postgresRunTask = nil
        }
        postgresClient = nil
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
                    isNotNull: row.count > 2 && row[2] == "NO"
                )
            }
        case .postgres:
            let literal = quoteSQLLiteral(table)
            let result = try await postgresQuery(
                """
                SELECT column_name, data_type, is_nullable
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
                    isNotNull: row[2] == "NO"
                )
            }
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
                SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY
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
                       numeric_precision, numeric_scale, is_nullable, column_default
                FROM information_schema.columns
                WHERE table_schema = 'public'
                ORDER BY table_name, ordinal_position
                """
            )
            let primaryKeys = try await postgresAllPrimaryKeys()
            return SQLSchemaMapping.postgresColumns(result, primaryKeyColumns: primaryKeys)
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
                SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
                FROM information_schema.KEY_COLUMN_USAGE
                WHERE TABLE_SCHEMA = DATABASE()
                  AND REFERENCED_TABLE_NAME IS NOT NULL
                ORDER BY TABLE_NAME, ORDINAL_POSITION
                """
            )
            return SQLSchemaMapping.foreignKeys(result)
        case .postgres:
            let result = try await postgresQuery(
                """
                SELECT tc.table_name, kcu.column_name, ccu.table_name, ccu.column_name
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                  ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
                JOIN information_schema.constraint_column_usage ccu
                  ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema
                WHERE tc.constraint_type = 'FOREIGN KEY'
                  AND tc.table_schema = 'public'
                ORDER BY tc.table_name, kcu.ordinal_position
                """
            )
            return SQLSchemaMapping.foreignKeys(result)
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
        case .mongo:
            throw DatabaseError.executionFailed("MongoDB is not a SQL connection.")
        }
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
        case .mongo:
            return []
        }
    }

    public func query(_ sql: String) async throws -> QueryResult {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DatabaseError.executionFailed("Query is empty")
        }
        if readOnly, !SQLShaping.isReadOnlyStatement(trimmed) {
            throw DatabaseError.readOnlyViolation
        }
        switch engine {
        case .mysql:
            return try await mysqlQuery(trimmed)
        case .postgres:
            return try await postgresQuery(trimmed)
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

    private func connectMySQL(login: SQLLogin) async throws {
        let configuration: MySQLConfiguration
        if let socket = login.unixSocketPath {
            configuration = MySQLConfiguration(
                unixDomainSocketPath: socket,
                username: login.username,
                password: login.password,
                database: login.database.isEmpty ? nil : login.database,
                tlsConfiguration: login.useTLS ? .makeClientConfiguration() : nil
            )
        } else {
            configuration = MySQLConfiguration(
                hostname: login.host,
                port: login.port,
                username: login.username,
                password: login.password,
                database: login.database.isEmpty ? nil : login.database,
                tlsConfiguration: login.useTLS ? .makeClientConfiguration() : nil
            )
        }
        let pool = EventLoopGroupConnectionPool(
            source: MySQLConnectionSource(configuration: configuration),
            on: NIOSingletons.posixEventLoopGroup
        )
        mysqlPool = pool
        _ = try await pool.database(logger: logger).simpleQuery("SELECT 1").get()
    }

    private func mysqlQuery(_ sql: String) async throws -> QueryResult {
        guard let mysqlPool else { throw DatabaseError.notConnected }
        let rows = try await mysqlPool.database(logger: logger).simpleQuery(sql).get()
        return Self.mapMySQLRows(rows)
    }

    private static func mapMySQLRows(_ mysqlRows: [MySQLRow]) -> QueryResult {
        guard let first = mysqlRows.first else {
            return QueryResult(columns: [], rows: [], rowsAffected: nil, isReadQuery: false)
        }
        let columns = first.columnDefinitions.map(\.name)
        let rows = mysqlRows.map { row in
            zip(row.columnDefinitions, row.values).map { column, buffer in
                let data = MySQLData(
                    type: column.columnType,
                    format: row.format,
                    buffer: buffer,
                    isUnsigned: column.flags.contains(.COLUMN_UNSIGNED)
                )
                return formatMySQLValue(data)
            }
        }
        return QueryResult(columns: columns, rows: rows, rowsAffected: nil, isReadQuery: true)
    }

    private static func formatMySQLValue(_ data: MySQLData) -> String? {
        guard data.buffer != nil else { return nil }
        switch data.type {
        case .blob, .tinyBlob, .mediumBlob, .longBlob:
            if let text = blobText(data) {
                return text
            }
            return "<BLOB \(data.buffer?.readableBytes ?? 0) bytes>"
        default:
            return data.string ?? ""
        }
    }

    /// Text for a blob-typed value that actually delivered a string (`SHOW COLUMNS` and
    /// `information_schema` strings can arrive with a blob wire type), or nil when the bytes
    /// are really binary.
    private static func blobText(_ data: MySQLData) -> String? {
        guard var buffer = data.buffer,
              let bytes = buffer.readBytes(length: buffer.readableBytes)
        else { return nil }
        return SQLDisplayText.text(bytes: bytes)
    }

    private func connectPostgres(login: SQLLogin) async throws {
        let client = PostgresClient(
            configuration: Self.postgresConfiguration(from: login),
            backgroundLogger: logger
        )
        postgresClient = client
        postgresRunTask = Task { await client.run() }
        _ = try await client.query("SELECT 1", logger: logger)
    }

    private func postgresQuery(_ sql: String) async throws -> QueryResult {
        guard let postgresClient else { throw DatabaseError.notConnected }
        let sequence = try await postgresClient.query(PostgresQuery(unsafeSQL: sql), logger: logger)
        var columns: [String] = []
        var rows: [[String?]] = []
        for try await row in sequence {
            var values: [String?] = []
            for cell in row {
                if columns.count < row.count {
                    columns.append(cell.columnName)
                }
                values.append(Self.formatPostgresCell(cell))
            }
            rows.append(values)
        }
        if columns.isEmpty {
            return QueryResult(columns: [], rows: [], rowsAffected: nil, isReadQuery: false)
        }
        return QueryResult(columns: columns, rows: rows, rowsAffected: nil, isReadQuery: true)
    }

    private static func postgresConfiguration(from login: SQLLogin) -> PostgresClient.Configuration {
        let tls: PostgresClient.Configuration.TLS = login.useTLS
            ? .prefer(.makeClientConfiguration())
            : .disable
        let password = login.password.isEmpty ? nil : login.password
        let database = login.database.isEmpty ? nil : login.database
        if let socket = login.unixSocketPath {
            return PostgresClient.Configuration(
                unixSocketPath: socket,
                username: login.username,
                password: password,
                database: database
            )
        }
        return PostgresClient.Configuration(
            host: login.host,
            port: login.port,
            username: login.username,
            password: password,
            database: database,
            tls: tls
        )
    }

    private static func formatPostgresCell(_ cell: PostgresCell) -> String? {
        guard let bytes = cell.bytes, bytes.readableBytes > 0 else { return nil }
        if let string = try? cell.decode(String.self) { return string }
        if let integer = try? cell.decode(Int.self) { return String(integer) }
        if let int64 = try? cell.decode(Int64.self) { return String(int64) }
        if let double = try? cell.decode(Double.self) { return String(double) }
        if let boolean = try? cell.decode(Bool.self) { return boolean ? "true" : "false" }
        return "<\(String(describing: cell.dataType)) \(bytes.readableBytes) bytes>"
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
                isNotNull: row[3] == "NO"
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
                defaultValue: row[7] ?? ""
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
            return SQLForeignKey(fromTable: fromTable, fromColumn: fromColumn, toTable: toTable, toColumn: toColumn)
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

/// Decides whether bytes a blob-typed column delivered are displayable text. A pure function
/// so it is testable without a live database.
enum SQLDisplayText {
    static func text(bytes: [UInt8]) -> String? {
        guard let text = String(bytes: bytes, encoding: .utf8), !text.isEmpty else { return nil }
        let displayable = text.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
                || !CharacterSet.controlCharacters.contains(scalar)
        }
        return displayable ? text : nil
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
    }
}
