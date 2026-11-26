import DatabaseCore
import Foundation

/// A PostgreSQL or MySQL result that the server confirmed comes from one base table whose full
/// key is in the result. Without that confirmation there is no target and the result is
/// read-only, with the reason. Only scalar cell updates are offered on these engines.
public struct SQLEditTarget: Equatable, Sendable {
    public struct Column: Equatable, Sendable {
        /// Position in the result.
        public let resultIndex: Int
        /// The column's name in the table (a result may alias it).
        public let name: String
        /// PostgreSQL: `format_type` (`numeric(10,2)`, `timestamp with time zone`). MySQL: `DATA_TYPE`.
        public let typeName: String
        public let isKey: Bool
        public let isRequired: Bool
        /// Nil when a cell of this column can be edited, else why not.
        public let readOnlyReason: String?

        public init(
            resultIndex: Int, name: String, typeName: String, isKey: Bool, isRequired: Bool, readOnlyReason: String? = nil
        ) {
            self.resultIndex = resultIndex
            self.name = name
            self.typeName = typeName
            self.isKey = isKey
            self.isRequired = isRequired
            self.readOnlyReason = readOnlyReason
        }
    }

    public let engine: DatabaseEngine
    public let schema: String
    public let table: String
    public let keys: [Column]
    public let columns: [Column]

    public init(engine: DatabaseEngine, schema: String, table: String, keys: [Column], columns: [Column]) {
        self.engine = engine
        self.schema = schema
        self.table = table
        self.keys = keys
        self.columns = columns
    }

    public func column(named name: String) -> Column? { columns.first { $0.name == name } }
}

extension SQLEditTarget {
    /// The guarded UPDATE a staged row will run, with its bound parameters.
    public func statement(for update: SQLiteOptimisticUpdate) throws -> (sql: String, parameters: [DatabaseValue]) {
        try SQLEditStatements.update(update, target: self)
    }
}

public enum SQLEditResolution: Equatable, Sendable {
    case editable(SQLEditTarget)
    case readOnly(String)
}

private func literal(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
}

extension SQLSession {
    /// Decides, from what the server itself reports, whether a result may be edited.
    public func resolveEditTarget(columns: [ResultColumn]) async -> SQLEditResolution {
        if readOnly { return .readOnly("This connection is read-only.") }
        return await resolveRowSource(columns: columns)
    }

    /// The same verification without the write check: which table and key a result's rows come
    /// from. Reading one large value or following a foreign key needs the identity, not the right
    /// to write, so a read-only connection still gets it.
    public func resolveRowSource(columns: [ResultColumn]) async -> SQLEditResolution {
        do {
            switch engine {
            case .postgres: return try await resolvePostgres(columns)
            case .mysql: return try await resolveMySQL(columns)
            case .sqlite, .mongo: return .readOnly("\(engine.displayName) results are verified elsewhere.")
            }
        } catch {
            return .readOnly("The source table could not be verified: \(error.localizedDescription)")
        }
    }

    // MARK: PostgreSQL

    static let postgresEditableTypes: Set<String> = [
        "smallint", "integer", "bigint", "numeric", "boolean", "text", "character varying", "character", "date",
        "timestamp without time zone", "timestamp with time zone", "time without time zone", "time with time zone", "uuid",
    ]

