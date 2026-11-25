import DatabaseCore
import Foundation
import SQLite3

/// SQLite's column type affinity, from the declared type, by SQLite's own five rules
/// (https://www.sqlite.org/datatype3.html §3.1). It says what a column *prefers*, never what a
/// stored value *is*: any column can hold any storage class.
public enum SQLiteAffinity: String, Sendable, Equatable {
    case integer = "INTEGER", text = "TEXT", blob = "BLOB", real = "REAL", numeric = "NUMERIC"

    public init(declaredType: String) {
        let type = declaredType.uppercased()
        if type.contains("INT") { self = .integer }
        else if type.contains("CHAR") || type.contains("CLOB") || type.contains("TEXT") { self = .text }
        else if type.isEmpty || type.contains("BLOB") { self = .blob }
        else if type.contains("REAL") || type.contains("FLOA") || type.contains("DOUB") { self = .real }
        else { self = .numeric }
    }
}

public struct SQLiteColumnInfo: Equatable, Sendable {
    public var name: String
    public var declaredType: String
    public var affinity: SQLiteAffinity
    public var isNotNull: Bool
    public var defaultValue: String?
    /// 1-based position in the primary key, or 0 when not part of it.
    public var primaryKeyPosition: Int
    /// 0 normal, 1 hidden (virtual table), 2 generated virtual, 3 generated stored.
    public var hidden: Int
    public var isGenerated: Bool { hidden == 2 || hidden == 3 }
    public var isHidden: Bool { hidden == 1 }
}

public struct SQLiteForeignKeyInfo: Equatable, Sendable {
    public var id: Int
    public var table: String
    /// Columns of this table, in key order. More than one for a composite key.
    public var from: [String]
    /// Referenced columns; nil entries mean "the parent's primary key".
    public var to: [String?]
    public var onUpdate: String
    public var onDelete: String
}

public struct SQLiteIndexInfo: Equatable, Sendable {
    public var name: String
    public var isUnique: Bool
    /// `c` created by CREATE INDEX, `u` by a UNIQUE constraint, `pk` by the primary key.
    public var origin: String
    public var isPartial: Bool
    /// Key columns; a nil entry is an expression.
    public var columns: [String?]
}

public struct SQLiteTableInfo: Equatable, Sendable {
    public enum Kind: String, Sendable { case table, view, virtual, shadow }
    public var schema: String
    public var name: String
    public var kind: Kind
    public var isStrict: Bool
    public var withoutRowID: Bool
    public var columns: [SQLiteColumnInfo]
    public var foreignKeys: [SQLiteForeignKeyInfo]
    public var indexes: [SQLiteIndexInfo]
    public var triggers: [String]
    public var sql: String?

    /// The primary key columns in key order.
    public var primaryKey: [String] {
        columns.filter { $0.primaryKeyPosition > 0 }.sorted { $0.primaryKeyPosition < $1.primaryKeyPosition }.map(\.name)
    }

    /// A row of an ordinary rowid table can always be addressed by `rowid`; a `WITHOUT ROWID`
    /// table, a view or a virtual table cannot.
    public var hasRowID: Bool { kind == .table && !withoutRowID }
}

public struct SQLiteObjectInfo: Equatable, Sendable {
    public var schema: String
    /// `table`, `view`, `index` or `trigger`.
    public var type: String
    public var name: String
    public var tableName: String
    public var sql: String?
}

public struct SQLiteSizeInfo: Equatable, Sendable {
    public var pageSize: Int
    public var pageCount: Int
    public var freePages: Int
    public var fileBytes: Int64?
    public var walBytes: Int64?
    public var logicalBytes: Int64 { Int64(pageSize) * Int64(pageCount) }
    public var reclaimableBytes: Int64 { Int64(pageSize) * Int64(freePages) }
}

public struct SQLiteForeignKeyViolation: Equatable, Sendable {
    public var table: String
    public var rowID: Int64?
    public var parent: String
    public var keyIndex: Int
}

