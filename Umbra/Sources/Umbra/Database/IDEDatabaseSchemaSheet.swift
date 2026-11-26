import SwiftUI

struct IDEDatabaseSchemaSheet: View {
    @State var draft: IDEDatabaseSchemaDraft
    let onOpen: (String, IDEDatabaseSchemaDraft) -> Void
    let loadSQLite: (IDEDatabaseSchemaDraft) async throws -> IDEDatabaseSQLiteRebuild
    @State private var schemaError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let statement = try? draft.statement()
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            Text(draft.operation.rawValue).font(.headline)
            Text(draft.connection.name).foregroundStyle(.secondary)
            if draft.needsSQLiteRebuild {
                if let schemaError {
                    Label(schemaError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(IDEAppearance.ColorToken.error)
                } else if let rebuild = draft.sqliteRebuild {
                    Text("The preview rebuilds the table and restores \(rebuild.definitions.count) index and trigger definitions. Run the entire script in one batch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView("Reading SQLite Schema").controlSize(.small)
                }
            }
            Form {
                TextField("Table", text: $draft.table)
                    .disabled(draft.operation != .createTable)
                switch draft.operation {
                case .createTable, .addColumn:
                    Section("Columns") {
                        ForEach($draft.columns) { $column in
                            HStack {
                                TextField("Column Name", text: $column.name)
                                Picker("Type", selection: $column.type) {
                                    ForEach(IDEDatabaseSchemaDraft.ColumnType.allCases) { Text($0.rawValue).tag($0) }
                                }
                                Toggle("Required", isOn: $column.required)
                                if draft.columns.count > 1 {
                                    Button("Remove Column", systemImage: "minus.circle") {
                                        draft.columns.removeAll { $0.id == column.id }
                                    }.labelStyle(.iconOnly)
                                }
                            }
                        }
                        if draft.operation == .createTable {
                            Button("Add Column", systemImage: "plus") { draft.columns.append(.init()) }
                        }
                    }
                case .createIndex, .addUnique, .addForeignKey:
                    Section(draft.operation == .createIndex ? "Index" : "Constraint") {
                        TextField("Name", text: $draft.name)
                        ForEach($draft.keys) { $column in
                            HStack {
                                TextField("Column Name", text: $column.name)
                                if draft.keys.count > 1 {
                                    Button("Remove Column", systemImage: "minus.circle") {
                                        draft.keys.removeAll { $0.id == column.id }
                                    }.labelStyle(.iconOnly)
                                }
                            }
                        }
                        if draft.operation == .addForeignKey {
                            TextField("Referenced Table", text: $draft.referencesTable)
                            TextField("Referenced Column", text: $draft.referencesColumn)
                        } else {
                            Button("Add Column", systemImage: "plus") { draft.keys.append(.init()) }
                        }
                        if draft.operation == .createIndex { Toggle("Unique Index", isOn: $draft.uniqueIndex) }
                    }
                }
            }
            .formStyle(.grouped)
            GroupBox("SQL Preview") {
                ScrollView {
                    Text(statement ?? "Enter valid names to generate SQL.")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
                .frame(height: 100)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open in Console") {
                    if let statement { onOpen(statement, draft) }
                    dismiss()
                }
                .disabled(statement == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .task {
            guard draft.needsSQLiteRebuild, draft.sqliteRebuild == nil else { return }
            do { draft.sqliteRebuild = try await loadSQLite(draft) }
            catch { if !Task.isCancelled { schemaError = error.localizedDescription } }
        }
    }
}
