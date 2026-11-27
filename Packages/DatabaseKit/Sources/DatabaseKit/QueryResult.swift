import Foundation

/// One page of cells. `nil` is SQL NULL (or a missing Mongo field), distinct from an empty string.
public struct QueryResult: Equatable, Sendable {
    public var columns: [String]
    public var rows: [[String?]]
    public var rowsAffected: Int?
    public var isReadQuery: Bool
    /// The statement was cancelled, so `rows` is what arrived before it stopped (possibly none).
    public var wasCancelled: Bool
    public var notices: [DatabaseNotice]

    public init(
        columns: [String], rows: [[String?]], rowsAffected: Int?, isReadQuery: Bool, wasCancelled: Bool = false,
        notices: [DatabaseNotice] = []
    ) {
        self.columns = columns
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.isReadQuery = isReadQuery
        self.wasCancelled = wasCancelled
        self.notices = notices
    }
}

public struct SQLColumn: Equatable, Sendable, Identifiable {
    public let name: String
    public let declaredType: String
    public let isPrimaryKey: Bool
    public let isNotNull: Bool
    /// The `DEFAULT` expression, if any (PostgreSQL bulk load; empty otherwise).
    public let defaultValue: String
    /// A generated column: it cannot be written.
    public let isGenerated: Bool
    /// `GENERATED ALWAYS AS IDENTITY`: the server assigns it and refuses a value.
    public let isIdentityAlways: Bool

    public var id: String { name }

    public init(
        name: String, declaredType: String, isPrimaryKey: Bool, isNotNull: Bool, defaultValue: String = "",
        isGenerated: Bool = false, isIdentityAlways: Bool = false
    ) {
        self.name = name
        self.declaredType = declaredType
        self.isPrimaryKey = isPrimaryKey
        self.isNotNull = isNotNull
        self.defaultValue = defaultValue
        self.isGenerated = isGenerated
        self.isIdentityAlways = isIdentityAlways
    }
}

/// One column pair of a foreign key: `fromTable.fromColumn` references `toTable.toColumn`. A
/// composite key is several of these with the same `constraint`, in `ordinal` order.
public struct SQLForeignKey: Equatable, Sendable {
    public let fromTable: String
    public let fromColumn: String
    public let toTable: String
    public let toColumn: String
    public let constraint: String?
    public let ordinal: Int

    public init(
        fromTable: String, fromColumn: String, toTable: String, toColumn: String, constraint: String? = nil, ordinal: Int = 0
    ) {
        self.fromTable = fromTable
        self.fromColumn = fromColumn
        self.toTable = toTable
        self.toColumn = toColumn
        self.constraint = constraint
        self.ordinal = ordinal
    }
}

/// A table or view in the schema.
public struct SQLRelationInfo: Equatable, Sendable {
    public let name: String
    public let isView: Bool

    public init(name: String, isView: Bool) {
        self.name = name
        self.isView = isView
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
    func query(_ sql: String, parameters: [DatabaseValue]) async throws -> QueryResult
    func execute(_ sql: String, parameters: [DatabaseValue], into store: ResultStore) async throws -> ExecutionSummary
}

public extension SQLExecuting {
    func execute(_ sql: String, parameters: [DatabaseValue], into store: ResultStore) async throws -> ExecutionSummary {
        let result = try await query(sql, parameters: parameters)
        let columns = result.columns.map { ResultColumn(name: $0) }
        await store.setColumns(columns)
        let accepted = try await store.append(result.rows.map { $0.map { $0.map(DatabaseValue.text) ?? .null } })
        await store.finish()
        return ExecutionSummary(columns: columns, rowCount: await store.rowCount, affectedRows: result.rowsAffected,
                                limitReached: !accepted, wasCancelled: result.wasCancelled, notices: result.notices)
    }

    func query(_ sql: String, parameters: [DatabaseValue]) async throws -> QueryResult {
        guard parameters.isEmpty else { throw DatabaseError.executionFailed("This session does not support bound parameters.") }
        return try await query(sql)
    }
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

    static let paginationPrefix = "SELECT * FROM ("

    static func composedQuery(
        base: String,
        quotedSortColumn: String?,
        sortAscending: Bool,
        limit: Int?,
        offset: Int
    ) -> String {
        let stripped = stripTrailingSemicolons(base)
        var sql = "\(paginationPrefix)\(stripped)) AS __umbra_q"
        if let quotedSortColumn {
            sql += " ORDER BY \(quotedSortColumn) \(sortAscending ? "ASC" : "DESC")"
        }
        if let limit { sql += " LIMIT \(max(1, limit)) OFFSET \(max(0, offset))" }
        return sql
    }