public enum SQLiteCheckpointMode: Int32, Sendable {
    case passive, full, restart, truncate
}

public struct SQLiteCheckpointResult: Equatable, Sendable {
    /// The checkpoint could not complete because a reader or writer was in the way.
    public var wasBlocked: Bool
    public var logFrames: Int
    public var checkpointedFrames: Int
}

extension SQLiteSession {
    // MARK: - Introspection

    private static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// `main`, `temp` and every attached database.
    public func schemas() async throws -> [String] {
        try await run("PRAGMA database_list", parameters: []).compactMap { $0.count > 1 ? $0[1].rawText : nil }
    }

    /// Tables, views, virtual tables and shadow tables of a schema, without SQLite's own
    /// `sqlite_*` bookkeeping tables unless asked.
    public func tableNames(schema: String = "main", includeInternal: Bool = false) async throws -> [(name: String, kind: SQLiteTableInfo.Kind)] {
        let rows = try await run("SELECT name, type FROM pragma_table_list WHERE schema = ?1 ORDER BY name", parameters: [.text(schema)])
        return rows.compactMap { row in
            guard let name = row[0].rawText, let type = row[1].rawText else { return nil }
            if !includeInternal, name.hasPrefix("sqlite_") { return nil }
            return (name, SQLiteTableInfo.Kind(rawValue: type) ?? .table)
        }
    }

    public func objects(schema: String = "main") async throws -> [SQLiteObjectInfo] {
        let table = schema.lowercased() == "temp" ? "sqlite_temp_schema" : "\(Self.quote(schema)).sqlite_schema"
        let rows = try await run("SELECT type, name, tbl_name, sql FROM \(table) ORDER BY type, name", parameters: [])
        return rows.compactMap { row in
            guard let type = row[0].rawText, let name = row[1].rawText, let tableName = row[2].rawText else { return nil }
            return SQLiteObjectInfo(schema: schema, type: type, name: name, tableName: tableName, sql: row[3].rawText)
        }
    }

    public func tableInfo(schema: String = "main", table: String) async throws -> SQLiteTableInfo {
        let listing = try await run(
            "SELECT type, wr, strict FROM pragma_table_list WHERE schema = ?1 AND name = ?2",
            parameters: [.text(schema), .text(table)]
        )
        guard let entry = listing.first else {
            throw DatabaseServerError(message: "There is no table or view \"\(table)\" in \(schema).", code: "SQLITE_ERROR")
        }
        let kind = SQLiteTableInfo.Kind(rawValue: entry[0].rawText ?? "table") ?? .table
        let withoutRowID = entry[1].rawText == "1"
        let strict = entry[2].rawText == "1"

        let columnRows = try await run(
            "SELECT name, type, \"notnull\", dflt_value, pk, hidden FROM pragma_table_xinfo(?1, ?2) ORDER BY cid",
            parameters: [.text(table), .text(schema)]
        )
        let columns = columnRows.map { row in
            SQLiteColumnInfo(
                name: row[0].rawText ?? "", declaredType: row[1].rawText ?? "",
                affinity: SQLiteAffinity(declaredType: row[1].rawText ?? ""),
                isNotNull: row[2].rawText == "1", defaultValue: row[3].rawText,
                primaryKeyPosition: Int(row[4].rawText ?? "") ?? 0, hidden: Int(row[5].rawText ?? "") ?? 0
            )
        }

        // Composite keys arrive as several rows with the same id, in `seq` order.
        let keyRows = try await run(
            "SELECT id, seq, \"table\", \"from\", \"to\", on_update, on_delete FROM pragma_foreign_key_list(?1, ?2) ORDER BY id, seq",
            parameters: [.text(table), .text(schema)]
        )
        var foreignKeys: [SQLiteForeignKeyInfo] = []
        for row in keyRows {
            let id = Int(row[0].rawText ?? "") ?? 0
            if let index = foreignKeys.firstIndex(where: { $0.id == id }) {
                foreignKeys[index].from.append(row[3].rawText ?? "")
                foreignKeys[index].to.append(row[4].rawText)
            } else {
                foreignKeys.append(SQLiteForeignKeyInfo(
                    id: id, table: row[2].rawText ?? "", from: [row[3].rawText ?? ""], to: [row[4].rawText],
                    onUpdate: row[5].rawText ?? "NO ACTION", onDelete: row[6].rawText ?? "NO ACTION"
                ))
            }
        }

        let indexRows = try await run(
            "SELECT name, \"unique\", origin, partial FROM pragma_index_list(?1, ?2) ORDER BY seq",
            parameters: [.text(table), .text(schema)]
        )
        var indexes: [SQLiteIndexInfo] = []
        for row in indexRows {
            let name = row[0].rawText ?? ""
            let keyColumns = try await run(
                "SELECT name FROM pragma_index_xinfo(?1, ?2) WHERE key = 1 ORDER BY seqno",
                parameters: [.text(name), .text(schema)]
            )
            indexes.append(SQLiteIndexInfo(
                name: name, isUnique: row[1].rawText == "1", origin: row[2].rawText ?? "c",
                isPartial: row[3].rawText == "1", columns: keyColumns.map { $0[0].rawText }
            ))
        }

        let schemaObjects = try await objects(schema: schema)
        return SQLiteTableInfo(
            schema: schema, name: table, kind: kind, isStrict: strict, withoutRowID: withoutRowID,
            columns: columns, foreignKeys: foreignKeys, indexes: indexes,
            triggers: schemaObjects.filter { $0.type == "trigger" && $0.tableName == table }.map(\.name),
            sql: schemaObjects.first { ($0.type == "table" || $0.type == "view") && $0.name == table }?.sql
        )
    }