    private func resolvePostgres(_ columns: [ResultColumn]) async throws -> SQLEditResolution {
        let sources = columns.compactMap(\.postgresSource)
        guard !sources.isEmpty else { return .readOnly("The result has no columns that come from a table.") }
        let relations = Set(sources.map(\.tableOID))
        let attributes = try await postgresQuery("""
        SELECT a.attrelid::int8, a.attnum, n.nspname, c.relname, a.attname, format_type(a.atttypid, a.atttypmod),
               a.attnotnull, a.attgenerated::text, a.attidentity::text, c.relkind::text, t.typtype::text
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_type t ON t.oid = a.atttypid
        WHERE a.attrelid IN (\(relations.sorted().map(String.init).joined(separator: ", "))) AND a.attnum > 0 AND NOT a.attisdropped
        """)
        struct Attribute {
            let oid: UInt32, number: Int16, schema: String, table: String, name: String
            let type: String, notNull: Bool, generated: String, identity: String, kind: String, typeKind: String
        }
        let all: [Attribute] = attributes.rows.compactMap { row in
            guard row.count >= 11, let oid = UInt32(row[0] ?? ""), let number = Int16(row[1] ?? ""),
                  let schema = row[2], let table = row[3], let name = row[4], let type = row[5] else { return nil }
            return Attribute(oid: oid, number: number, schema: schema, table: table, name: name, type: type,
                             notNull: row[6] == "true" || row[6] == "t", generated: Self.charValue(row[7]),
                             identity: Self.charValue(row[8]), kind: Self.charValue(row[9]), typeKind: Self.charValue(row[10]))
        }
        let tables = Set(all.map { "\($0.schema).\($0.table)" })
        guard tables.count == 1, let first = all.first else {
            return .readOnly(tables.count > 1
                ? "Columns come from several tables (\(tables.sorted().joined(separator: ", "))). Edit one table at a time."
                : "The source table could not be found.")
        }
        guard ["r", "p"].contains(first.kind) else {
            return .readOnly("\(first.table) is not an ordinary table (relkind \(first.kind)).")
        }
        let byNumber = Dictionary(uniqueKeysWithValues: all.map { ($0.number, $0) })
        var seen = Set<Int16>()
        for source in sources where !seen.insert(source.attribute).inserted {
            return .readOnly("\(byNumber[source.attribute]?.name ?? "A column") appears more than once in the result.")
        }
        let indexes = try await postgresQuery("""
        SELECT i.indisprimary, i.indisunique, i.indisvalid, i.indpred IS NOT NULL, i.indnkeyatts, i.indkey::text
        FROM pg_index i WHERE i.indrelid = \(first.oid) ORDER BY i.indisprimary DESC, i.indexrelid
        """)
        let present = Set(sources.map(\.attribute))
        var keyNumbers: [Int16]?
        for row in indexes.rows where row.count >= 6 {
            let primary = row[0] == "true" || row[0] == "t", unique = row[1] == "true" || row[1] == "t"
            let valid = row[2] == "true" || row[2] == "t", partial = row[3] == "true" || row[3] == "t"
            guard primary || (unique && valid && !partial), let count = Int(row[4] ?? "") else { continue }
            let numbers = (row[5] ?? "").split(separator: " ").prefix(count).compactMap { Int16($0) }
            // An expression column is attribute 0: the index is not a plain key.
            guard numbers.count == count, !numbers.contains(0), numbers.allSatisfy({ byNumber[$0]?.notNull == true }),
                  numbers.allSatisfy(present.contains) else { continue }
            keyNumbers = numbers
            break
        }
        guard let keyNumbers else {
            return .readOnly("The result does not include every column of a primary key or a NOT NULL unique key of \(first.table).")
        }
        var resolved: [SQLEditTarget.Column] = []
        for (index, column) in columns.enumerated() {
            guard let source = column.postgresSource, let attribute = byNumber[source.attribute] else { continue }
            let isKey = keyNumbers.contains(source.attribute)
            var reason: String?
            if isKey {
                reason = "\(attribute.name) identifies the row."
            } else if !attribute.generated.isEmpty {
                reason = "\(attribute.name) is a generated column."
            } else if attribute.identity == "a" {
                reason = "\(attribute.name) is GENERATED ALWAYS."
            } else if attribute.typeKind != "e" {
                let base = Self.baseTypeName(attribute.type)
                if !Self.postgresEditableTypes.contains(base) {
                    reason = "\(attribute.name) has type \(attribute.type), which is not editable here yet."
                }
            }
            resolved.append(.init(resultIndex: index, name: attribute.name, typeName: attribute.type, isKey: isKey,
                                  isRequired: attribute.notNull, readOnlyReason: reason))
        }
        let keys = keyNumbers.compactMap { number in resolved.first { $0.name == byNumber[number]?.name } }
        return .editable(SQLEditTarget(engine: .postgres, schema: first.schema, table: first.table, keys: keys, columns: resolved))
    }

