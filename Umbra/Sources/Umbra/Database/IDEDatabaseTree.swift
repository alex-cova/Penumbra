import DatabaseKit
import Foundation

/// The Database sidebar as a flat list of rows, so arrow keys can walk it like Gradle and Maven.
enum IDEDatabaseTree {
    enum Kind: Equatable {
        case group
        case connection(UUID)
        case placeholder(UUID)
        case schema(UUID)
        case table(UUID, String)
        case column(UUID, String, String)
        case mongoDatabase(UUID, String)
        case mongoCollection(UUID, String, String)
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All Objects", tables = "Tables", views = "Views", columns = "Columns", collections = "Collections"
        case favorites = "Favorites", recents = "Recent Objects"

        var id: Self { self }

        func includes(_ row: Row, favorites: Set<String>) -> Bool {
            switch (self, row.kind) {
            case (.all, .group), (.all, .placeholder): false
            case (.all, _), (.columns, .column), (.collections, .mongoCollection): true
            case (.tables, .table): !row.isView
            case (.views, .table): row.isView
            case (.favorites, _): favorites.contains(row.id)
            default: false
            }
        }
    }

    struct Row: Identifiable, Equatable {
        var id: String
        var title: String
        var detail: String
        var systemImage: String
        var isAccent: Bool
        var depth: Int
        var canDisclose: Bool
        var isExpanded: Bool
        var kind: Kind
        var isView = false
        var status: String? = nil
        var isProduction = false
        var context: String? = nil

        var isObject: Bool {
            switch kind {
            case .table, .column, .mongoCollection: true
            default: false
            }
        }
    }

    static func connectionKey(_ id: UUID) -> String { "connection:\(id.uuidString)" }
    static func schemaKey(_ id: UUID) -> String { "schema:\(id.uuidString)" }
    static func tableKey(_ id: UUID, _ table: String) -> String { "table:\(id.uuidString):\(table)" }
    static func columnKey(_ id: UUID, _ table: String, _ column: String) -> String {
        "column:\(id.uuidString):\(table.utf8.count):\(table):\(column)"
    }
    static func mongoDatabaseKey(_ id: UUID, _ name: String) -> String { "mongo:\(id.uuidString):\(name)" }
    static func mongoCollectionKey(_ id: UUID, _ database: String, _ collection: String) -> String {
        "mongo-coll:\(id.uuidString):\(database.utf8.count):\(database):\(collection)"
    }
    static func placeholderKey(_ id: UUID) -> String { "placeholder:\(id.uuidString)" }

