import DatabaseKit
import Foundation

/// The Database sidebar as a flat list of rows, so arrow keys can walk it like Gradle and Maven.
enum IDEDatabaseTree {
    enum Kind: Equatable {
        case connection(UUID)
        case placeholder(UUID)
        case schema(UUID)
        case table(UUID, String)
        case column(UUID, String, String)
        case mongoDatabase(UUID, String)
        case mongoCollection(UUID, String, String)
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
    }

    static func connectionKey(_ id: UUID) -> String { "connection:\(id.uuidString)" }
    static func schemaKey(_ id: UUID) -> String { "schema:\(id.uuidString)" }
    static func tableKey(_ id: UUID, _ table: String) -> String { "table:\(id.uuidString):\(table)" }
    static func columnKey(_ id: UUID, _ table: String, _ column: String) -> String {
        "column:\(id.uuidString):\(table):\(column)"
    }
    static func mongoDatabaseKey(_ id: UUID, _ name: String) -> String { "mongo:\(id.uuidString):\(name)" }
    static func mongoCollectionKey(_ id: UUID, _ database: String, _ collection: String) -> String {
        "mongo-coll:\(id.uuidString):\(database):\(collection)"
    }
    static func placeholderKey(_ id: UUID) -> String { "placeholder:\(id.uuidString)" }

    static func flatten(
        connections: [DatabaseConnection],
        connected: Set<UUID>,
        sqlSchemas: [UUID: IDEDatabaseSQLSchema],
        mongoSchemas: [UUID: IDEDatabaseMongoSchema],
        expanded: Set<String>
    ) -> [Row] {
        var rows: [Row] = []
        for connection in connections {
            append(connection, connected: connected, sqlSchemas: sqlSchemas, mongoSchemas: mongoSchemas, expanded: expanded, into: &rows)
        }
        return rows
    }

    private static func append(
        _ connection: DatabaseConnection,
        connected: Set<UUID>,
        sqlSchemas: [UUID: IDEDatabaseSQLSchema],
        mongoSchemas: [UUID: IDEDatabaseMongoSchema],
        expanded: Set<String>,
        into rows: inout [Row]
    ) {
        let id = connection.id
        let key = connectionKey(id)
        let isOpen = expanded.contains(key)
        let isConnected = connected.contains(id)
        rows.append(Row(
            id: key,
            title: connection.name,
            detail: "\(connection.engine.displayName) · \(connection.host)",
            systemImage: isConnected ? "cylinder.split.1x2.fill" : "cylinder",
            isAccent: isConnected,
            depth: 0,
            canDisclose: true,
            isExpanded: isOpen,
            kind: .connection(id)
        ))
        guard isOpen else { return }
        if !isConnected {
            rows.append(Row(
                id: placeholderKey(id),
                title: "Not connected",
                detail: "",
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
            appendSQL(id, connection: connection, schema: sqlSchemas[id], expanded: expanded, into: &rows)
        }
    }

    private static func appendSQL(
        _ id: UUID,
        connection: DatabaseConnection,
        schema: IDEDatabaseSQLSchema?,
        expanded: Set<String>,
        into rows: inout [Row]
    ) {
        let key = schemaKey(id)
        let isOpen = expanded.contains(key)
        rows.append(Row(
            id: key,
            title: connection.database.isEmpty ? "database" : connection.database,
            detail: "",
            systemImage: "square.stack.3d.up",
            isAccent: false,
            depth: 1,
            canDisclose: true,
            isExpanded: isOpen,
            kind: .schema(id)
        ))
        guard isOpen else { return }
        for table in schema?.tables ?? [] {
            appendTable(id, table: table, columns: schema?.columns[table], expanded: expanded, into: &rows)
        }
    }

    private static func appendTable(
        _ id: UUID,
        table: String,
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
            systemImage: "tablecells",
            isAccent: false,
            depth: 2,
            canDisclose: true,
            isExpanded: isOpen,
            kind: .table(id, table)
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