    /// PostgreSQL's single-character `"char"` columns hold a NUL byte when unset.
    nonisolated static func charValue(_ value: String?) -> String {
        (value ?? "").replacingOccurrences(of: "\0", with: "")
    }

    nonisolated static func baseTypeName(_ type: String) -> String {
        type.replacingOccurrences(of: #"\(.*?\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: MySQL

    private static let mysqlEditableTypes: Set<String> = [
        "tinyint", "smallint", "mediumint", "int", "bigint", "decimal", "char", "varchar", "tinytext", "text",
        "mediumtext", "longtext", "date", "time", "datetime", "timestamp", "enum",
    ]

    private func resolveMySQL(_ columns: [ResultColumn]) async throws -> SQLEditResolution {
        let origins = columns.compactMap(\.origin)
        guard !origins.isEmpty else { return .readOnly("The result has no columns that come from a table.") }
        let tables = Set(origins.map { "\($0.schema ?? "").\($0.table)" })
        guard tables.count == 1, let origin = origins.first, let schema = origin.schema, !schema.isEmpty else {
            return .readOnly(tables.count > 1
                ? "Columns come from several tables (\(tables.sorted().joined(separator: ", "))). Edit one table at a time."
                : "The server did not report the source database.")
        }
        var seen = Set<String>()
        for column in origins where !seen.insert(column.column).inserted {
            return .readOnly("\(column.column) appears more than once in the result.")
        }
        let info = try await mysqlQuery("""
        SELECT c.COLUMN_NAME, c.DATA_TYPE, c.IS_NULLABLE, c.EXTRA, t.TABLE_TYPE
        FROM information_schema.COLUMNS c
        JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
        WHERE c.TABLE_SCHEMA = \(literal(schema)) AND c.TABLE_NAME = \(literal(origin.table))
        """)
        struct Attribute { let name: String, type: String, nullable: Bool, extra: String }
        let attributes: [String: Attribute] = Dictionary(info.rows.compactMap { row -> (String, Attribute)? in
            guard row.count >= 5, let name = row[0], let type = row[1] else { return nil }
            return (name, Attribute(name: name, type: type.lowercased(), nullable: row[2] == "YES", extra: (row[3] ?? "").lowercased()))
        }, uniquingKeysWith: { first, _ in first })
        guard !attributes.isEmpty else { return .readOnly("The source table could not be found.") }
        guard info.rows.first?[4] == "BASE TABLE" else { return .readOnly("\(origin.table) is a view, not a table.") }
        let statistics = try await mysqlQuery("""
        SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, NULLABLE, SUB_PART
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = \(literal(schema)) AND TABLE_NAME = \(literal(origin.table))
        ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX
        """)
        var indexes: [(name: String, unique: Bool, columns: [(name: String, nullable: Bool, partial: Bool)])] = []
        for row in statistics.rows where row.count >= 6 {
            guard let name = row[0], let column = row[3] else { continue }
            let entry = (name: column, nullable: !(row[4] ?? "").isEmpty, partial: row[5] != nil)
            if let last = indexes.indices.last, indexes[last].name == name {
                indexes[last].columns.append(entry)
            } else {
                indexes.append((name: name, unique: row[1] == "0", columns: [entry]))
            }
        }
        let present = Set(origins.map(\.column))
        guard let key = indexes.first(where: { index in
            index.unique && index.columns.allSatisfy { !$0.nullable && !$0.partial && present.contains($0.name) }
        }) else {
            return .readOnly("The result does not include every column of a primary key or a NOT NULL unique key of \(origin.table).")
        }
        let keyNames = Set(key.columns.map(\.name))
        var resolved: [SQLEditTarget.Column] = []
        for (index, column) in columns.enumerated() {
            guard let origin = column.origin, let attribute = attributes[origin.column] else { continue }
            let isKey = keyNames.contains(attribute.name)
            var reason: String?
            if isKey {
                reason = "\(attribute.name) identifies the row."
            } else if attribute.extra.contains("generated") {
                reason = "\(attribute.name) is a generated column."
            } else if !Self.mysqlEditableTypes.contains(attribute.type) {
                reason = "\(attribute.name) has type \(attribute.type), which is not editable here yet."
            }
            resolved.append(.init(resultIndex: index, name: attribute.name, typeName: attribute.type, isKey: isKey,
                                  isRequired: !attribute.nullable, readOnlyReason: reason))
        }
        let keys = key.columns.compactMap { part in resolved.first { $0.name == part.name } }
        return .editable(SQLEditTarget(engine: .mysql, schema: schema, table: origin.table, keys: keys, columns: resolved))
    }

    // MARK: Reading one large value

    /// Reads one column of the row a verified key names, with the display bound lifted, so the
    /// inspector can show what the grid only previews. The row is found by key, never by position:
    /// if it changed or is gone this throws rather than answering with another row's value.
    public func fetchFullValue(
        column: String, keys: [SQLiteOptimisticUpdate.Key], target: SQLEditTarget
    ) async throws -> DatabaseValue {
        let statement = try SQLEditStatements.value(column: column, keys: keys, target: target)
        return try await readOneValue(statement.sql, statement.parameters)
    }

    /// The same for an SQLite table.
    public func fetchFullSQLiteValue(
        table: String, column: String, keys: [SQLiteOptimisticUpdate.Key]
    ) async throws -> DatabaseValue {
        guard engine == .sqlite, !keys.isEmpty, keys.allSatisfy({ !$0.value.isNull }) else {
            throw DatabaseError.executionFailed("The row needs a complete key.")
        }
        let sql = try "SELECT " + SQLIdentifiers.quote(column, engine: .sqlite) + " FROM main."
            + SQLIdentifiers.quote(table, engine: .sqlite) + " WHERE " + SQLiteOptimisticUpdate.keyLookup(keys) + " LIMIT 2"
        return try await readOneValue(sql, keys.map(\.value))
    }

    private func readOneValue(_ sql: String, _ parameters: [DatabaseValue]) async throws -> DatabaseValue {
        let store = ResultStore(columns: [], rowLimit: 2)
        defer { Task { await store.close() } }
        let limit = ValueLimits.fullValueLimit
        _ = try await ValueLimits.$override.withValue(ValueLimits(maxTextBytes: limit, binaryPrefix: limit)) {
            try await execute(sql, parameters: parameters, into: store)
        }
        let rows = try await store.rows(in: 0..<store.rowCount)
        guard rows.count == 1, let value = rows[0].first else {
            throw DatabaseError.executionFailed(rows.isEmpty
                ? "The row is no longer there." : "The key matched more than one row, so it does not identify a value.")
        }
        return value
    }

    // MARK: Applying

    /// Applies cell updates as one transaction, or under a savepoint inside the console's own.
    /// A row whose key or original values no longer match throws `SQLiteOptimisticConflict`; a
    /// refusal by the server throws `SQLiteMutationFailure`. Either way nothing is kept.
    @discardableResult
    public func applyUpdates(_ updates: [SQLiteOptimisticUpdate], target: SQLEditTarget) async throws -> SQLMutationResult {
        guard !readOnly else { throw DatabaseError.readOnlyViolation }
        guard target.engine == engine, engine == .postgres || engine == .mysql else {
            throw DatabaseError.executionFailed("This target belongs to another connection.")
        }
        guard !updates.isEmpty, updates.count <= 500 else {
            throw DatabaseError.executionFailed("Submit between 1 and 500 changed rows.")
        }
        let statements = try updates.map { try SQLEditStatements.update($0, target: target) }
        let nested = await transactionState().isOpen
        let savepoint = "umbra_submit"
        func control(_ sql: String) async throws {
            let store = ResultStore(columns: [])
            defer { Task { await store.close() } }
            _ = try await execute(sql, parameters: [], into: store)
        }
        if nested { try await control("SAVEPOINT \(savepoint)") } else { try await beginTransaction() }
        var result = SQLMutationResult(rowsAffected: 0, leftTransactionOpen: nested, insertedRowIDs: [:])
        do {
            for (index, statement) in statements.enumerated() {
                try Task.checkCancellation()
                let store = ResultStore(columns: [])
                let summary: ExecutionSummary
                do {
                    summary = try await execute(statement.sql, parameters: statement.parameters, into: store)
                } catch let error as DatabaseServerError {
                    await store.close()
                    throw SQLiteMutationFailure(index: index, message: error.localizedDescription, code: error.code)
                }
                await store.close()
                guard summary.affectedRows == 1 else {
                    let query = try SQLEditStatements.current(updates[index], target: target)
                    let current = try await self.query(query.sql, parameters: query.parameters)
                    let row = current.rows.count == 1 ? current.rows[0] : nil
                    throw SQLiteOptimisticConflict(updateIndex: index, current: row.map { Self.currentValues($0, updates[index]) })
                }
                result.rowsAffected += 1
            }
            try Task.checkCancellation()
            if nested { try await control("RELEASE SAVEPOINT \(savepoint)") } else { try await endTransaction(commit: true) }
        } catch {
            if nested {
                try? await control("ROLLBACK TO SAVEPOINT \(savepoint)")
                try? await control("RELEASE SAVEPOINT \(savepoint)")
            } else {
                try? await endTransaction(commit: false)
            }
            throw error
        }
        return result
    }

    /// `query` hands back display strings; a conflict view needs the values.
    private static func currentValues(_ row: [String?], _ update: SQLiteOptimisticUpdate) -> [DatabaseValue] {
        row.map { $0.map(DatabaseValue.text) ?? .null }
    }
}

/// Guarded UPDATE statements for the server engines: every key and every original value is
/// matched with a null-safe comparison, so a changed row matches nothing.
enum SQLEditStatements {
    static func update(_ update: SQLiteOptimisticUpdate, target: SQLEditTarget) throws -> (sql: String, parameters: [DatabaseValue]) {
        guard !update.keys.isEmpty, !update.changes.isEmpty,
              update.keys.count == target.keys.count,
              update.keys.allSatisfy({ key in target.keys.contains { $0.name == key.column } && !key.value.isNull }) else {
            throw DatabaseError.executionFailed("The row needs its complete key.")
        }
        var writer = Writer(engine: target.engine)
        let qualified = try qualifiedName(target)
        var assignments: [String] = []
        for change in update.changes {
            guard let column = target.column(named: change.column), column.readOnlyReason == nil,
                  case .value(let replacement) = change.replacement else {
                throw DatabaseError.executionFailed("\(change.column) cannot be edited.")
            }
            assignments.append(try quote(change.column, target.engine) + " = " + writer.operand(replacement, column: column))
        }
        var conditions: [String] = []
        for key in update.keys {
            let column = target.keys.first { $0.name == key.column }!
            conditions.append(try quote(key.column, target.engine) + " = " + writer.operand(key.value, column: column))
        }
        for change in update.changes {
            let column = target.column(named: change.column)!
            conditions.append(try writer.matches(change.column, change.original, column: column))
        }
        return ("UPDATE \(qualified)\nSET \(assignments.joined(separator: ", "))\nWHERE \(conditions.joined(separator: " AND "));",
                writer.parameters)
    }

    /// One column of the row a key names.
    static func value(column: String, keys: [SQLiteOptimisticUpdate.Key], target: SQLEditTarget) throws -> (sql: String, parameters: [DatabaseValue]) {
        guard target.column(named: column) != nil, !keys.isEmpty, keys.count == target.keys.count,
              keys.allSatisfy({ key in target.keys.contains { $0.name == key.column } && !key.value.isNull }) else {
            throw DatabaseError.executionFailed("The row needs its complete key.")
        }
        var writer = Writer(engine: target.engine)
        var conditions: [String] = []
        for key in keys {
            let keyColumn = target.keys.first { $0.name == key.column }!
            conditions.append(try quote(key.column, target.engine) + " = " + writer.operand(key.value, column: keyColumn))
        }
        return ("SELECT \(try quote(column, target.engine)) FROM \(try qualifiedName(target)) WHERE \(conditions.joined(separator: " AND ")) LIMIT 2",
                writer.parameters)
    }

    /// The row's current values for the changed columns, read by key.
    static func current(_ update: SQLiteOptimisticUpdate, target: SQLEditTarget) throws -> (sql: String, parameters: [DatabaseValue]) {
        var writer = Writer(engine: target.engine)
        let fields = try update.changes.map { try quote($0.column, target.engine) }.joined(separator: ", ")
        var conditions: [String] = []
        for key in update.keys {
            let column = target.keys.first { $0.name == key.column }!
            conditions.append(try quote(key.column, target.engine) + " = " + writer.operand(key.value, column: column))
        }
        return ("SELECT \(fields) FROM \(try qualifiedName(target)) WHERE \(conditions.joined(separator: " AND ")) LIMIT 2",
                writer.parameters)
    }

    private static func qualifiedName(_ target: SQLEditTarget) throws -> String {
        try quote(target.schema, target.engine) + "." + quote(target.table, target.engine)
    }

    private static func quote(_ name: String, _ engine: DatabaseEngine) throws -> String {
        try SQLIdentifiers.quote(name, engine: engine)
    }

    struct Writer {
        let engine: DatabaseEngine
        private(set) var parameters: [DatabaseValue] = []

        init(engine: DatabaseEngine) { self.engine = engine }

        /// A placeholder for `value`, cast to the column's type where the engine needs it.
        mutating func operand(_ value: DatabaseValue, column: SQLEditTarget.Column) -> String {
            let (parameter, cast) = convert(value, column: column)
            parameters.append(parameter)
            switch engine {
            case .postgres: return "$\(parameters.count)::\(column.typeName)"
            default: return cast ?? "?"
            }
        }

        mutating func appendPlain(_ value: DatabaseValue) { parameters.append(value) }

        mutating func matches(_ name: String, _ value: DatabaseValue, column: SQLEditTarget.Column) throws -> String {
            let field = try SQLIdentifiers.quote(name, engine: engine)
            let placeholder = operand(value, column: column)
            switch engine {
            case .postgres: return "\(field) IS NOT DISTINCT FROM \(placeholder)"
            default:
                // A case-insensitive collation would call 'A' and 'a' equal; compare the bytes.
                let textual = ["char", "varchar", "tinytext", "text", "mediumtext", "longtext", "enum"].contains(column.typeName)
                return textual && !value.isNull ? "BINARY \(field) <=> BINARY \(placeholder)" : "\(field) <=> \(placeholder)"
            }
        }

        private func convert(_ value: DatabaseValue, column: SQLEditTarget.Column) -> (DatabaseValue, String?) {
            switch value {
            case .null: return (.null, nil)
            case .bool, .int, .text, .double: return (value, nil)
            case .uint(let number):
                return (.text(String(number)), engine == .mysql ? "CAST(? AS UNSIGNED)" : nil)
            case .decimal(let text): return (.text(text), engine == .mysql ? "CAST(? AS DECIMAL(65,30))" : nil)
            case .uuid(let text): return (.text(text), nil)
            case .temporal(let text, let kind):
                let cast: String? = switch kind {
                case .date: "CAST(? AS DATE)"
                case .time, .timeWithZone: "CAST(? AS TIME(6))"
                default: "CAST(? AS DATETIME(6))"
                }
                return (.text(text), engine == .mysql ? cast : nil)
            default: return (.text(value.rawText ?? ""), nil)
            }
        }
    }
}

/// Binds values for a statement the app builds around a verified table: `$n` with a cast on
/// PostgreSQL, `?` with the casts MySQL needs for exact decimals and temporal values on MySQL.
/// SQLite binds plainly. Nothing is ever interpolated.
public struct SQLParameterWriter: Sendable {
    private var writer: SQLEditStatements.Writer

    public init(engine: DatabaseEngine) { writer = .init(engine: engine) }

    public var parameters: [DatabaseValue] { writer.parameters }

    /// The placeholder for `value`, typed as `typeName` where the engine needs it.
    public mutating func placeholder(_ value: DatabaseValue, typeName: String) -> String {
        if writer.engine == .sqlite {
            writer.appendPlain(value)
            return "?"
        }
        return writer.operand(value, column: .init(resultIndex: 0, name: "", typeName: typeName, isKey: false, isRequired: false))
    }

    /// Whether PostgreSQL can cast a bound parameter to this catalog type name.
    public static func canBind(typeName: String, engine: DatabaseEngine) -> Bool {
        engine != .postgres || SQLSession.postgresEditableTypes.contains(SQLSession.baseTypeName(typeName))
    }
}
