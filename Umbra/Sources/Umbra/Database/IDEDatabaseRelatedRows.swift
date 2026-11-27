import AppKit
import DatabaseKit
import SwiftUI

struct IDEDatabaseResultQuery: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let sql: String
    let parameters: [DatabaseValue]
    let engine: DatabaseEngine
    let binding: IDEDatabaseConsoleBinding
    let scopeRevision: UUID?

    static func make(
        table: String, column: String, values: [String: DatabaseValue], keys: [SQLCatalog.ForeignKey],
        binding: IDEDatabaseConsoleBinding, scopeRevision: UUID?
    ) throws -> [Self] {
        func quote(_ name: String) throws -> String { try SQLIdentifiers.quote(name, engine: .sqlite) }
        var queries: [Self] = []
        for key in keys where key.fromColumns.count == key.toColumns.count && !key.fromColumns.isEmpty {
            guard !(key.fromColumns + key.toColumns).contains(where: \.isEmpty) else { continue }
            for inbound in [false, true] {
                let own = inbound ? key.toColumns : key.fromColumns
                guard (inbound ? key.toRelation : key.fromRelation) == table, own.contains(column) else { continue }
                let parameters = own.compactMap { values[$0] }
                guard parameters.count == own.count,
                      parameters.allSatisfy({ !$0.isNull && SQLiteOptimisticUpdate.isEditableValue($0) }) else { continue }
                let parent = try quote(key.toRelation)
                let child = try quote(key.fromRelation)
                let primary = try key.toColumns.map(quote)
                let foreign = try key.fromColumns.map(quote)
                let whereClause = primary.map { "parent.\($0) = ?" }.joined(separator: " AND ")
                let sql: String
                if inbound {
                    let relationship = zip(primary, foreign).map { "parent.\($0) = child.\($1)" }.joined(separator: " AND ")
                    sql = "SELECT child.* FROM main.\(child) AS child\nWHERE EXISTS (\n    SELECT 1 FROM main.\(parent) AS parent\n    WHERE \(relationship) AND \(whereClause)\n)"
                } else {
                    sql = "SELECT parent.* FROM main.\(parent) AS parent\nWHERE \(whereClause)"
                }
                let target = inbound ? key.fromRelation : key.toRelation
                let fields = (inbound ? key.fromColumns : key.toColumns).joined(separator: ", ")
                let name = inbound ? "Rows in \(target) referencing this row" : "Referenced row in \(target)"
                // The result is rows of `target`, so the next hop starts from a verified table too.
                var next = binding
                next.sqliteBrowseTable = target
                queries.append(Self(title: "\(name) (\(fields))", sql: sql, parameters: parameters, engine: .sqlite,
                                    binding: next, scopeRevision: scopeRevision))
            }
        }
        return queries
    }

    /// The same two hops for PostgreSQL and MySQL: the row a foreign key points at, and the rows
    /// that point at this one. Values are bound (cast where the server needs it), identifiers are
    /// quoted, and a key whose column type cannot be bound safely is left out rather than guessed.
    static func make(
        engine: DatabaseEngine, schema: String, table: String, column: String, values: [String: DatabaseValue],
        keys: [SQLCatalog.ForeignKey], typeOf: (_ relation: String, _ column: String) -> String?,
        binding: IDEDatabaseConsoleBinding, scopeRevision: UUID?
    ) throws -> [Self] {
        var queries: [Self] = []
        for key in keys where key.fromColumns.count == key.toColumns.count && !key.fromColumns.isEmpty {
            for inbound in [false, true] {
                let own = inbound ? key.toColumns : key.fromColumns
                guard (inbound ? key.toRelation : key.fromRelation) == table, own.contains(column) else { continue }
                let parameters = own.compactMap { values[$0] }
                guard parameters.count == own.count, parameters.allSatisfy({ isBindable($0) }) else { continue }
                let target = inbound ? key.fromRelation : key.toRelation
                let targetColumns = inbound ? key.fromColumns : key.toColumns
                var writer = SQLParameterWriter(engine: engine)
                var conditions: [String] = []
                for (name, value) in zip(targetColumns, parameters) {
                    guard let type = typeOf(target, name), SQLParameterWriter.canBind(typeName: type, engine: engine) else {
                        conditions.removeAll()
                        break
                    }
                    conditions.append(try SQLIdentifiers.quote(name, engine: engine) + " = " + writer.placeholder(value, typeName: type))
                }
                guard conditions.count == targetColumns.count else { continue }
                let sql = "SELECT * FROM \(try SQLIdentifiers.quote(schema, engine: engine)).\(try SQLIdentifiers.quote(target, engine: engine))"
                    + "\nWHERE \(conditions.joined(separator: " AND "))"
                let name = inbound ? "Rows in \(target) referencing this row" : "Referenced row in \(target)"
                queries.append(Self(title: "\(name) (\(targetColumns.joined(separator: ", ")))", sql: sql,
                                    parameters: writer.parameters, engine: engine, binding: binding, scopeRevision: scopeRevision))
            }
        }
        return queries
    }

    private static func isBindable(_ value: DatabaseValue) -> Bool {
        switch value {
        case .int, .uint, .text, .decimal, .uuid, .bool: true
        case .temporal(_, let kind): kind != .interval
        default: false
        }
    }
}

