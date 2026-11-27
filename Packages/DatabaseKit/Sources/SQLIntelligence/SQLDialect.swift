import DatabaseCore
import Foundation

/// The SQL dialects the console understands. Each differs in how text is written (quoting,
/// comments, string escapes) and in what exists (keywords, types, functions), so everything in
/// this module takes one.
public enum SQLDialect: String, Sendable, CaseIterable {
    case postgres, mysql, sqlite

    public init?(engine: DatabaseEngine) {
        switch engine {
        case .postgres: self = .postgres
        case .mysql: self = .mysql
        case .sqlite: self = .sqlite
        case .mongo: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .sqlite: "SQLite"
        }
    }

    /// The character that quotes an identifier in this dialect's own style.
    public var identifierQuote: Character {
        self == .mysql ? "`" : "\""
    }

    /// MySQL reads a backslash inside `'…'` as an escape; PostgreSQL does only in `E'…'`; SQLite never.
    var backslashEscapesInStrings: Bool { self == .mysql }

    /// `#` starts a comment in MySQL only. (`--` always does.)
    var hashComments: Bool { self == .mysql }

    /// `/* … /* … */ … */` nests in PostgreSQL only.
    var nestedBlockComments: Bool { self == .postgres }

    /// `$tag$ … $tag$` strings are PostgreSQL's.
    var dollarQuotes: Bool { self == .postgres }

    /// `[name]` quotes an identifier in SQLite (for compatibility); in PostgreSQL it is array syntax.
    var bracketIdentifiers: Bool { self == .sqlite }

    /// Backtick-quoted identifiers: MySQL's own, accepted by SQLite.
    var backtickIdentifiers: Bool { self != .postgres }

    /// In MySQL a double-quoted token is a string (unless `ANSI_QUOTES` is set); elsewhere it is an
    /// identifier.
    var doubleQuotesAreStrings: Bool { self == .mysql }

    /// The `DELIMITER` client directive exists only in the `mysql` client and tools that copy it.
    var supportsDelimiterDirective: Bool { self == .mysql }

    /// Does `E'…'` or `N'…'` style prefix a string?
    func stringPrefixes() -> Set<Character> {
        switch self {
        case .postgres: ["E", "e", "B", "b", "X", "x", "U", "u"]
        case .mysql: ["N", "n", "B", "b", "X", "x"]
        case .sqlite: ["X", "x"]
        }
    }
}
