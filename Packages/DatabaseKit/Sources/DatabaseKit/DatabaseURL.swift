import Foundation

/// `mysql://`, `postgresql://`, `mongodb://` and `mongodb+srv://`.
public enum DatabaseURL {
    public static func parse(_ raw: String) throws -> DatabaseConnectionDraft {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("mysql://") || lower.hasPrefix("mysql+")
            || lower.hasPrefix("postgres://") || lower.hasPrefix("postgresql://")
            || lower.hasPrefix("postgres+") || lower.hasPrefix("postgresql+")
        {
            let login = try SQLURLs.parse(trimmed)
            var connection = DatabaseConnection(
                name: login.database.isEmpty ? login.host : login.database,
                engine: login.engine == .mysql ? .mysql : .postgres,
                host: login.host,
                port: login.port,
                username: login.username,
                database: login.database,
                useTLS: login.useTLS,
                tlsRequired: login.requireTLS ? true : nil
            )
            if connection.name.isEmpty { connection.name = connection.engine.displayName }
            return DatabaseConnectionDraft(connection: connection, password: login.password)
        }
        if lower.hasPrefix("sqlite://") {
            return try parseSQLite(trimmed)
        }
        if lower.hasPrefix("mongodb://") || lower.hasPrefix("mongodb+srv://") {
            let login = try MongoURLs.parse(trimmed)
            let name = login.defaultDatabase == "admin" ? login.host : login.defaultDatabase
            let connection = DatabaseConnection(
                name: name,
                engine: .mongo,
                host: login.host,
                port: login.port,
                username: login.username,
                database: login.defaultDatabase,
                useTLS: login.useTLS,
                authSource: login.authSource,
                useSRV: login.useSRV,
                replicaSet: login.replicaSet,
                directConnection: login.directConnection
            )
            return DatabaseConnectionDraft(connection: connection, password: login.password)
        }
        throw DatabaseError.invalidURL(trimmed)
    }

    /// `sqlite:///absolute/path.db`, `sqlite://:memory:`, and `?mode=ro` for read-only.
    private static func parseSQLite(_ raw: String) throws -> DatabaseConnectionDraft {
        var rest = String(raw.dropFirst("sqlite://".count))
        var readOnly = false
        if let question = rest.firstIndex(of: "?") {
            let query = rest[rest.index(after: question)...]
            readOnly = query.split(separator: "&").contains("mode=ro")
            rest = String(rest[..<question])
        }
        let path = rest.removingPercentEncoding ?? rest
        guard !path.isEmpty else { throw DatabaseError.invalidURL(raw) }
        let name = path == ":memory:" ? "In-memory database" : URL(fileURLWithPath: path).lastPathComponent
        let connection = DatabaseConnection(name: name, engine: .sqlite, host: "", database: path, readOnly: readOnly)
        return DatabaseConnectionDraft(connection: connection, password: "")
    }

    private static func sqliteURL(_ connection: DatabaseConnection) -> String {
        let path = connection.database
        let encoded = path == ":memory:" ? path : (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
        return "sqlite://" + encoded + (connection.readOnly ? "?mode=ro" : "")
    }

    public static func build(_ connection: DatabaseConnection, password: String) -> String {
        switch connection.engine {
        case .sqlite:
            sqliteURL(connection)
        case .mysql, .postgres:
            SQLURLs.build(connection.sqlLogin(password: password))
        case .mongo:
            MongoURLs.connectionURI(from: connection.mongoLogin(password: password))
        }
    }

    /// A URL safe to show. The password, when there is one, is `***`.
    public static func redacted(_ connection: DatabaseConnection, password: String) -> String {
        switch connection.engine {
        case .sqlite:
            sqliteURL(connection)
        case .mysql, .postgres:
            SQLURLs.build(connection.sqlLogin(password: password.isEmpty ? "" : "***"))
        case .mongo:
            MongoURLs.redactedURI(from: connection.mongoLogin(password: password))
        }
    }
}

extension DatabaseConnection {
    /// A SQLite source keeps its file path in `database`; `:memory:` is a private in-memory one.
    public var isInMemorySQLite: Bool { engine == .sqlite && database == ":memory:" }

    public func sqliteOpenOptions(createIfMissing: Bool = false) -> SQLiteOpenOptions {
        SQLiteOpenOptions(
            location: isInMemorySQLite ? .memory : .file(database), readOnly: readOnly,
            createIfMissing: createIfMissing
        )
    }

    /// `SELECT * FROM` the table, quoted for this engine.
    public func selectAll(from table: String) throws -> String {
        try SQLIdentifiers.selectAll(from: table, engine: engine)
    }
}
