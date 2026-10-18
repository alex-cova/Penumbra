import Foundation

/// One page of cells. `nil` is SQL NULL (or a missing Mongo field), distinct from an empty string.
public struct QueryResult: Equatable, Sendable {
    public var columns: [String]
    public var rows: [[String?]]
    public var rowsAffected: Int?
    public var isReadQuery: Bool

    public init(columns: [String], rows: [[String?]], rowsAffected: Int?, isReadQuery: Bool) {
        self.columns = columns
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.isReadQuery = isReadQuery
    }
}

public struct SQLColumn: Equatable, Sendable, Identifiable {
    public let name: String
    public let declaredType: String
    public let isPrimaryKey: Bool
    public let isNotNull: Bool
    /// The `DEFAULT` expression, if any (PostgreSQL bulk load; empty otherwise).
    public let defaultValue: String

    public var id: String { name }

    public init(name: String, declaredType: String, isPrimaryKey: Bool, isNotNull: Bool, defaultValue: String = "") {
        self.name = name
        self.declaredType = declaredType
        self.isPrimaryKey = isPrimaryKey
        self.isNotNull = isNotNull
        self.defaultValue = defaultValue
    }
}

/// One foreign key: `fromTable.fromColumn` references `toTable.toColumn`.
public struct SQLForeignKey: Equatable, Sendable {
    public let fromTable: String
    public let fromColumn: String
    public let toTable: String
    public let toColumn: String

    public init(fromTable: String, fromColumn: String, toTable: String, toColumn: String) {
        self.fromTable = fromTable
        self.fromColumn = fromColumn
        self.toTable = toTable
        self.toColumn = toColumn
    }
}

public struct SQLIndex: Equatable, Sendable, Identifiable {
    public let name: String
    public let columns: [String]
    public let isUnique: Bool

    public var id: String { name }

    public init(name: String, columns: [String], isUnique: Bool) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
    }
}

/// A live SQL session Umbra can run statements through. Tests supply their own.
public protocol SQLExecuting: Sendable {
    func query(_ sql: String) async throws -> QueryResult
}

enum SQLShaping {
    /// The first keyword after leading whitespace and comments.
    static func firstKeyword(in sql: String) -> String? {
        var remainder = sql[...]

        while true {
            remainder = remainder.drop(while: \.isWhitespace)

            if remainder.hasPrefix("--") || remainder.hasPrefix("#") {
                guard let newline = remainder.firstIndex(of: "\n") else { return nil }
                remainder = remainder[remainder.index(after: newline)...]
                continue
            }

            if remainder.hasPrefix("/*") {
                guard let commentEnd = remainder.range(of: "*/")?.upperBound else { return nil }
                remainder = remainder[commentEnd...]
                continue
            }

            break
        }

        let keyword = remainder.prefix { $0.isLetter }
        return keyword.isEmpty ? nil : keyword.uppercased()
    }

