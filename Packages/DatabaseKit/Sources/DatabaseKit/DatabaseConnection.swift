@_exported import DatabaseCore
@_exported import SQLIntelligence
import Foundation
import MySQLKit
import PostgresKit

extension DatabaseEngine {
    /// The port a server of this engine listens on by default. Lives here, not in
    /// `DatabaseCore`, because the constants come from the drivers.
    public var defaultPort: Int {
        switch self {
        case .mysql: MySQLConfiguration.ianaPortNumber
        case .postgres: SQLPostgresConfiguration.ianaPortNumber
        case .sqlite: 0  // a file has no port
        case .mongo: 27017
        }
    }
}

/// A saved data source. The password is never a field: it lives in the login Keychain.
public struct DatabaseConnection: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var engine: DatabaseEngine
    public var host: String
    public var port: Int
    public var username: String
    /// SQL database, or the Mongo database a new console opens.
    public var database: String
    public var useTLS: Bool
    /// Make TLS mandatory with certificate verification (PostgreSQL; MySQL already requires it
    /// when `useTLS` is set). `nil` in files saved before this existed: those keep `useTLS`
    /// semantics unchanged.
    public var tlsRequired: Bool?
    public var readOnly: Bool
    public var authSource: String
    public var useSRV: Bool
    public var replicaSet: String
    public var directConnection: Bool
    /// The last statement run against this data source, so it can be reopened.
    public var lastStatement: String
    public var sortIndex: Int
    public var isProduction: Bool?
    public var group: String?
    public var sqliteBusyTimeoutMilliseconds: Int?

    public init(
        id: UUID = UUID(),
        name: String = "",
        engine: DatabaseEngine = .postgres,
        host: String = "localhost",
        port: Int? = nil,
        username: String = "",
        database: String = "",
        useTLS: Bool = false,
        tlsRequired: Bool? = nil,
        readOnly: Bool = false,
        authSource: String = "admin",
        useSRV: Bool = false,
        replicaSet: String = "",
        directConnection: Bool = true,
        lastStatement: String = "",
        sortIndex: Int = 0,
        isProduction: Bool? = nil,
        group: String? = nil,
        sqliteBusyTimeoutMilliseconds: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.host = host
        self.port = port ?? engine.defaultPort
        self.username = username
        self.database = database
        self.useTLS = useTLS
        self.tlsRequired = tlsRequired
        self.readOnly = readOnly
        self.authSource = authSource
        self.useSRV = useSRV
        self.replicaSet = replicaSet
        self.directConnection = directConnection
        self.lastStatement = lastStatement
        self.sortIndex = sortIndex
        self.isProduction = isProduction
        self.group = group
        self.sqliteBusyTimeoutMilliseconds = sqliteBusyTimeoutMilliseconds
    }

    public func mongoLogin(password: String) -> MongoLogin {
        MongoLogin(
            host: host,
            port: port,
            username: username,
            password: password,
            authSource: authSource,
            defaultDatabase: database,
            useTLS: useTLS,
            useSRV: useSRV,
            replicaSet: replicaSet,
            directConnection: directConnection
        )
    }
}

/// A connection plus the password the sheet is holding. The password is not encoded with the connection.
public struct DatabaseConnectionDraft: Equatable, Sendable {
    public var connection: DatabaseConnection
    public var password: String

    public init(connection: DatabaseConnection, password: String) {
        self.connection = connection
        self.password = password
    }
}

public enum DatabaseError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL(String)
    case invalidIdentifier(String)
    case notConnected
    case readOnlyViolation
    case executionFailed(String)
    case invalidJSON(String)
    case missingDocumentID
    case connectionTimedOut(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            "Invalid connection URL: \(url)"
        case .invalidIdentifier(let name):
            "Invalid SQL identifier: \(name)"
        case .notConnected:
            "Not connected to a database."
        case .readOnlyViolation:
            "Read-only mode blocks mutating statements."
        case .executionFailed(let message):
            message
        case .invalidJSON(let message):
            "Invalid JSON: \(message)"
        case .missingDocumentID:
            "Document is missing an _id field."
        case .connectionTimedOut(let seconds):
            "Connection timed out after \(Self.seconds(seconds))s."
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// How many rows a page asks for.
public enum DatabasePageSize {
    public static let sql = 200
    public static let mongo = 50
}
