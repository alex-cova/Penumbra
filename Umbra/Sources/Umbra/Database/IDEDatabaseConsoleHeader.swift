import DatabaseKit
import Penumbra
import SwiftUI

struct IDEDatabaseConsoleHeader: View {
    let document: WorkbenchDocument
    let support: IDEDatabaseSupport
    let onBindingChange: () -> Void
    @State private var showsHistory = false

    private var binding: IDEDatabaseConsoleBinding? { support.consoles[document.id] }
    private var connection: DatabaseConnection? {
        binding.flatMap { support.catalog.connection(id: $0.connectionID) }
    }

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            if connection?.engine == .mongo {
                Label(connection?.name ?? "", systemImage: "cylinder")
            } else {
                Menu {
                    ForEach(support.catalog.connections.filter { $0.engine != .mongo }) { source in
                        Button(source.name) { bind(to: source) }
                    }
                    if binding != nil {
                        Divider()
                        Button("Unbind Data Source", action: unbind)
                    }
                } label: {
                    Label(connection?.name ?? (binding == nil ? "Bind Data Source" : "Data Source Removed"), systemImage: "cylinder")
                }
                .fixedSize()
                .disabled(support.isRunning)
            }
            if let connection {
                if connection.isProduction == true {
                    Label("Production", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(IDEAppearance.ColorToken.error)
                }
                scopeControls(connection)
                if connection.engine != .mongo, !connection.readOnly, support.isConnected(connection.id),
                   support.sourceNotes[connection.id] == nil {
                    IDEDatabaseTransactionControls(connection: connection, support: support)
                } else {
                    Text(status(for: connection))
                }
                if connection.readOnly {
                    Label("Read Only", systemImage: "lock")
                }
                IDEIconButton(systemImage: "clock", help: "Query History") { showsHistory.toggle() }
                    .popover(isPresented: $showsHistory) {
                        IDEDatabaseQueryHistoryView(history: support.catalog.history, source: connection.id)
                    }
            }
            Spacer(minLength: 0)
        }
        .font(IDEAppearance.Typography.caption)
        .padding(.horizontal, IDEAppearance.Spacing.sm)
        .padding(.vertical, IDEAppearance.Spacing.xs)
        .background(IDEAppearance.ColorToken.panel)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func bind(to source: DatabaseConnection) {
        support.bindConsole(
            workbenchID: document.id, documentID: document.documentID,
            binding: IDEDatabaseConsoleBinding(connectionID: source.id, mongoDatabase: nil, mongoCollection: nil)
        )
        onBindingChange()
    }

    private func unbind() {
        support.closeConsole(workbenchID: document.id, documentID: document.documentID)
        onBindingChange()
    }

    @ViewBuilder
    private func scopeControls(_ connection: DatabaseConnection) -> some View {
        switch connection.engine {
        case .sqlite:
            Text(connection.isInMemorySQLite ? "In Memory · main" : "\(URL(fileURLWithPath: connection.database).lastPathComponent) · main")
                .lineLimit(1)
        case .postgres, .mysql:
            let scope = support.displayedSQLScope(connection)
            let changed = support.scopeChangedInConsole(connection.id)
            HStack(spacing: IDEAppearance.Spacing.xs) {
                IDEDatabaseScopePicker(label: "Database", current: changed ? "" : scope.database) {
                    try await support.sqlScopeChoices(connectionID: connection.id, schemas: false)
                } select: { value in
                    try await support.switchSQLScope(connectionID: connection.id, database: value)
                }
                if connection.engine == .postgres {
                    IDEDatabaseScopePicker(label: "Schema", current: changed ? "" : (scope.schema ?? "public")) {
                        try await support.sqlScopeChoices(connectionID: connection.id, schemas: true)
                    } select: { value in
                        try await support.switchSQLScope(connectionID: connection.id, schema: value)
                    }
                }
                if changed {
                    Label("Scope changed in SQL", systemImage: "exclamationmark.circle")
                        .help("Choose an indexed scope to reset the connection's search settings.")
                }
            }
            .disabled(!support.isConnected(connection.id) || support.isRunning || support.switchingSQLSourceID != nil)
            .help("Scope applies to every console bound to this source in this window.")
        case .mongo:
            if let binding {
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    IDEDatabaseScopePicker(label: "Database", current: binding.mongoDatabase ?? "") {
                        try await support.mongoScopeChoices(connectionID: connection.id, database: nil)
                    } select: { value in
                        updateMongoBinding(binding, database: value, collection: nil)
                    }
                    if let database = binding.mongoDatabase {
                        IDEDatabaseScopePicker(label: "Collection", current: binding.mongoCollection ?? "") {
                            try await support.mongoScopeChoices(connectionID: connection.id, database: database)
                        } select: { value in
                            updateMongoBinding(binding, database: database, collection: value)
                        }
                    }
                }
                .disabled(!support.isConnected(connection.id) || support.isRunning)
            }
        }
    }

    private func updateMongoBinding(_ current: IDEDatabaseConsoleBinding, database: String, collection: String?) {
        guard !support.isRunning, binding == current else { return }
        support.bindConsole(workbenchID: document.id, documentID: document.documentID,
                            binding: .init(connectionID: current.connectionID, mongoDatabase: database, mongoCollection: collection))
        onBindingChange()
    }

    private func status(for connection: DatabaseConnection) -> String {
        guard support.isConnected(connection.id) else { return "Disconnected" }
        guard connection.engine != .mongo else { return "Connected" }
        switch support.sqlTransactions[connection.id] ?? .none {
        case .none: return "Autocommit"
        case .active(let readOnly): return readOnly ? "Read-Only Transaction" : "Transaction Open"
        case .aborted: return "Transaction Aborted"
        case .lost: return "Transaction Lost"
        }
    }
}
