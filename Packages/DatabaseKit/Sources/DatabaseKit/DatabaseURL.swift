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
                useTLS: login.useTLS
            )
            if connection.name.isEmpty { connection.name = connection.engine.displayName }
            return DatabaseConnectionDraft(connection: connection, password: login.password)
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

    public static func build(_ connection: DatabaseConnection, password: String) -> String {
        switch connection.engine {
        case .mysql, .postgres:
            SQLURLs.build(connection.sqlLogin(password: password))
        case .mongo:
            MongoURLs.connectionURI(from: connection.mongoLogin(password: password))
        }
    }

    /// A URL safe to show. The password, when there is one, is `***`.
    public static func redacted(_ connection: DatabaseConnection, password: String) -> String {
        switch connection.engine {
        case .mysql, .postgres:
            SQLURLs.build(connection.sqlLogin(password: password.isEmpty ? "" : "***"))
        case .mongo:
            MongoURLs.redactedURI(from: connection.mongoLogin(password: password))
        }
    }
}

extension DatabaseConnection {
    /// `SELECT * FROM` the table, quoted for this engine.
    public func selectAll(from table: String) throws -> String {
        try SQLIdentifiers.selectAll(from: table, engine: engine)
    }
}
