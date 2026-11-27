import DatabaseKit
import SwiftUI

enum IDEDatabaseTransactionAction {
    case begin(TransactionOptions), commit, rollback, savepoint, rollbackTo(String), release(String)
}

struct IDEDatabaseTransactionControls: View {
    let connection: DatabaseConnection
    let support: IDEDatabaseSupport

    private var state: TransactionState { support.sqlTransactions[connection.id] ?? .none }

    var body: some View {
        Menu {
            if state.isOpen {
                Button(connection.isProduction == true ? "Commit Production Transaction" : "Commit") { perform(.commit) }
                    .disabled(state == .aborted)
                Button("Rollback", role: .destructive) { perform(.rollback) }
                Divider()
                Button("Create Savepoint") { perform(.savepoint) }.disabled(state == .aborted)
                ForEach(support.databaseSavepoints[connection.id] ?? [], id: \.self) { name in
                    Menu(name) {
                        Button("Rollback to Savepoint") { perform(.rollbackTo(name)) }
                        Button("Release Savepoint") { perform(.release(name)) }.disabled(state == .aborted)
                    }
                }
            } else {
                Button("Begin Transaction") { perform(.begin(.init())) }
                if connection.engine != .sqlite {
                    Button("Begin Read-Only Transaction") { perform(.begin(.init(readOnly: true))) }
                    Menu("Begin with Isolation Level") {
                        ForEach(isolationLevels, id: \.self) { level in
                            Button(level.rawValue.capitalized) { perform(.begin(.init(isolation: level))) }
                        }
                    }
                }
            }
        } label: {
            Label(title, systemImage: state.isOpen ? "lock.open" : "arrow.trianglehead.clockwise")
        }
        .fixedSize()
        .disabled(support.isRunning || support.switchingSQLSourceID != nil)
        .help("Transaction actions apply to this source’s shared SQL session.")
    }

    private var isolationLevels: [IsolationLevel] {
        IsolationLevel.allCases.filter { connection.engine == .mysql || $0 != .readUncommitted }
    }

    private var title: String {
        switch state {
        case .none: "Autocommit"
        case .active(let readOnly): readOnly ? "Read-Only Transaction" : "Transaction Open"
        case .aborted: "Transaction Aborted"
        case .lost: "Transaction Lost"
        }
    }

    private func perform(_ action: IDEDatabaseTransactionAction) {
        Task { await support.performTransaction(action, connectionID: connection.id) }
    }
}