extension IDEDatabaseResultQuery {
    /// The table named by an SQLite foreign-key hop this app generated (`SELECT parent.* FROM
    /// main."t" AS parent …`), so the result of a hop can itself be followed and edited.
    static func navigatedTable(in sql: String) -> String? {
        for qualifier in ["parent", "child"] {
            let prefix = "SELECT \(qualifier).* FROM main.\""
            guard sql.hasPrefix(prefix) else { continue }
            var name = ""
            var index = sql.index(sql.startIndex, offsetBy: prefix.count)
            while index < sql.endIndex {
                if sql[index] == "\"" {
                    let next = sql.index(after: index)
                    if next < sql.endIndex, sql[next] == "\"" {
                        name.append("\"")
                        index = sql.index(after: next)
                        continue
                    }
                    guard sql[next...].hasPrefix(" AS \(qualifier)") else { return nil }
                    return name.isEmpty ? nil : name
                }
                name.append(sql[index])
                index = sql.index(after: index)
            }
        }
        return nil
    }
}

struct IDEDatabaseRelatedRows: View {
    let load: () async throws -> [IDEDatabaseResultQuery]
    let run: (IDEDatabaseResultQuery) -> Void
    /// Runs the query in the console that holds the result, so Back and Forward can return to it.
    var follow: ((IDEDatabaseResultQuery) -> Void)?
    @State private var showsRelated = false
    @State private var queries: [IDEDatabaseResultQuery]?
    @State private var selected: IDEDatabaseResultQuery?
    @State private var error: String?

    var body: some View {
        Button("Related Rows…", systemImage: "arrow.triangle.branch") { showsRelated = true }
            .popover(isPresented: $showsRelated) {
                VStack(alignment: .leading, spacing: 10) {
                    if let selected {
                        Text(selected.title).font(.headline)
                        ScrollView {
                            Text(selected.sql)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 170)
                        Text("Bound values · " + selected.parameters.map { $0.displayText() ?? "NULL" }.joined(separator: ", "))
                            .font(.caption).lineLimit(3)
                        HStack {
                            Button("Back") { self.selected = nil }
                            Button("Copy SQL") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(selected.sql, forType: .string)
                            }
                            Spacer()
                            Button("Open in New Tab") {
                                showsRelated = false
                                run(selected)
                            }
                            if let follow {
                                Button("Follow Here") {
                                    showsRelated = false
                                    follow(selected)
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                    } else if let queries {
                        if queries.isEmpty {
                            Text("No declared relationship uses this cell’s available values.").foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(queries) { query in Button(query.title) { selected = query }.buttonStyle(.plain) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 210)
                        }
                    } else if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        ProgressView("Looking Up Foreign Keys").controlSize(.small)
                    }
                }
                .padding(12)
                .frame(width: 425)
                .task {
                    selected = nil
                    queries = nil
                    error = nil
                    do { queries = try await load() }
                    catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
            }
    }
}
