import Foundation

/// What a connected server can do, filled in from what it answered, not from its brand. The UI
/// reads this to enable or explain a control; nothing is simulated for an engine that lacks it.
public struct DatabaseCapabilities: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let transactions = DatabaseCapabilities(rawValue: 1 << 0)
    public static let savepoints = DatabaseCapabilities(rawValue: 1 << 1)
    public static let isolationLevels = DatabaseCapabilities(rawValue: 1 << 2)
    public static let readOnlyTransactions = DatabaseCapabilities(rawValue: 1 << 3)
    /// A running statement can be cancelled without dropping the connection.
    public static let cancellation = DatabaseCapabilities(rawValue: 1 << 4)
    public static let explainText = DatabaseCapabilities(rawValue: 1 << 5)
    public static let explainStructured = DatabaseCapabilities(rawValue: 1 << 6)
    public static let explainAnalyze = DatabaseCapabilities(rawValue: 1 << 7)
    /// Rows can be fetched incrementally from the server (cursor or row-at-a-time protocol).
    public static let streamingCursor = DatabaseCapabilities(rawValue: 1 << 8)
    public static let multipleResultSets = DatabaseCapabilities(rawValue: 1 << 9)
    public static let foreignKeys = DatabaseCapabilities(rawValue: 1 << 10)
    public static let storedRoutines = DatabaseCapabilities(rawValue: 1 << 11)
    public static let spatial = DatabaseCapabilities(rawValue: 1 << 12)
    public static let schemas = DatabaseCapabilities(rawValue: 1 << 13)
    public static let multipleDatabases = DatabaseCapabilities(rawValue: 1 << 14)
    public static let notices = DatabaseCapabilities(rawValue: 1 << 15)
    public static let backup = DatabaseCapabilities(rawValue: 1 << 16)
    /// DDL statements implicitly commit (MySQL): a transaction cannot span them.
    public static let ddlImplicitlyCommits = DatabaseCapabilities(rawValue: 1 << 17)
    /// The session itself is read-only at the server, so a write is refused by the database.
    public static let serverEnforcedReadOnly = DatabaseCapabilities(rawValue: 1 << 18)
}

/// Facts a session reports alongside its capabilities, shown in the console header and used by
/// the SQL intelligence to pick dialect rules.
public struct ServerInfo: Equatable, Sendable, Codable {
    public var engine: DatabaseEngine
    /// The server's own version string (`16.4`, `8.4.1`, `3.54.0`, `7.0.12`).
    public var version: String
    public var majorVersion: Int
    /// Named features detected at connect, for example `postgis`, `replicaSet`, `wal`.
    public var features: Set<String>
    /// MySQL `sql_mode`, empty elsewhere.
    public var sqlMode: String

    public init(
        engine: DatabaseEngine, version: String, majorVersion: Int,
        features: Set<String> = [], sqlMode: String = ""
    ) {
        self.engine = engine
        self.version = version
        self.majorVersion = majorVersion
        self.features = features
        self.sqlMode = sqlMode
    }
}

/// A database Umbra can open.
public enum DatabaseEngine: String, Codable, CaseIterable, Sendable, Identifiable {
    case mysql
    case postgres
    case sqlite
    case mongo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mysql: "MySQL"
        case .postgres: "PostgreSQL"
        case .sqlite: "SQLite"
        case .mongo: "MongoDB"
        }
    }

    public var isSQL: Bool { self != .mongo }

    /// Reached over a network with a host and port. SQLite is a file.
    public var isNetworked: Bool { self != .sqlite }

    /// The editor language of a console bound to this engine.
    public var consoleLanguage: String {
        self == .mongo ? "json" : "sql"
    }
}