    /// Words that make a statement non-read-only wherever they appear outside a string, comment
    /// or quoted identifier: data-modifying CTEs (`WITH x AS (DELETE …)`), `EXPLAIN ANALYZE
    /// DELETE …`, `SELECT … INTO` / `INTO OUTFILE`, and row locks (`FOR UPDATE`).
    private static let writeWords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE", "INTO", "TRUNCATE", "DROP", "ALTER",
        "CREATE", "GRANT", "REVOKE", "CALL", "COPY", "LOCK",
    ]

    /// Functions known to change state from inside a `SELECT`. A denylist cannot be complete, so
    /// this is a stopgap: the real guarantee is a read-only session or transaction on the server.
    private static let sideEffectFunctions: Set<String> = [
        "NEXTVAL", "SETVAL", "SET_CONFIG", "PG_TERMINATE_BACKEND", "PG_CANCEL_BACKEND",
        "PG_RELOAD_CONF", "PG_ROTATE_LOGFILE", "LO_IMPORT", "LO_EXPORT", "LO_UNLINK", "LO_CREATE",
        "PG_ADVISORY_LOCK", "PG_ADVISORY_XACT_LOCK", "PG_TRY_ADVISORY_LOCK", "DBLINK_EXEC",
        "DBLINK", "GET_LOCK", "RELEASE_LOCK", "LOAD_FILE",
        "PG_COPY_PHYSICAL_REPLICATION_SLOT", "PG_CREATE_RESTORE_POINT",
    ]

    /// Every word outside strings, comments and quoted identifiers, upper-cased, plus whether a
    /// second statement follows the first. Handles `'…'` (with `''` and `\'`), `"…"`, `` `…` ``,
    /// `--` / `#` / `/* */` comments and PostgreSQL `$tag$…$tag$` bodies.
    static func words(in sql: String) -> (words: [String], hasSecondStatement: Bool) {
        let scalars = Array(sql.unicodeScalars)
        var words: [String] = []
        var sawTerminator = false
        var hasSecondStatement = false
        var index = 0

        func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
        }

        while index < scalars.count {
            let scalar = scalars[index]
            let next: Unicode.Scalar? = index + 1 < scalars.count ? scalars[index + 1] : nil
            switch scalar {
            case "-" where next == "-", "#":
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
            case "/" where next == "*":
                index += 2
                while index + 1 < scalars.count, !(scalars[index] == "*" && scalars[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, scalars.count)
            case "'", "\"", "`":
                if sawTerminator { hasSecondStatement = true }
                let quote = scalar
                index += 1
                while index < scalars.count {
                    if scalars[index] == "\\", quote == "'" { index += 2; continue }
                    if scalars[index] == quote {
                        if index + 1 < scalars.count, scalars[index + 1] == quote { index += 2; continue }
                        break
                    }
                    index += 1
                }
                index += 1
            case "$":
                // `$tag$ … $tag$`; a bare `$1` placeholder has no closing `$`.
                var cursor = index + 1
                while cursor < scalars.count, isWordScalar(scalars[cursor]) { cursor += 1 }
                // A tag is empty or starts with a non-digit; `$1$` is not one.
                let tagStartsWithDigit = cursor > index + 1 && ("0"..."9").contains(scalars[index + 1])
                if cursor < scalars.count, scalars[cursor] == "$", !tagStartsWithDigit {
                    let tag = Array(scalars[index...cursor])
                    var search = cursor + 1
                    var closed = false
                    while search + tag.count <= scalars.count {
                        if Array(scalars[search..<search + tag.count]) == tag { closed = true; break }
                        search += 1
                    }
                    if sawTerminator { hasSecondStatement = true }
                    index = closed ? search + tag.count : scalars.count
                } else {
                    index += 1
                }
            case ";":
                sawTerminator = true
                index += 1
            default:
                if isWordScalar(scalar) {
                    if sawTerminator { hasSecondStatement = true }
                    var end = index + 1
                    while end < scalars.count, isWordScalar(scalars[end]) { end += 1 }
                    var word = String.UnicodeScalarView()
                    word.append(contentsOf: scalars[index..<end])
                    words.append(String(word).uppercased())
                    index = end
                } else {
                    index += 1
                }
            }
        }
        return (words, hasSecondStatement)
    }

