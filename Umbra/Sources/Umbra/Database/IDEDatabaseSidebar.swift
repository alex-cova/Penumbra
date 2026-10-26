import DatabaseKit
import SwiftUI

/// Data sources, schemas, tables and collections. Double-click a table or collection to query it.
struct IDEDatabaseSidebar: View {
    @Environment(IDEWorkspace.self) private var workspace

    private var support: IDEDatabaseSupport { workspace.databaseSupport }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(IDEAppearance.ColorToken.border)
            if support.catalog.connections.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(support.catalog.connections) { connection in
                            connectionBlock(connection)
                        }
                    }
                    .padding(IDEAppearance.Spacing.sm)
                }
            }
            if let banner = support.banner {
                Text(banner)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(IDEAppearance.Spacing.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Data Sources")
                .font(IDEAppearance.Typography.sidebarHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Spacer(minLength: 0)
            Button {
                workspace.showNewDatabaseConnection()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Data Source")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No data sources")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Text("Add a MySQL, PostgreSQL or MongoDB connection. The password is saved in the login Keychain.")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Button("New Data Source") { workspace.showNewDatabaseConnection() }
                .buttonStyle(.bordered)
        }
        .padding(IDEAppearance.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func connectionBlock(_ connection: DatabaseConnection) -> some View {
        let expanded = expandedBinding(IDEDatabaseSupport.connectionKey(connection.id))
        DisclosureGroup(isExpanded: expanded) {
            if support.isConnected(connection.id) {
                if connection.engine == .mongo {
                    mongoTree(connection)
                } else {
                    sqlTree(connection)
                }
            } else {
                Text("Not connected")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .padding(.leading, 16)
            }
        } label: {
            connectionLabel(connection)
        }
        .contextMenu { connectionMenu(connection) }
    }

    private func connectionLabel(_ connection: DatabaseConnection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: support.isConnected(connection.id) ? "cylinder.split.1x2.fill" : "cylinder")
                .foregroundStyle(
                    support.isConnected(connection.id)
                        ? IDEAppearance.ColorToken.accent
                        : IDEAppearance.ColorToken.muted
                )
            VStack(alignment: .leading, spacing: 0) {
                Text(connection.name)
                    .font(IDEAppearance.Typography.caption)
                    .lineLimit(1)
                Text("\(connection.engine.displayName) · \(connection.host)")
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            support.selectedConnectionID = connection.id
            support.selectedMongoDatabase = nil
            support.selectedMongoCollection = nil
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            support.selectedConnectionID = connection.id
            Task {
                do { try await support.connect(connection.id) }
                catch { support.banner = error.localizedDescription }
            }
        })
    }

    @ViewBuilder
    private func sqlTree(_ connection: DatabaseConnection) -> some View {
        let schema = support.sqlSchemas[connection.id]
        let schemaExpanded = expandedBinding(IDEDatabaseSupport.schemaKey(connection.id))
        DisclosureGroup(isExpanded: schemaExpanded) {
            ForEach(schema?.tables ?? [], id: \.self) { table in
                tableRow(connection, table: table, columns: schema?.columns[table])
            }
        } label: {
            Label(connection.database.isEmpty ? "database" : connection.database, systemImage: "square.stack.3d.up")
                .font(IDEAppearance.Typography.caption)
        }
        .padding(.leading, 8)
    }

    private func tableRow(_ connection: DatabaseConnection, table: String, columns: [SQLColumn]?) -> some View {
        let key = IDEDatabaseSupport.tableKey(connection.id, table)
        return DisclosureGroup(isExpanded: expandedBinding(key)) {
            if let columns {
                Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 2) {
                    ForEach(columns) { column in
                        GridRow {
                            Image(systemName: column.isPrimaryKey ? "key.fill" : "circle")
                                .font(.system(size: 8))
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                            Text(column.name)
                                .font(IDEAppearance.Typography.monoSmall)
                                .gridColumnAlignment(.leading)
                            Text(column.declaredType)
                                .font(IDEAppearance.Typography.monoSmall)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                                .lineLimit(1)
                                .gridColumnAlignment(.leading)
                        }
                    }
                }
                .padding(.leading, 12)
            }
        } label: {
            Label(table, systemImage: "tablecells")
                .font(IDEAppearance.Typography.caption)
        }
        .padding(.leading, 8)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            support.expanded.insert(key)
            workspace.openDatabaseTable(connection, table: table)
        })
        .contextMenu {
            Button("Query") { workspace.openDatabaseTable(connection, table: table) }
            Button("Copy CREATE TABLE") { workspace.copyCreateTable(connection, table: table) }
        }
        .onChange(of: support.expanded.contains(key)) { _, isExpanded in
            guard isExpanded else { return }
            Task { await support.ensureColumns(connectionID: connection.id, table: table) }
        }
    }

    @ViewBuilder
    private func mongoTree(_ connection: DatabaseConnection) -> some View {
        let schema = support.mongoSchemas[connection.id]
        ForEach(schema?.databases ?? [], id: \.self) { name in
            let key = IDEDatabaseSupport.mongoDatabaseKey(connection.id, name)
            DisclosureGroup(isExpanded: expandedBinding(key)) {
                ForEach(schema?.collections[name] ?? [], id: \.self) { collection in
                    Label(collection, systemImage: "doc.text")
                        .font(IDEAppearance.Typography.caption)
                        .padding(.leading, 12)
                        .onTapGesture(count: 2) {
                            workspace.openDatabaseCollection(connection, database: name, collection: collection)
                        }
                        .contextMenu {
                            Button("Query") {
                                workspace.openDatabaseCollection(connection, database: name, collection: collection)
                            }
                        }
                }
            } label: {
                Label(name, systemImage: "folder")
                    .font(IDEAppearance.Typography.caption)
            }
            .padding(.leading, 8)
            .onChange(of: support.expanded.contains(key)) { _, isExpanded in
                guard isExpanded else { return }
                support.selectedMongoDatabase = name
                Task { await support.ensureCollections(connectionID: connection.id, database: name) }
            }
        }
    }

    @ViewBuilder
    private func connectionMenu(_ connection: DatabaseConnection) -> some View {
        Button(support.isConnected(connection.id) ? "Reconnect" : "Connect") {
            Task {
                do { try await support.connect(connection.id) }
                catch { support.banner = error.localizedDescription }
            }
        }
        if support.isConnected(connection.id) {
            Button("Disconnect") { Task { await support.disconnect(connection.id) } }
        }
        Button("New Query Console") {
            support.selectedConnectionID = connection.id
            workspace.openDatabaseQueryConsole()
        }
        if connection.engine != .mongo {
            Button("Show Schema Diagram") { workspace.showSchemaDiagram(connection) }
            Button("Copy Database SQL") { workspace.copyDatabaseSQL(connection) }
        }
        Button("Edit…") { support.beginEdit(connection.id) }
        Divider()
        Button("Delete", role: .destructive) { support.remove(connection.id) }
    }

    private func expandedBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { support.expanded.contains(key) },
            set: { isExpanded in
                if isExpanded {
                    support.expanded.insert(key)
                } else {
                    support.expanded.remove(key)
                }
            }
        )
    }
}
