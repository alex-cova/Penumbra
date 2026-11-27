import DatabaseKit
import SwiftUI
import UniformTypeIdentifiers

/// Data sources, schemas, tables and collections. Double-click a table or collection to query it.
struct IDEDatabaseSidebar: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var selectedID: String?
    @State private var typeahead = IDETypeaheadBuffer()
    @State private var query = ""
    @State private var filter: IDEDatabaseTree.Filter = .all
    @State private var failedConnection: UUID?
    @FocusState private var isListFocused: Bool
    @FocusState private var isSearchFocused: Bool

    private var support: IDEDatabaseSupport { workspace.databaseSupport }

    private var rows: [IDEDatabaseTree.Row] {
        IDEDatabaseTree.flatten(
            connections: support.catalog.connections,
            connected: Set(support.catalog.connections.map(\.id).filter(support.isConnected)),
            sqlSchemas: support.sqlSchemas,
            mongoSchemas: support.mongoSchemas,
            expanded: support.expanded,
            notes: support.sourceNotes.mapValues(\.tag),
            sqlScopes: support.sqlScopes,
            connecting: support.connectingIDs,
            query: query, filter: filter, favorites: support.favoriteObjects, recents: support.recentObjects
        )
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            header(rows.first { $0.id == selectedID })
            Divider().overlay(IDEAppearance.ColorToken.border)
            if support.catalog.connections.isEmpty {
                empty
            } else {
                search
                if rows.isEmpty {
                    ContentUnavailableView("No Matching Objects", systemImage: "magnifyingglass",
                                           description: Text("Try another search, or connect and expand a data source to load more objects."))
                } else {
                    tree(rows)
                }
            }
            if let banner = support.banner {
                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                    Text(banner)
                        .font(.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.error)
                        .textSelection(.enabled)
                    if let failedConnection, support.catalog.connection(id: failedConnection) != nil {
                        HStack {
                            Button("Retry") { connect(failedConnection) }
                            Button("Edit Connection…") { support.beginEdit(failedConnection) }
                        }
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(IDEAppearance.Spacing.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ideSidebarFocus(.database, on: $isListFocused)
        // Drop SQLite files here to open them.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in workspace.addSQLiteFiles([url]) }
                }
            }
            return !providers.isEmpty
        }
        .onChange(of: rows.map(\.id), initial: true) { _, ids in
            if let selectedID, ids.contains(selectedID) { return }
            selectedID = ids.first
        }
    }

    private var search: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            TextField("Search loaded objects", text: $query)
                .focused($isSearchFocused)
                .onSubmit { isListFocused = true }
                .onKeyPress(.downArrow) {
                    isListFocused = true
                    return .handled
                }
                .onKeyPress(.escape) {
                    if query.isEmpty { isListFocused = true } else { query = "" }
                    return .handled
                }
            Picker("Object Filter", selection: $filter) {
                ForEach(IDEDatabaseTree.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .accessibilityLabel("Object Filter")
            .fixedSize()
        }
        .padding(IDEAppearance.Spacing.xs)
    }

    private func header(_ selected: IDEDatabaseTree.Row?) -> some View {
        HStack(spacing: 4) {
            Text("Data Sources")
                .font(IDEAppearance.Typography.sidebarHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Spacer(minLength: 0)
            if !support.catalog.connections.isEmpty {
                IDEIconButton(systemImage: "magnifyingglass", help: "Search Database Objects") { isSearchFocused = true }
            }
            if let selected {
                IDEIconMenu(systemImage: "ellipsis", help: "Actions for \(selected.title)") { menu(for: selected) }
            }
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
            Text("Add a PostgreSQL, MySQL or MongoDB connection (the password is saved in the login Keychain), or open a SQLite file. You can drop a SQLite file here.")
                .font(IDEAppearance.Typography.monoSmall)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            HStack {
                Button("New Data Source") { workspace.showNewDatabaseConnection() }
                Button("Open SQLite File…") { workspace.openSQLiteFile() }
            }
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

    private func tree(_ rows: [IDEDatabaseTree.Row]) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        IDEDatabaseTreeRow(
                            row: row,
                            isSelected: selectedID == row.id,
                            isFavorite: support.favoriteObjects.contains(row.id),
                            onSelect: { select(row, toggling: false) },
                            onToggle: { select(row, toggling: true) },
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
        case .group:
            break
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
        if case .connection(let id) = row.kind, row.isExpanded == false, support.isConnected(id) {
            restoreBranches(id)
        }
        workspace.saveSession()
    }

    private func restoreBranches(_ id: UUID) {
        Task {
            for name in support.mongoSchemas[id]?.databases ?? [] where support.expanded.contains(IDEDatabaseTree.mongoDatabaseKey(id, name)) {
                await support.ensureCollections(connectionID: id, database: name)
            }
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
        if row.isObject {
            support.recentObjects.removeAll { $0 == row.id }
            support.recentObjects.insert(row.id, at: 0)
            if support.recentObjects.count > 24 { support.recentObjects.removeLast() }
            workspace.saveSession()
        }
        switch row.kind {
        case .group:
            toggle(row)
        case .connection(let id), .placeholder(let id):
            connect(id)
        case .table(let id, let table):
            guard let connection = support.catalog.connection(id: id) else { return }
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
        failedConnection = nil
        support.selectedConnectionID = id
        Task {
            do {
                try await support.connect(id)
                restoreBranches(id)
                workspace.saveSession()
            }
            catch is CancellationError {}
            catch {
                failedConnection = id
                if let source = support.catalog.connection(id: id) {
                    support.banner = IDEDatabaseConnectionDiagnostics.message(error.localizedDescription, engine: source.engine)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for row: IDEDatabaseTree.Row) -> some View {
        switch row.kind {
        case .group:
            Button(row.isExpanded ? "Collapse Group" : "Expand Group") { toggle(row) }
        case .connection(let id), .placeholder(let id), .schema(let id):
            if let connection = support.catalog.connection(id: id) {
                connectionMenu(connection)
            }
        case .table(let id, let table):
            if let connection = support.catalog.connection(id: id) {
                Button("Open Data") { activate(row) }
                Button("Open Definition") { workspace.openDatabaseDefinition(connection, table: table) }
                Button("Copy Qualified Name") { workspace.copyDatabaseObjectName(connection, parts: [table]) }
                Button("Generate SELECT") { workspace.generateDatabaseSelect(connection, table: table) }
                Button("Show Dependencies") { workspace.showDatabaseDependencies(connection, table: table) }
                if !row.isView { schemaActions(connection, table: table) }
                Button("Refresh Columns") { Task { await support.ensureColumns(connectionID: id, table: table, refresh: true) } }
            }
        case .mongoCollection(let id, let database, let collection):
            if let connection = support.catalog.connection(id: id) {
                Button("Open Documents") { activate(row) }
                Button("Copy Qualified Name") { workspace.copyDatabaseObjectName(connection, parts: [database, collection]) }
            }
        case .mongoDatabase(let id, let database):
            if let connection = support.catalog.connection(id: id) {
                Button("New Query Console") {
                    applySelection(row.kind)
                    workspace.openDatabaseQueryConsole()
                }
                Button("Copy Database Name") { workspace.copyDatabaseObjectName(connection, parts: [database]) }
                Button("Refresh Collections") { Task { await support.ensureCollections(connectionID: id, database: database, refresh: true) } }
            }
        case .column(let id, let table, let column):
            if let connection = support.catalog.connection(id: id) {
                Button("Copy Qualified Name") { workspace.copyDatabaseObjectName(connection, parts: [table, column]) }
            }
        }
        if row.isObject {
            Divider()
            Button(support.favoriteObjects.contains(row.id) ? "Remove Favorite" : "Add to Favorites") {
                if !support.favoriteObjects.insert(row.id).inserted { support.favoriteObjects.remove(row.id) }
                workspace.saveSession()
            }
        }
    }

    @ViewBuilder
    private func connectionMenu(_ connection: DatabaseConnection) -> some View {
        Button(support.isConnected(connection.id) ? "Reconnect" : "Connect") {
            connect(connection.id)
        }
        if support.isConnected(connection.id) {
            Button("Refresh Objects") { Task { await support.refreshSource(connection.id) } }
            Button("Disconnect") { Task { await support.disconnect(connection.id) } }
        }
        Button("New Query Console") {
            support.selectedConnectionID = connection.id
            workspace.openDatabaseQueryConsole()
        }
        if connection.engine != .mongo {
            if support.isConnected(connection.id), !connection.readOnly {
                Button("Create Table…") {
                    workspace.databaseSchemaDraft = .init(connection: connection, operation: .createTable,
                                                          sqlScope: support.displayedSQLScope(connection))
                }
            }
            Button("Show Schema Diagram") { workspace.showSchemaDiagram(connection) }
            Button("Copy Database SQL") { workspace.copyDatabaseSQL(connection) }
        }
        Button("Edit…") { support.beginEdit(connection.id) }
        Divider()
        Button("Delete", role: .destructive) { support.remove(connection.id) }
    }

    @ViewBuilder
    private func schemaActions(_ connection: DatabaseConnection, table: String) -> some View {
        if !connection.readOnly {
            Menu("Generate Schema Change") {
                ForEach(IDEDatabaseSchemaDraft.Operation.tableActions(for: connection.engine)) { operation in
                    Button(operation.rawValue) {
                        workspace.databaseSchemaDraft = .init(connection: connection, operation: operation, table: table,
                                                              sqlScope: support.displayedSQLScope(connection))
                    }
                }
            }
        }
    }
}

private struct IDEDatabaseTreeRow<Menu: View>: View {
    let row: IDEDatabaseTree.Row
    let isSelected: Bool
    let isFavorite: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onActivate: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            if row.canDisclose {
                Button(action: onToggle) {
                    IDEDisclosureChevron(isExpanded: row.isExpanded, size: 10, width: 12)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .frame(width: 12, height: 16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.isExpanded ? "Collapse \(row.title)" : "Expand \(row.title)")
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
            let detail = [row.detail.isEmpty ? nil : row.detail, row.context].compactMap { $0 }.joined(separator: " · ")
            if !detail.isEmpty {
                Text(detail)
                    .font(IDEAppearance.Typography.monoSmall)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isFavorite { Image(systemName: "star.fill").foregroundStyle(.secondary).accessibilityHidden(true) }
            if row.isProduction {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(IDEAppearance.ColorToken.error)
                    .help("Production")
                    .accessibilityHidden(true)
            }
            if let status = row.status {
                Image(systemName: status == "Connected" ? "circle.fill" : (status == "Connecting" ? "circle.dotted" : "circle"))
                    .font(.system(size: 8))
                    .foregroundStyle(status == "Connected" ? IDEAppearance.ColorToken.gitAdded : IDEAppearance.ColorToken.muted)
                    .help(status)
                    .accessibilityHidden(true)
            }
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
        .accessibilityLabel([row.title, row.detail.isEmpty ? nil : row.detail, row.context].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue([row.status, row.isProduction ? "Production" : nil, isFavorite ? "Favorite" : nil,
                             row.canDisclose ? (row.isExpanded ? "Expanded" : "Collapsed") : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAction(named: Text("Open")) { onActivate() }
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
