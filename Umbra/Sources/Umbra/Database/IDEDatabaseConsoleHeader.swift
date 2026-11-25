import DatabaseKit
import Penumbra
import SwiftUI

struct IDEDatabaseConsoleHeader: View {
    let document: WorkbenchDocument
    let support: IDEDatabaseSupport
    let onBindingChange: () -> Void

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
                if let scope = scope(for: connection) {
                    Text(scope)
                        .lineLimit(1)
                        .help(scope)
                }
                Text(status(for: connection))
                if connection.readOnly {
                    Label("Read Only", systemImage: "lock")
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

    private func scope(for connection: DatabaseConnection) -> String? {
        switch connection.engine {
        case .sqlite: connection.isInMemorySQLite ? "In Memory · main" : "\(URL(fileURLWithPath: connection.database).lastPathComponent) · main"
        case .postgres: connection.database.isEmpty ? nil : connection.database
        case .mysql: connection.database.isEmpty ? nil : connection.database
        case .mongo: [binding?.mongoDatabase, binding?.mongoCollection].compactMap { $0 }.joined(separator: ".")
        }
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
