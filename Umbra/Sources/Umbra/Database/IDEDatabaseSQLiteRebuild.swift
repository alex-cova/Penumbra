import DatabaseKit
import Foundation

/// A preview constructed from a consistent snapshot of main.sqlite_schema.
struct IDEDatabaseSQLiteRebuild: Sendable {
    let schemaVersion: Int
    let original: SQLiteTableInfo
    let definitions: [String]
    let tableDefinition: String
    let body: String
    let suffix: String
    let copyColumns: [String]

    static func load(_ table: String, from session: SQLiteSession) async throws -> Self {
        let version = try await session.pragma("schema_version")
        let info = try await session.tableInfo(table: table)
        let objects = try await session.objects()
        var limitations: [String] = []
        guard info.kind == .table, let sql = info.sql else {
            throw DatabaseError.executionFailed("Only ordinary SQLite tables in main can be rebuilt.")
        }
        let source = sql as NSString
        let tokens = SQLLexer(sql, dialect: .sqlite).tokenize()
        if tokens.contains(where: { $0.kind == .word && source.substring(with: $0.range).uppercased() == "AUTOINCREMENT" }) {
            limitations.append("the AUTOINCREMENT sequence")
        }
        let dependents = objects.filter {
            ($0.type == "view" || ($0.type == "trigger" && $0.tableName != table))
                && $0.sql.map { mentions(table, in: $0) } == true
        }
        limitations += dependents.map { "\($0.type) \($0.name)" }
        let incoming = try await session.allForeignKeys().filter {
            $0.key.table.caseInsensitiveCompare(table) == .orderedSame
        }
        for name in Set(incoming.map(\.table)).sorted() {
            limitations.append("incoming foreign keys from \(name)")
        }
        let columns = info.columns.filter { $0.hidden == 0 }
        var copyNames = columns.map(\.name)
        let aliasesRowID = columns.contains {
            $0.primaryKeyPosition == 1 && $0.declaredType.uppercased() == "INTEGER"
        } && !info.indexes.contains { $0.origin == "pk" }
        if info.hasRowID && !aliasesRowID {
            let declared = Set(copyNames.map { $0.lowercased() })
            if let alias = ["rowid", "_rowid_", "oid"].first(where: { !declared.contains($0) }) {
                copyNames.insert(alias, at: 0)
            } else {
                limitations.append("the hidden row identifier")
            }
        }
        let owned = objects.filter { $0.tableName == table && ($0.type == "index" || $0.type == "trigger") }
        let definitions = owned.compactMap(\.sql)
        let expected = info.indexes.filter { $0.origin == "c" }.count + info.triggers.count
        if definitions.count != expected { limitations.append("one or more index or trigger definitions") }
        guard limitations.isEmpty else {
            throw DatabaseError.executionFailed("This rebuild cannot preserve \(limitations.joined(separator: ", ")).")
        }
        guard let version, let schemaVersion = Int(version), try await session.pragma("schema_version") == version else {
            throw DatabaseError.executionFailed("The SQLite schema changed while it was being read. Open the preview again.")
        }
        let parentheses = tokens.filter { $0.kind == .symbol }
        guard let open = parentheses.first(where: { source.substring(with: $0.range) == "(" }),
              let close = parentheses.last(where: { source.substring(with: $0.range) == ")" }), open.end < close.start else {
            throw DatabaseError.executionFailed("The original CREATE TABLE statement could not be read.")
        }
        return Self(schemaVersion: schemaVersion, original: info, definitions: definitions,
                    tableDefinition: sql,
                    body: source.substring(with: NSRange(location: open.end, length: close.start - open.end)),
                    suffix: source.substring(from: close.end), copyColumns: copyNames)
    }

    func statement(adding constraint: String, nonce: UUID) throws -> String {
        let tag = nonce.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let guardName = "_umbra_guard_\(tag)"
        let replacement = "_umbra_rebuild_\(tag)"
        let name = try SQLIdentifiers.quote(original.name, engine: .sqlite)
        let originalName = original.name.replacing("'", with: "''")
        let originalDefinition = tableDefinition.replacing("'", with: "''")
        let columns = try copyColumns.map { try SQLIdentifiers.quote($0, engine: .sqlite) }.joined(separator: ", ")
        let restored = definitions.map { $0.hasSuffix(";") ? $0 : $0 + ";" }.joined(separator: "\n")
        return """
        BEGIN IMMEDIATE;
        CREATE TEMP TABLE \(guardName) (ok INTEGER NOT NULL CHECK (ok = 1));
        INSERT OR ROLLBACK INTO temp.\(guardName)
        SELECT schema_version = \(schemaVersion)
           AND EXISTS (SELECT 1 FROM main.sqlite_schema
                       WHERE type = 'table' AND name = '\(originalName)' AND sql = '\(originalDefinition)')
           AND NOT EXISTS (SELECT 1 FROM temp.sqlite_schema WHERE name <> '\(guardName)')
        FROM pragma_schema_version;
        CREATE TABLE main.\(replacement) (
        \(body),
        \(constraint)
        )\(suffix);
        INSERT OR ROLLBACK INTO main.\(replacement) (\(columns))
        SELECT \(columns) FROM main.\(name);
        INSERT OR ROLLBACK INTO temp.\(guardName)
        SELECT 0 FROM pragma_foreign_key_check('\(replacement)', 'main') LIMIT 1;
        DROP TABLE main.\(name);
        ALTER TABLE main.\(replacement) RENAME TO \(name);
        \(restored)
        DROP TABLE temp.\(guardName);
        COMMIT;
        """
    }

    private static func mentions(_ table: String, in sql: String) -> Bool {
        let source = sql as NSString
        return SQLLexer(sql, dialect: .sqlite).tokenize().contains { token in
            guard token.kind == .word || token.kind == .quotedIdentifier || token.kind == .string else { return false }
            let raw = source.substring(with: token.range)
            let name: String
            if token.kind == .word {
                name = raw
            } else if token.isTerminated, let delimiter = raw.first, raw.count >= 2 {
                name = raw.dropFirst().dropLast().replacingOccurrences(of: "\(delimiter)\(delimiter)", with: String(delimiter))
            } else {
                return false
            }
            return name.caseInsensitiveCompare(table) == .orderedSame
        }
    }
}