    // MARK: - Maintenance (always an explicit call; never run on open)

    public func pragma(_ name: String) async throws -> String? {
        guard name.allSatisfy({ $0.isLetter || $0 == "_" }) else {
            throw DatabaseError.invalidIdentifier(name)
        }
        return try await run("PRAGMA \(name)", parameters: []).first?.first?.rawText
    }

    public func journalMode() async throws -> String {
        try await pragma("journal_mode") ?? "unknown"
    }

    public func sizeInfo() async throws -> SQLiteSizeInfo {
        func number(_ name: String) async throws -> Int { Int(try await pragma(name) ?? "") ?? 0 }
        var info = SQLiteSizeInfo(
            pageSize: try await number("page_size"), pageCount: try await number("page_count"),
            freePages: try await number("freelist_count")
        )
        if case .file(let path) = options.location {
            let manager = FileManager.default
            info.fileBytes = (try? manager.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
            info.walBytes = (try? manager.attributesOfItem(atPath: path + "-wal")[.size] as? Int64) ?? nil
        }
        return info
    }

    /// `PRAGMA integrity_check`. A healthy database returns exactly `["ok"]`. Reads the whole
    /// file, so it can take a while on a large database; the caller asks for it.
    public func integrityCheck(limit: Int = 100) async throws -> [String] {
        try await run("PRAGMA integrity_check(\(max(1, limit)))", parameters: []).compactMap { $0.first?.rawText }
    }

    public func quickCheck(limit: Int = 100) async throws -> [String] {
        try await run("PRAGMA quick_check(\(max(1, limit)))", parameters: []).compactMap { $0.first?.rawText }
    }

    /// Rows that break a foreign key. Empty means every key holds.
    public func foreignKeyCheck() async throws -> [SQLiteForeignKeyViolation] {
        try await run("PRAGMA foreign_key_check", parameters: []).map { row in
            SQLiteForeignKeyViolation(
                table: row[0].rawText ?? "", rowID: row[1].rawText.flatMap(Int64.init),
                parent: row[2].rawText ?? "", keyIndex: Int(row[3].rawText ?? "") ?? 0
            )
        }
    }

    public func analyze() async throws { try await maintenance("ANALYZE") }
    public func optimize() async throws { try await maintenance("PRAGMA optimize") }

    /// Rebuilds the file to reclaim free pages. Needs room for a second copy and fails inside a
    /// transaction; it rewrites the whole database.
    public func vacuum() async throws { try await maintenance("VACUUM") }

    /// Writes a vacuumed copy to a new file and leaves this database untouched.
    public func vacuum(into path: String) async throws {
        guard !FileManager.default.fileExists(atPath: path) else { throw SQLiteSession.OpenError.alreadyExists(path) }
        _ = try await run("VACUUM INTO ?1", parameters: [.text(path)])
    }

    private func maintenance(_ statement: String) async throws {
        guard !readOnly else { throw DatabaseError.readOnlyViolation }
        _ = try await run(statement, parameters: [])
    }

    public func walCheckpoint(_ mode: SQLiteCheckpointMode = .passive) async throws -> SQLiteCheckpointResult {
        guard !readOnly else { throw DatabaseError.readOnlyViolation }
        guard let db = rawHandle else { throw DatabaseError.notConnected }
        var logFrames: Int32 = 0, checkpointed: Int32 = 0
        let code = sqlite3_wal_checkpoint_v2(db, "main", mode.rawValue, &logFrames, &checkpointed)
        switch code {
        case SQLITE_OK:
            return SQLiteCheckpointResult(wasBlocked: false, logFrames: Int(logFrames), checkpointedFrames: Int(checkpointed))
        case SQLITE_BUSY:
            return SQLiteCheckpointResult(wasBlocked: true, logFrames: Int(logFrames), checkpointedFrames: Int(checkpointed))
        default:
            throw DatabaseServerError(message: String(cString: sqlite3_errmsg(db)), code: "SQLITE_\(code)")
        }
    }

    // MARK: - Backup and attached databases

    /// Copies the database to a new file with SQLite's online backup API, which is consistent
    /// even while the database is in WAL mode or being written (copying the file is not). It
    /// refuses to overwrite an existing file. `progress` receives 0...1 between steps.
    public func backup(to path: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let source = rawHandle else { throw DatabaseError.notConnected }
        guard !FileManager.default.fileExists(atPath: path) else { throw SQLiteSession.OpenError.alreadyExists(path) }
        var destination: OpaquePointer?
        guard sqlite3_open_v2(path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let destination else {
            if let destination { sqlite3_close_v2(destination) }
            throw SQLiteSession.OpenError.notReadable(path)
        }
        defer { sqlite3_close_v2(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            try? FileManager.default.removeItem(atPath: path)
            throw DatabaseServerError(message: String(cString: sqlite3_errmsg(destination)), code: "SQLITE_ERROR")
        }
        var finished = false
        defer {
            sqlite3_backup_finish(backup)
            // A cancelled or failed backup must not leave a partial file that looks like one.
            if !finished { try? FileManager.default.removeItem(atPath: path) }
        }
        while true {
            let code = sqlite3_backup_step(backup, 256)
            let total = Double(sqlite3_backup_pagecount(backup))
            if total > 0 { progress?(1 - Double(sqlite3_backup_remaining(backup)) / total) }
            if code == SQLITE_DONE { finished = true; return }
            if code == SQLITE_BUSY || code == SQLITE_LOCKED {
                try await Task.sleep(for: .milliseconds(50))
            } else if code != SQLITE_OK {
                throw DatabaseServerError(message: String(cString: sqlite3_errmsg(destination)), code: "SQLITE_\(code)")
            }
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    /// Attaches another database file under `alias`. A read-only attach opens it `mode=ro`.
    public func attach(path: String, alias: String, readOnly attachReadOnly: Bool = false) async throws {
        guard alias.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw DatabaseError.invalidIdentifier(alias)
        }
        try SQLiteSession.validate(path: path)
        let location: String
        if attachReadOnly || readOnly {
            guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                throw DatabaseError.invalidIdentifier(path)
            }
            location = "file:\(encoded)?mode=ro"
        } else {
            location = path
        }
        _ = try await run("ATTACH DATABASE ?1 AS \(Self.quote(alias))", parameters: [.text(location)])
    }

    public func detach(alias: String) async throws {
        _ = try await run("DETACH DATABASE \(Self.quote(alias))", parameters: [])
    }
}

extension SQLiteSession {
    /// Every table's and view's columns in one query, for completion and the explorer. Hidden
    /// virtual-table columns are left out; generated columns are kept.
    public func allColumns(schema: String = "main") async throws -> [String: [SQLiteColumnInfo]] {
        let rows = try await run(
            """
            SELECT m.name, p.name, p.type, p."notnull", p.dflt_value, p.pk, p.hidden
            FROM pragma_table_list AS m, pragma_table_xinfo(m.name, m.schema) AS p
            WHERE m.schema = ?1 AND m.name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND m.type IN ('table', 'view', 'virtual')
            ORDER BY m.name, p.cid
            """,
            parameters: [.text(schema)], limit: 2_000_000
        )
        var grouped: [String: [SQLiteColumnInfo]] = [:]
        for row in rows {
            guard let table = row[0].rawText else { continue }
            let hidden = Int(row[6].rawText ?? "") ?? 0
            if hidden == 1 { continue }
            let declared = row[2].rawText ?? ""
            grouped[table, default: []].append(SQLiteColumnInfo(
                name: row[1].rawText ?? "", declaredType: declared, affinity: SQLiteAffinity(declaredType: declared),
                isNotNull: row[3].rawText == "1", defaultValue: row[4].rawText,
                primaryKeyPosition: Int(row[5].rawText ?? "") ?? 0, hidden: hidden
            ))
        }
        return grouped
    }

    /// Every foreign key of every table, one entry per constraint (composite keys stay together).
    /// A key that names no parent column refers to the parent's primary key; that is resolved here.
    public func allForeignKeys(schema: String = "main") async throws -> [(table: String, key: SQLiteForeignKeyInfo)] {
        let rows = try await run(
            """
            SELECT m.name, f.id, f.seq, f."table", f."from", f."to", f.on_update, f.on_delete
            FROM pragma_table_list AS m, pragma_foreign_key_list(m.name, m.schema) AS f
            WHERE m.schema = ?1 AND m.type = 'table'
            ORDER BY m.name, f.id, f.seq
            """,
            parameters: [.text(schema)], limit: 1_000_000
        )
        var result: [(table: String, key: SQLiteForeignKeyInfo)] = []
        for row in rows {
            guard let table = row[0].rawText else { continue }
            let id = Int(row[1].rawText ?? "") ?? 0
            if let index = result.firstIndex(where: { $0.table == table && $0.key.id == id }) {
                result[index].key.from.append(row[4].rawText ?? "")
                result[index].key.to.append(row[5].rawText)
            } else {
                result.append((table, SQLiteForeignKeyInfo(
                    id: id, table: row[3].rawText ?? "", from: [row[4].rawText ?? ""], to: [row[5].rawText],
                    onUpdate: row[6].rawText ?? "NO ACTION", onDelete: row[7].rawText ?? "NO ACTION"
                )))
            }
        }
        guard result.contains(where: { $0.key.to.contains(where: { $0 == nil }) }) else { return result }
        let columns = try await allColumns(schema: schema)
        for index in result.indices {
            let primary = (columns[result[index].key.table] ?? [])
                .filter { $0.primaryKeyPosition > 0 }.sorted { $0.primaryKeyPosition < $1.primaryKeyPosition }.map(\.name)
            result[index].key.to = result[index].key.to.enumerated().map { $0.element ?? (primary.indices.contains($0.offset) ? primary[$0.offset] : nil) }
        }
        return result
    }
}
