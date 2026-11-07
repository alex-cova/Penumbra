import DatabaseKit
import SwiftUI

/// Data sources, schemas, tables and collections. Double-click a table or collection to query it.
struct IDEDatabaseSidebar: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var selectedID: String?
    @State private var typeahead = IDETypeaheadBuffer()
    @FocusState private var isListFocused: Bool

    private var support: IDEDatabaseSupport { workspace.databaseSupport }

    private var rows: [IDEDatabaseTree.Row] {
        IDEDatabaseTree.flatten(
            connections: support.catalog.connections,
            connected: Set(support.catalog.connections.map(\.id).filter(support.isConnected)),
            sqlSchemas: support.sqlSchemas,
            mongoSchemas: support.mongoSchemas,
            expanded: support.expanded
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(IDEAppearance.ColorToken.border)
            if support.catalog.connections.isEmpty {
                empty
            } else {
                tree
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
        .ideSidebarFocus(.database, on: $isListFocused)
        .onChange(of: rows.map(\.id)) { _, ids in
            if let selectedID, ids.contains(selectedID) { return }
            selectedID = ids.first
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("Data Sources")
                .font(IDEAppearance.Typography.sidebarHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Spacer(minLength: 0)
            IDEIconButton(systemImage: "plus", help: "New Data Source") {
                workspace.showNewDatabaseConnection()
            }
        }
        .ideIconButtonSize(.compact)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .frame(height: IDEAppearance.Spacing.tabHeight + 2)
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
        .focusable()
        .focused($isListFocused)
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            workspace.focusActiveEditor()
            return .handled
        }
    }

    private var tree: some View {
        let rows = self.rows
        return ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        IDEDatabaseTreeRow(
                            row: row,
                            isSelected: selectedID == row.id,
                            onSelect: { select(row, toggling: row.canDisclose) },
                            onActivate: { activate(row) },
                            menu: { menu(for: row) }
                        )
                        .id(row.id)
                    }
                }
                .padding(.vertical, IDEAppearance.Spacing.xs)
            }
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                handleKey(press, rows: rows, scroller: scroller)
            }
            .onChange(of: selectedID) { _, id in
                if let id { scroller.scrollTo(id) }
            }
        }
    }

    private func handleKey(
        _ press: KeyPress,
        rows: [IDEDatabaseTree.Row],
        scroller: ScrollViewProxy
    ) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let current = rows.first { $0.id == selectedID }

        func move(_ delta: Int) {
            if let id = IDEListNeighbor.move(selectedID, in: rows.map(\.id), by: delta) {
                if let row = rows.first(where: { $0.id == id }) {
                    select(row, toggling: false)
                    scroller.scrollTo(id)
                }
            }
        }

        switch press.key {
        case .upArrow:
            typeahead.reset()
            move(-1)
            return .handled
        case .downArrow:
            typeahead.reset()
            move(1)
            return .handled
        case .rightArrow:
            typeahead.reset()
            guard let current, current.canDisclose, !current.isExpanded else { return .ignored }
            toggle(current)
            return .handled
        case .leftArrow:
            typeahead.reset()
            guard let current else { return .ignored }
            if current.canDisclose, current.isExpanded {
                toggle(current)
            } else if let index = rows.firstIndex(where: { $0.id == current.id }),
                      let parent = rows[..<index].last(where: { $0.depth < current.depth }) {
                select(parent, toggling: false)
                scroller.scrollTo(parent.id)
            }
            return .handled
        case .return:
            typeahead.reset()
            guard let current else { return .ignored }
            activate(current)
            return .handled
        case .escape:
            typeahead.reset()
            workspace.focusActiveEditor()
            return .handled
        default:
            guard let character = IDEListTypeahead.character(from: press) else { return .ignored }
            if let row = IDEListTypeahead.match(
                query: typeahead.typed(character), in: rows, selected: current, title: \.title
            ) {
                select(row, toggling: false)
                scroller.scrollTo(row.id)
            }
            return .handled
        }
    }

    private func select(_ row: IDEDatabaseTree.Row, toggling: Bool) {
        selectedID = row.id
        isListFocused = true
        applySelection(row.kind)
        if toggling { toggle(row) }
    }

    private func applySelection(_ kind: IDEDatabaseTree.Kind) {
        switch kind {
        case .connection(let id), .placeholder(let id), .schema(let id), .table(let id, _), .column(let id, _, _):
            support.selectedConnectionID = id
            support.selectedMongoDatabase = nil
            support.selectedMongoCollection = nil
        case .mongoDatabase(let id, let name):
            support.selectedConnectionID = id
            support.selectedMongoDatabase = name
            support.selectedMongoCollection = nil
        case .mongoCollection(let id, let database, let collection):
            support.selectedConnectionID = id
            support.selectedMongoDatabase = database
            support.selectedMongoCollection = collection
        }
    }

    private func toggle(_ row: IDEDatabaseTree.Row) {
        guard row.canDisclose else { return }
        if support.expanded.contains(row.id) {
            support.expanded.remove(row.id)
        } else {
            support.expanded.insert(row.id)
            loadIfNeeded(row)
        }
    }

    private func loadIfNeeded(_ row: IDEDatabaseTree.Row) {
        switch row.kind {
        case .table(let id, let table):
            Task { await support.ensureColumns(connectionID: id, table: table) }
        case .mongoDatabase(let id, let name):
            support.selectedMongoDatabase = name
            Task { await support.ensureCollections(connectionID: id, database: name) }
        default:
            break
        }
    }

    private func activate(_ row: IDEDatabaseTree.Row) {
        select(row, toggling: false)
        switch row.kind {
        case .connection(let id), .placeholder(let id):
            connect(id)
        case .table(let id, let table):
            guard let connection = support.catalog.connection(id: id) else { return }
            support.expanded.insert(row.id)
            workspace.openDatabaseTable(connection, table: table)
        case .mongoCollection(let id, let database, let collection):
            guard let connection = support.catalog.connection(id: id) else { return }
            workspace.openDatabaseCollection(connection, database: database, collection: collection)
        case .schema, .mongoDatabase:
            toggle(row)
        case .column:
            break
        }
    }

    private func connect(_ id: UUID) {
        support.selectedConnectionID = id
        Task {
            do { try await support.connect(id) }
            catch { support.banner = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func menu(for row: IDEDatabaseTree.Row) -> some View {
        switch row.kind {
        case .connection(let id), .placeholder(let id), .schema(let id):
            if let connection = support.catalog.connection(id: id) {
                connectionMenu(connection)
            }
        case .table(let id, let table):
            if let connection = support.catalog.connection(id: id) {
                Button("Query") { workspace.openDatabaseTable(connection, table: table) }
                Button("Copy CREATE TABLE") { workspace.copyCreateTable(connection, table: table) }
            }
        case .mongoCollection(let id, let database, let collection):
            if let connection = support.catalog.connection(id: id) {
                Button("Query") {
                    workspace.openDatabaseCollection(connection, database: database, collection: collection)
                }
            }
        case .mongoDatabase(let id, _):
            if let connection = support.catalog.connection(id: id) {
                connectionMenu(connection)
            }
        case .column:
            EmptyView()
        }
    }

    @ViewBuilder
    private func connectionMenu(_ connection: DatabaseConnection) -> some View {
        Button(support.isConnected(connection.id) ? "Reconnect" : "Connect") {
            connect(connection.id)
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
}

private struct IDEDatabaseTreeRow<Menu: View>: View {
    let row: IDEDatabaseTree.Row
    let isSelected: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if row.canDisclose {
                IDEDisclosureChevron(isExpanded: row.isExpanded, size: 10, width: 12)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 12, height: 16)
            } else {
                Spacer().frame(width: 12)
            }
            Image(systemName: row.systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(row.isAccent ? IDEAppearance.ColorToken.accent : IDEAppearance.ColorToken.muted)
                .frame(width: 14)
            Text(row.title)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .lineLimit(1)
            if !row.detail.isEmpty {
                Text(row.detail)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 14 + CGFloat(IDEAppearance.Spacing.sm))
        .padding(.trailing, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .background(isSelected ? IDEAppearance.ColorToken.selection : (isHovering ? IDEAppearance.ColorToken.controlHover : Color.clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onActivate)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .contextMenu { menu() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.detail.isEmpty ? row.title : "\(row.title), \(row.detail)")
        .accessibilityValue(row.canDisclose ? (row.isExpanded ? "Expanded" : "Collapsed") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