    static func flatten(
        connections: [DatabaseConnection],
        connected: Set<UUID>,
        sqlSchemas: [UUID: IDEDatabaseSQLSchema],
        mongoSchemas: [UUID: IDEDatabaseMongoSchema],
        expanded: Set<String>,
        notes: [UUID: String] = [:],
        sqlScopes: [UUID: IDEDatabaseSQLScope] = [:],
        connecting: Set<UUID> = [],
        query: String = "",
        filter: Filter = .all,
        favorites: Set<String> = [],
        recents: [String] = []
    ) -> [Row] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = !query.isEmpty || filter != .all
        var expanded = expanded
        if searching {
            for source in connections {
                let id = source.id
                expanded.insert(connectionKey(id))
                expanded.insert(schemaKey(id))
                if filter != .tables && filter != .views && filter != .collections {
                    if let columns = sqlSchemas[id]?.columns {
                        for table in columns.keys { expanded.insert(tableKey(id, table)) }
                    }
                }
                for database in mongoSchemas[id]?.databases ?? [] { expanded.insert(mongoDatabaseKey(id, database)) }
            }
        }
        var rows: [Row] = []
        let groups = Dictionary(grouping: connections) { searching ? "" : ($0.group ?? "") }
        for name in groups.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let key = "group:\(name)"
            if !name.isEmpty {
                rows.append(Row(id: key, title: name, detail: "", systemImage: "folder", isAccent: false,
                                depth: 0, canDisclose: true, isExpanded: !expanded.contains(key), kind: .group))
                if expanded.contains(key) { continue }
            }
            let start = rows.count
            for connection in groups[name] ?? [] {
                let sourceStart = rows.count
                append(connection, connected: connected, sqlSchemas: sqlSchemas, mongoSchemas: mongoSchemas,
                       expanded: expanded, note: notes[connection.id], connecting: connecting,
                       scope: sqlScopes[connection.id], into: &rows)
                if searching {
                    for index in (sourceStart + 1)..<rows.count {
                        switch rows[index].kind {
                        case .column(_, let table, _):
                            rows[index].context = "\(connection.name) · \(table)"
                        case .mongoCollection(_, let database, _):
                            rows[index].context = "\(connection.name) · \(database)"
                        default:
                            rows[index].context = connection.name
                        }
                    }
                }
            }
            if !name.isEmpty { for index in start..<rows.count { rows[index].depth += 1 } }
        }
        guard searching else { return rows }
        if filter == .recents {
            let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rows = recents.compactMap { byID[$0] }
        } else {
            rows = rows.filter { filter.includes($0, favorites: favorites) }
        }
        rows = rows.filter { row in
            query.isEmpty || row.title.localizedStandardContains(query) || row.detail.localizedStandardContains(query)
                || row.context?.localizedStandardContains(query) == true
        }
        for index in rows.indices {
            rows[index].depth = 0
            rows[index].canDisclose = false
        }
        return rows
    }

    private static func append(
        _ connection: DatabaseConnection,
        connected: Set<UUID>,
        sqlSchemas: [UUID: IDEDatabaseSQLSchema],
        mongoSchemas: [UUID: IDEDatabaseMongoSchema],
        expanded: Set<String>,
        note: String?,
        connecting: Set<UUID>,
        scope: IDEDatabaseSQLScope?,
        into rows: inout [Row]
    ) {
        let id = connection.id
        let key = connectionKey(id)
        let isOpen = expanded.contains(key)
        let isConnected = connected.contains(id)
        rows.append(Row(
            id: key,
            title: connection.name,
            detail: (connection.engine == .sqlite
                ? "SQLite · \(connection.isInMemorySQLite ? "in memory" : (connection.database as NSString).abbreviatingWithTildeInPath)"
                : "\(connection.engine.displayName) · \(connection.host)") + (note.map { " · \($0)" } ?? ""),
            systemImage: isConnected ? "cylinder.split.1x2.fill" : "cylinder",
            isAccent: isConnected,
            depth: 0,
            canDisclose: true,
            isExpanded: isOpen,
            kind: .connection(id),
            status: connecting.contains(id) ? "Connecting" : (isConnected ? "Connected" : "Disconnected"),
            isProduction: connection.isProduction == true
        ))
        guard isOpen else { return }
        if !isConnected {
            rows.append(Row(
                id: placeholderKey(id),
                title: connecting.contains(id) ? "Connecting…" : "Not connected",
                detail: connecting.contains(id) ? "" : "Return to connect",
                systemImage: "bolt.slash",
                isAccent: false,
                depth: 1,
                canDisclose: false,
                isExpanded: false,
                kind: .placeholder(id)
            ))
            return
        }
        if connection.engine == .mongo {
            appendMongo(id, schema: mongoSchemas[id], expanded: expanded, into: &rows)
        } else {
            appendSQL(id, connection: connection, schema: sqlSchemas[id], expanded: expanded, scope: scope, into: &rows)
        }
    }

    private static func appendSQL(
        _ id: UUID,
        connection: DatabaseConnection,
        schema: IDEDatabaseSQLSchema?,
        expanded: Set<String>,
        scope: IDEDatabaseSQLScope?,
        into rows: inout [Row]
    ) {
        let key = schemaKey(id)
        let isOpen = expanded.contains(key)
        let database = scope?.database ?? connection.database
        rows.append(Row(
            id: key,
            title: connection.engine == .sqlite ? "main" : (database.isEmpty ? "Database" : database),
            detail: connection.engine == .postgres ? (scope?.schema ?? "public") : "",
            systemImage: "square.stack.3d.up",
            isAccent: false,
            depth: 1,
            canDisclose: true,
            isExpanded: isOpen,
            kind: .schema(id)
        ))
        guard isOpen else { return }
        for table in schema?.tables ?? [] {
            appendTable(id, table: table, isView: schema?.views.contains(table) == true,
                        columns: schema?.columns[table], expanded: expanded, into: &rows)
        }
    }

    private static func appendTable(
        _ id: UUID,
        table: String,
        isView: Bool,
        columns: [SQLColumn]?,
        expanded: Set<String>,
        into rows: inout [Row]
    ) {
        let key = tableKey(id, table)
        let isOpen = expanded.contains(key)
        rows.append(Row(
            id: key,
            title: table,
            detail: "",
            systemImage: isView ? "eye" : "tablecells",
            isAccent: false,
            depth: 2,
            canDisclose: true,
            isExpanded: isOpen,
            kind: .table(id, table),
            isView: isView
        ))
        guard isOpen else { return }
        for column in columns ?? [] {
            rows.append(Row(
                id: columnKey(id, table, column.name),
                title: column.name,
                detail: column.declaredType,
                systemImage: column.isPrimaryKey ? "key.fill" : "circle",
                isAccent: false,
                depth: 3,
                canDisclose: false,
                isExpanded: false,
                kind: .column(id, table, column.name)
            ))
        }
    }

    private static func appendMongo(
        _ id: UUID,
        schema: IDEDatabaseMongoSchema?,
        expanded: Set<String>,
        into rows: inout [Row]
    ) {
        for name in schema?.databases ?? [] {
            let key = mongoDatabaseKey(id, name)
            let isOpen = expanded.contains(key)
            rows.append(Row(
                id: key,
                title: name,
                detail: "",
                systemImage: "folder",
                isAccent: false,
                depth: 1,
                canDisclose: true,
                isExpanded: isOpen,
                kind: .mongoDatabase(id, name)
            ))
            guard isOpen else { continue }
            for collection in schema?.collections[name] ?? [] {
                rows.append(Row(
                    id: mongoCollectionKey(id, name, collection),
                    title: collection,
                    detail: "",
                    systemImage: "doc.text",
                    isAccent: false,
                    depth: 2,
                    canDisclose: false,
                    isExpanded: false,
                    kind: .mongoCollection(id, name, collection)
                ))
            }
        }
    }
}
