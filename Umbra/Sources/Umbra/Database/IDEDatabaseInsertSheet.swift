import DatabaseKit
import SwiftUI

/// A new row, or a copy of one. Columns left on Default are not written, so SQLite assigns a
/// rowid and applies each column's own `DEFAULT`.
struct IDEDatabaseInsertSheet: View {
    let title: String
    let columns: [IDEDatabaseSQLiteEditTarget.InsertColumn]
    let onStage: ([SQLiteInsert.Field]) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [String: IDEDatabaseValueDraft]
    @State private var error: String?

    init(title: String, columns: [IDEDatabaseSQLiteEditTarget.InsertColumn], initial: [SQLiteInsert.Field],
         onStage: @escaping ([SQLiteInsert.Field]) throws -> Void) {
        self.title = title
        self.columns = columns
        self.onStage = onStage
        let given = Dictionary(initial.map { ($0.column, $0.value) }, uniquingKeysWith: { $1 })
        _drafts = State(initialValue: Dictionary(uniqueKeysWithValues: columns.map { column in
            if let cell = given[column.name] { return (column.name, IDEDatabaseValueDraft(cell)) }
            return (column.name, column.canUseDefault ? IDEDatabaseValueDraft(kind: .defaultValue) : IDEDatabaseValueDraft())
        }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text("Columns on Default are not written. The row is added when you submit the staged changes.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(columns) { column in
                        VStack(alignment: .leading, spacing: 2) {
                            IDEDatabaseValueField(
                                name: column.name, typeName: column.typeName.isEmpty ? "" : column.typeName.lowercased(),
                                allowsNull: !column.required, allowsDefault: column.canUseDefault,
                                draft: Binding(get: { drafts[column.name] ?? .init() }, set: { drafts[column.name] = $0 })
                            )
                            if column.isUnique {
                                Text("Unique: each row needs a different value.").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(maxHeight: 360)
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Stage Row") { stage() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func stage() {
        var fields: [SQLiteInsert.Field] = []
        for column in columns {
            switch (drafts[column.name] ?? .init()).resolve(column: column.name, defaultExpression: column.defaultExpression, insert: true) {
            case .set(let cell): fields.append(.init(column: column.name, value: cell))
            case .omit: break
            case .invalid(let message):
                error = message
                return
            }
        }
        do {
            try onStage(fields)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