    /// An early, client-side answer for "does this look read-only". It is a UX hint and a
    /// stopgap, never the enforcement: the server must also refuse writes (a read-only session or
    /// transaction), because no scan of the text can see what a function does.
    static func isReadOnlyStatement(_ sql: String) -> Bool {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let firstToken = firstKeyword(in: stripTrailingSemicolons(trimmed)) else { return false }
        switch firstToken {
        case "SELECT", "WITH", "SHOW", "EXPLAIN", "DESCRIBE", "DESC":
            break
        default:
            return false
        }
        let scan = words(in: trimmed)
        guard !scan.hasSecondStatement else { return false }
        return !scan.words.contains { writeWords.contains($0) || sideEffectFunctions.contains($0) }
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
        case .postgres, .sqlite, .mongo:
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
        case .postgres, .sqlite, .mongo:
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

    /// A name can be quoted safely whenever the quote character is doubled; what cannot be quoted
    /// is an empty name or one with control characters (NUL ends a C string, a newline breaks a
    /// log line). "Order Details" and "users; DROP TABLE users" are both fine to quote, and the
    /// second comes out as one identifier, not two statements.
    private static func isValid(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }
}

/// Runs one console statement: refuses writes on a read-only connection, and pages `SELECT` / `WITH`.
public enum DatabaseQuery {
    public static func canPage(_ statement: String) -> Bool {
        SQLShaping.isPaginatable(statement) && SQLShaping.isReadOnlyStatement(statement)
    }

    public static func sortedStatement(
        _ statement: String, column: String, ascending: Bool, engine: DatabaseEngine
    ) throws -> String? {
        guard canPage(statement) else { return nil }
        return SQLShaping.composedQuery(base: statement, quotedSortColumn: try SQLIdentifiers.quote(column, engine: engine),
                                       sortAscending: ascending, limit: nil, offset: 0)
    }

    public static func run(
        statement: String,
        readOnly: Bool,
        page: Int,
        pageSize: Int,
        sortColumn: String? = nil,
        sortAscending: Bool = true,
        engine: DatabaseEngine,
        using session: any SQLExecuting,
        parameters: [DatabaseValue] = []
    ) async throws -> QueryResult {
        try await runShaped(statement: statement, readOnly: readOnly, limit: pageSize,
                            offset: page * pageSize, sortColumn: sortColumn, sortAscending: sortAscending, engine: engine) {
            try await session.query($0, parameters: parameters)
        }
    }

    /// Runs a console statement once and streams its rows into the caller's store.
    public static func execute(
        statement: String, readOnly: Bool, sortColumn: String? = nil, sortAscending: Bool = true,
        engine: DatabaseEngine, using session: any SQLExecuting, parameters: [DatabaseValue] = [],
        into store: ResultStore
    ) async throws -> ExecutionSummary {
        try await runShaped(statement: statement, readOnly: readOnly, limit: nil,
                            offset: 0, sortColumn: sortColumn, sortAscending: sortAscending, engine: engine) {
            try await session.execute($0, parameters: parameters, into: store)
        }
    }

    private static func runShaped<T>(
        statement: String, readOnly: Bool, limit: Int?, offset: Int,
        sortColumn: String?, sortAscending: Bool, engine: DatabaseEngine,
        _ execute: (String) async throws -> T
    ) async throws -> T {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DatabaseError.executionFailed("Query is empty")
        }
        if readOnly, engine != .sqlite, !SQLShaping.isReadOnlyStatement(trimmed) {
            throw DatabaseError.readOnlyViolation
        }

        let sql: String
        let wrapped = (limit != nil || sortColumn != nil) && canPage(trimmed)
        if wrapped {
            let quoted = try sortColumn.map { try SQLIdentifiers.quote($0, engine: engine) }
            sql = SQLShaping.composedQuery(base: trimmed, quotedSortColumn: quoted, sortAscending: sortAscending,
                                           limit: limit, offset: offset)
        } else {
            sql = trimmed
        }
        do {
            return try await execute(sql)
        } catch var error as DatabaseServerError {
            if let position = error.position {
                let prefixLength = wrapped ? SQLShaping.paginationPrefix.unicodeScalars.count : 0
                let body = wrapped ? SQLShaping.stripTrailingSemicolons(trimmed) : trimmed
                let local = position > prefixLength ? position - prefixLength : 0
                let leading = statement.unicodeScalars.prefix {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                }.count
                error.position = local > 0 && local - 1 <= body.unicodeScalars.count ? leading + local : nil
            }
            throw error
        }
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
