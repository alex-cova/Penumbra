import DatabaseKit
import Foundation

/// The schema picture of one data source: one node per table, columns as its rows, one edge per
/// foreign key. Opened from the connection's context menu; the session reloads it live.
enum IDEDatabaseDiagram {
    static let requestPrefix = "database:schema:"

    static func request(connection: DatabaseConnection) -> IDEDiagramRequest {
        IDEDiagramRequest(
            id: "\(requestPrefix)\(connection.id.uuidString)",
            title: "\(connection.name) Schema",
            symbolName: "tablecells",
            presentation: .dependencies
        )
    }

    static func connectionID(from request: IDEDiagramRequest) -> UUID? {
        guard request.id.hasPrefix(requestPrefix) else { return nil }
        return UUID(uuidString: String(request.id.dropFirst(requestPrefix.count)))
    }

    static func document(
        title: String,
        tables: [String],
        columns: [String: [SQLColumn]],
        foreignKeys: [SQLForeignKey]
    ) -> IDEDiagramDocument {
        var nodes: [IDEDiagramNode] = []
        var ids: [String: UUID] = [:]
        for table in tables {
            let attributes = (columns[table] ?? []).map { column in
                "\(column.name): \(column.declaredType)\(column.isPrimaryKey ? " PK" : "")"
            }
            let node = IDEDiagramNode(
                key: "dbtable:\(table)",
                kind: .table,
                title: table,
                subtitle: "\(attributes.count) columns",
                attributes: attributes
            )
            ids[table] = node.id
            nodes.append(node)
        }
        var edges: [IDEDiagramEdge] = []
        for key in foreignKeys {
            guard let source = ids[key.fromTable], let destination = ids[key.toTable] else { continue }
            edges.append(IDEDiagramEdge(
                sourceID: source, destinationID: destination, kind: .association, label: key.fromColumn
            ))
        }
        return IDEDiagramDocument(meta: .init(title: title), canvas: IDEDiagramDocument.defaultCanvas, nodes: nodes, edges: edges)
    }

    /// Reads the schema live so the picture is fresh on every open and reload. The window must
    /// already be connected; an unconnected data source explains itself instead of failing.
    @MainActor
    static func load(connectionID: UUID, workspace: IDEWorkspace) async -> IDEDiagramLoad? {
        guard let connection = workspace.databaseSupport.catalog.connection(id: connectionID) else { return nil }
        guard connection.engine != .mongo else { return nil }
        guard let session = workspace.databaseSupport.sqlSession(for: connectionID) else {
            return IDEDiagramLoad(
                document: .empty(title: "\(connection.name) Schema"),
                emptyMessage: "",
                failure: "Connect to \(connection.name) first, then show its diagram."
            )
        }
        do {
            let tables = try await session.tables()
            let columns = try await session.allColumns()
            let keys = try await session.foreignKeys()
            let document = document(title: "\(connection.name) Schema", tables: tables, columns: columns, foreignKeys: keys)
            return IDEDiagramLoad(
                document: document,
                emptyMessage: tables.isEmpty ? "\(connection.name) has no tables." : ""
            )
        } catch {
            return IDEDiagramLoad(document: .empty(title: "\(connection.name) Schema"), failure: error.localizedDescription)
        }
    }
}