    static func stripTrailingSemicolons(_ sql: String) -> String {
        var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(";") {
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    static func composedQuery(
        base: String,
        quotedSortColumn: String?,
        sortAscending: Bool,
        limit: Int,
        offset: Int
    ) -> String {
        let stripped = stripTrailingSemicolons(base)
        var sql = "SELECT * FROM (\(stripped)) AS __umbra_q"
        if let quotedSortColumn {
            sql += " ORDER BY \(quotedSortColumn) \(sortAscending ? "ASC" : "DESC")"
        }
        sql += " LIMIT \(max(1, limit)) OFFSET \(max(0, offset))"
        return sql
    }

    static func isReadOnlyStatement(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let firstToken = firstKeyword(in: stripTrailingSemicolons(trimmed)) else { return false }
        switch firstToken {
        case "SELECT", "WITH", "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "PRAGMA":
            return true
        default:
            return false
        }
    }

    static func isPaginatable(_ sql: String) -> Bool {
        guard let keyword = firstKeyword(in: sql) else { return false }
        return keyword == "SELECT" || keyword == "WITH"
    }
}

public enum SQLIdentifiers {
    public static func quote(_ identifier: String, engine: DatabaseEngine) throws -> String {
        guard isValid(identifier) else { throw DatabaseError.invalidIdentifier(identifier) }
        switch engine {
        case .mysql:
            return "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
        case .postgres, .mongo:
            return "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
    }

    public static func selectAll(from table: String, engine: DatabaseEngine) throws -> String {
        let quoted = try quote(table, engine: engine)
        return "SELECT * FROM \(quoted)"
    }

    /// The text to insert for a completion candidate: the bare name, unless it needs quoting,
    /// in which case the engine's quoting (backticks for MySQL, double quotes otherwise). Unlike
    /// `quote(_:engine:)`, which rejects unsafe names for composed SQL, this quotes any
    /// schema name with the quote character escaped, so completion never fails on an odd name.
    public static func insertName(_ identifier: String, engine: DatabaseEngine) -> String {
        guard !identifier.isEmpty, needsQuoting(identifier) else { return identifier }
        switch engine {
        case .mysql:
            return "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
        case .postgres, .mongo:
            return "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
    }

    /// True when the name cannot appear bare in a statement: not a plain identifier, or a
    /// reserved word.
    public static func needsQuoting(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, isBare(identifier) else { return true }
        return reservedWords.contains(identifier.uppercased())
    }

    private static func isBare(_ identifier: String) -> Bool {
        guard let first = identifier.unicodeScalars.first,
              first == "_" || first.properties.isAlphabetic else { return false }
        return identifier.unicodeScalars.allSatisfy { scalar in
            scalar == "_"
                || scalar.isASCII
                && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil)
        }
    }

    /// Words that need quoting when used as a table or column name.
    private static let reservedWords: Set<String> = [
        "SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "FROM", "WHERE", "JOIN", "INTO",
        "TABLE", "ORDER", "GROUP", "BY", "HAVING", "SET", "VALUES", "ON", "AND", "OR",
        "AS", "SHOW", "EXPLAIN",
    ]

    private static func isValid(_ identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        guard identifier.unicodeScalars.allSatisfy({ scalar in
            scalar == "_" || scalar.isASCII && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil)
        }) else { return false }
        guard let first = identifier.unicodeScalars.first else { return false }
        return first == "_" || first.properties.isAlphabetic
    }
}

/// Runs one console statement: refuses writes on a read-only connection, and pages `SELECT` / `WITH`.
public enum DatabaseQuery {
    public static func run(
        statement: String,
        readOnly: Bool,
        page: Int,
        pageSize: Int,
        sortColumn: String? = nil,
        sortAscending: Bool = true,
        engine: DatabaseEngine,
        using session: any SQLExecuting
    ) async throws -> QueryResult {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DatabaseError.executionFailed("Query is empty")
        }
        if readOnly, !SQLShaping.isReadOnlyStatement(trimmed) {
            throw DatabaseError.readOnlyViolation
        }

        let sql: String
        if SQLShaping.isPaginatable(trimmed) {
            let quoted = try sortColumn.map { try SQLIdentifiers.quote($0, engine: engine) }
            sql = SQLShaping.composedQuery(
                base: trimmed,
                quotedSortColumn: quoted,
                sortAscending: sortAscending,
                limit: pageSize,
                offset: page * pageSize
            )
        } else {
            sql = trimmed
        }
        return try await session.query(sql)
    }
}

/// CSV, TSV and JSON for the page on screen.
public enum QueryExport {
    private static let formulaTriggers: Set<Character> = ["=", "+", "-", "@"]

    public static func csv(columns: [String], rows: [[String?]]) -> String {
        separated(columns: columns, rows: rows, separator: ",", nullText: "")
    }

    public static func tsv(columns: [String], rows: [[String?]]) -> String {
        separated(columns: columns, rows: rows, separator: "\t", nullText: "NULL")
    }

    public static func json(columns: [String], rows: [[String?]]) -> String {
        guard !rows.isEmpty else { return "[]" }
        var lines: [String] = ["["]
        for (rowIndex, row) in rows.enumerated() {
            let fields = columns.indices.map { index -> String in
                let value = index < row.count ? row[index] : nil
                let jsonValue = value.map(jsonStringLiteral) ?? "null"
                return "\(jsonStringLiteral(columns[index])): \(jsonValue)"
            }
            let suffix = rowIndex < rows.count - 1 ? "," : ""
            lines.append("  {" + fields.joined(separator: ", ") + "}" + suffix)
        }
        lines.append("]")
        return lines.joined(separator: "\n")
    }

    private static func separated(
        columns: [String],
        rows: [[String?]],
        separator: String,
        nullText: String
    ) -> String {
        var lines: [String] = [columns.map { field($0, separator: separator) }.joined(separator: separator)]
        for row in rows {
            let fields = columns.indices.map { index -> String in
                guard row.indices.contains(index), let value = row[index] else { return nullText }
                return field(value, separator: separator)
            }
            lines.append(fields.joined(separator: separator))
        }
        return lines.joined(separator: "\r\n")
    }

    private static func field(_ value: String, separator: String) -> String {
        guard !value.isEmpty else { return "" }
        var sanitized = value
        if let first = sanitized.first, formulaTriggers.contains(first) {
            sanitized = "'" + sanitized
        }
        let needsQuoting = sanitized.contains(separator) || sanitized.contains("\"")
            || sanitized.contains("\n") || sanitized.contains("\r")
        guard needsQuoting else { return sanitized }
        return "\"\(sanitized.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }
}
