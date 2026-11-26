import DatabaseCore
import Foundation

/// One new row. A field whose value is `.expression(.columnDefault)` is left out of the column
/// list, so SQLite applies the default itself (and assigns a rowid alias).
public struct SQLiteInsert: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public let column: String
        public let value: SQLiteCellValue

        public init(column: String, value: SQLiteCellValue) {
            self.column = column
            self.value = value
        }
    }

    public let fields: [Field]

    public init(fields: [Field]) { self.fields = fields }

    public func statement(table: String) throws -> (sql: String, parameters: [DatabaseValue]) {
        guard Set(fields.map { $0.column.lowercased() }).count == fields.count,
              fields.allSatisfy({ $0.value.isEditable }) else {
            throw DatabaseError.executionFailed("The new row needs distinct columns and editable values.")
        }
        let qualified = try "main." + SQLiteOptimisticUpdate.quote(table)
        let written = fields.filter { field in
            if case .expression(.columnDefault) = field.value { return false }
            return true
        }
        guard !written.isEmpty else { return ("INSERT INTO \(qualified) DEFAULT VALUES;", []) }
        let names = try written.map { try SQLiteOptimisticUpdate.quote($0.column) }.joined(separator: ", ")
        let values = written.map { field -> String in
            if case .expression(let expression) = field.value { return expression.sql }
            return "?"
        }.joined(separator: ", ")
        return ("INSERT INTO \(qualified) (\(names))\nVALUES (\(values));", written.compactMap(\.value.literal))
    }
}

/// Deletes the row a key identifies, but only while the values the grid loaded still match.
/// A column whose loaded value is binary or truncated cannot be compared and is left out of
/// `originals`; the preview says how many.
public struct SQLiteDelete: Equatable, Sendable {
    public let keys: [SQLiteOptimisticUpdate.Key]
    public let originals: [SQLiteOptimisticUpdate.Key]

    public init(keys: [SQLiteOptimisticUpdate.Key], originals: [SQLiteOptimisticUpdate.Key]) {
        self.keys = keys
        self.originals = originals
    }

    public func statement(table: String) throws -> (sql: String, parameters: [DatabaseValue]) {
        let keyNames = Set(keys.map { $0.column.lowercased() })
        guard !keys.isEmpty, keys.allSatisfy({ !$0.value.isNull && SQLiteOptimisticUpdate.isEditableValue($0.value) }),
              originals.allSatisfy({ SQLiteOptimisticUpdate.isEditableValue($0.value) && !keyNames.contains($0.column.lowercased()) }),
              Set(originals.map { $0.column.lowercased() }).count == originals.count else {
            throw DatabaseError.executionFailed("The row needs a complete key and comparable values.")
        }
        let compared = keys + originals
        let whereClause = try SQLiteOptimisticUpdate.keyLookup(keys) + " AND " + SQLiteOptimisticUpdate.matches(compared)
        return ("DELETE FROM main.\(try SQLiteOptimisticUpdate.quote(table))\nWHERE \(whereClause);",
                keys.map(\.value) + compared.flatMap { [$0.value, $0.value] })
    }

    func readCurrent(table: String) throws -> (sql: String, parameters: [DatabaseValue])? {
        guard !originals.isEmpty else { return nil }
        let fields = try originals.map { try SQLiteOptimisticUpdate.quote($0.column) }.joined(separator: ", ")
        return try SQLiteOptimisticUpdate.readStatement(fields: fields, table: table, keys: keys)
    }
}

public enum SQLiteRowMutation: Equatable, Sendable {
    case update(SQLiteOptimisticUpdate)
    case insert(SQLiteInsert)
    case delete(SQLiteDelete)

    public func statement(table: String) throws -> (sql: String, parameters: [DatabaseValue]) {
        switch self {
        case .update(let update): try update.statement(table: table)
        case .insert(let insert): try insert.statement(table: table)
        case .delete(let delete): try delete.statement(table: table)
        }
    }
}

/// A statement the database refused (a constraint, a trigger, a locked file). The whole batch is
/// rolled back; `index` names the mutation, so the caller can show which row was rejected.
public struct SQLiteMutationFailure: Error, LocalizedError, Sendable {
    public let index: Int
    public let message: String
    public let code: String?

    public var errorDescription: String? { message }
}

public struct SQLMutationResult: Equatable, Sendable {
    /// Rows the mutations changed, one per mutation (every mutation must change exactly one).
    public var rowsAffected: Int
    /// The batch ran inside a transaction the caller had already opened and did not commit it.
    public var leftTransactionOpen: Bool
    /// The rowid each insert received, keyed by the insert's position in the batch.
    public var insertedRowIDs: [Int: Int64]
}
