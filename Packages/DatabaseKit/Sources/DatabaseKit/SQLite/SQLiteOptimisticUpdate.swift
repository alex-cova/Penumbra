import DatabaseCore
import Foundation

/// A value a staged change writes: a bound parameter, or one of the few SQL expressions the
/// editor offers. Expressions are never free text: the three clock functions and the column's
/// own `DEFAULT` clause, read from the schema.
public enum SQLiteCellValue: Equatable, Sendable {
    case value(DatabaseValue)
    case expression(SQLiteExpression)

    public var isNull: Bool {
        if case .value(let value) = self { return value.isNull }
        return false
    }

    /// The bound value, nil for an expression.
    public var literal: DatabaseValue? {
        if case .value(let value) = self { return value }
        return nil
    }

    public var isEditable: Bool {
        switch self {
        case .value(let value): SQLiteOptimisticUpdate.isEditableValue(value)
        case .expression(let expression): expression.isSupported
        }
    }
}

public enum SQLiteExpression: Equatable, Sendable {
    case currentTimestamp
    case currentDate
    case currentTime
    /// The `DEFAULT` expression text of a column, exactly as `pragma_table_xinfo` reports it.
    /// An INSERT leaves the column out so SQLite applies it; an UPDATE inlines it in parentheses.
    case columnDefault(String)

    public var isSupported: Bool {
        guard case .columnDefault(let text) = self else { return true }
        return !text.isEmpty && text.utf8.count <= 512 && !text.contains(";") && !text.contains("\0")
    }

    /// SQL for an UPDATE assignment or an INSERT value list.
    var sql: String {
        switch self {
        case .currentTimestamp: "CURRENT_TIMESTAMP"
        case .currentDate: "CURRENT_DATE"
        case .currentTime: "CURRENT_TIME"
        case .columnDefault(let text): "(\(text))"
        }
    }

    public var title: String {
        switch self {
        case .currentTimestamp: "CURRENT_TIMESTAMP"
        case .currentDate: "CURRENT_DATE"
        case .currentTime: "CURRENT_TIME"
        case .columnDefault(let text): "DEFAULT \(text)"
        }
    }
}

public struct SQLiteOptimisticUpdate: Equatable, Sendable {
    public struct Key: Equatable, Sendable {
        public let column: String
        public let value: DatabaseValue

        public init(column: String, value: DatabaseValue) {
            self.column = column
            self.value = value
        }
    }

    public struct Change: Equatable, Sendable {
        public let column: String
        public let original: DatabaseValue
        public let replacement: SQLiteCellValue

        public init(column: String, original: DatabaseValue, replacement: SQLiteCellValue) {
            self.column = column
            self.original = original
            self.replacement = replacement
        }

        public init(column: String, original: DatabaseValue, replacement: DatabaseValue) {
            self.init(column: column, original: original, replacement: .value(replacement))
        }
    }

    public let keys: [Key]
    public let changes: [Change]

    public init(keys: [Key], changes: [Change]) {
        self.keys = keys
        self.changes = changes
    }

    public func statement(table: String) throws -> (sql: String, parameters: [DatabaseValue]) {
        guard !keys.isEmpty, !changes.isEmpty,
              Set((keys.map(\.column) + changes.map(\.column)).map { $0.lowercased() }).count == keys.count + changes.count,
              keys.allSatisfy({ !$0.value.isNull && Self.isEditableValue($0.value) }),
              changes.allSatisfy({ Self.isEditableValue($0.original) && $0.replacement.isEditable }) else {
            throw DatabaseError.executionFailed("The row needs a complete key and editable values.")
        }
        let qualified = try "main." + Self.quote(table)
        let assignments = try changes.map { change in
            let name = try Self.quote(change.column)
            switch change.replacement {
            case .value: return name + " = ?"
            case .expression(let expression): return name + " = " + expression.sql
            }
        }.joined(separator: ", ")
        let originals = originalsIncludingKeys
        let whereClause = try Self.keyLookup(keys) + " AND " + Self.matches(originals)
        return ("UPDATE \(qualified)\nSET \(assignments)\nWHERE \(whereClause);",
                changes.compactMap(\.replacement.literal) + keys.map(\.value) + originals.flatMap { [$0.value, $0.value] })
    }

    func readCurrent(table: String) throws -> (sql: String, parameters: [DatabaseValue]) {
        let fields = try changes.map { try Self.quote($0.column) }.joined(separator: ", ")
        return try Self.readStatement(fields: fields, table: table, keys: keys)
    }

    public static func isEditableValue(_ value: DatabaseValue) -> Bool {
        switch value {
        case .null, .int, .text: true
        case .double(let number): number.isFinite
        default: false
        }
    }

    private var originalsIncludingKeys: [Key] {
        keys + changes.map { Key(column: $0.column, value: $0.original) }
    }

    static func readStatement(fields: String, table: String, keys: [Key]) throws -> (sql: String, parameters: [DatabaseValue]) {
        let whereClause = try keyLookup(keys) + " AND " + matches(keys)
        return ("SELECT \(fields) FROM main.\(try quote(table)) WHERE \(whereClause) LIMIT 2",
                keys.map(\.value) + keys.flatMap { [$0.value, $0.value] })
    }

    static func matches(_ columns: [Key]) throws -> String {
        try columns.map {
            let name = try quote($0.column)
            return "(typeof(\(name)) = typeof(?) AND +\(name) COLLATE BINARY IS ?)"
        }.joined(separator: " AND ")
    }

    static func keyLookup(_ keys: [Key]) throws -> String {
        try keys.map { try quote($0.column) + " = ?" }.joined(separator: " AND ")
    }

    static func quote(_ name: String) throws -> String {
        try SQLIdentifiers.quote(name, engine: .sqlite)
    }
}

public struct SQLiteOptimisticConflict: Error, Sendable {
    public let updateIndex: Int
    /// The latest values for the changed columns in the preview, or nil for a missing row.
    public let current: [DatabaseValue]?
    /// A delete found its row changed or gone; `current` then holds the compared columns.
    public let isDeletion: Bool

    init(updateIndex: Int, current: [DatabaseValue]?, isDeletion: Bool = false) {
        self.updateIndex = updateIndex
        self.current = current
        self.isDeletion = isDeletion
    }
}
