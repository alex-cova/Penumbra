import AppKit
import DatabaseKit
import SwiftUI

struct IDEDatabaseMutationPreview: View {
    let pending: IDEDatabasePendingEdits
    let sourceName: String
    let production: Bool
    /// The console has an open transaction: the batch will be applied inside it and not committed.
    let inTransaction: Bool
    let submit: () async throws -> Bool
    var cancelSubmission: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        let preview = pending.preview()
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Changes").font(.headline)
            Text("\(sourceName) · \(pending.target.schema ?? pending.target.mongoDatabase ?? "main").\(pending.target.table)")
            Text(summary(preview))
                .font(.caption).foregroundStyle(.secondary)
            if inTransaction {
                Label("A transaction is open. These changes are applied inside it and stay uncommitted until you commit.",
                      systemImage: "arrow.triangle.branch")
                    .font(.caption)
            } else if pending.target.engine == .mongo {
                Label("Not all-or-nothing: MongoDB has no rollback across documents here. Every document is checked first and nothing is written if any differs, but if the server rejects a write partway, the documents before it stay changed. Keep batches small.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("All changes commit together. If any original value no longer matches, nothing is written.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if production {
                Label("Production database", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if let conflict = pending.conflict { conflictView(conflict) }
            if let rejection = pending.rejection { rejectionView(rejection) }
            List(preview) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(heading(row)).font(.caption.weight(.semibold))
                        .foregroundStyle(row.kind == .delete ? Color.red : Color.primary)
                    detail(row)
                    if let statement = pending.target.statement(for: row.mutation) {
                        Text(statement.sql).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if !statement.parameters.isEmpty {
                            DisclosureGroup("Bound Parameters") {
                                ForEach(Array(statement.parameters.enumerated()), id: \.offset) { item in
                                    LabeledContent("Parameter \(item.offset + 1)", value: display(item.element))
                                        .font(.caption).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Copy Parameterized SQL") { copy(preview) }.disabled(preview.isEmpty)
                Spacer()
                if isSubmitting {
                    Button("Cancel Submission", role: .cancel, action: cancelSubmission).keyboardShortcut(.cancelAction)
                } else {
                    Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Button(commitTitle, role: production && !inTransaction ? .destructive : nil) { commit() }
                    .disabled(preview.isEmpty || isSubmitting || pending.conflict != nil)
            }
        }
        .padding(20)
        .frame(width: 700, height: 560)
        .interactiveDismissDisabled(isSubmitting)
    }

    private var commitTitle: String {
        if inTransaction { return "Submit to Transaction" }
        return production ? "Commit to Production" : "Commit Changes"
    }

    private func summary(_ preview: [IDEDatabasePendingEdits.PreviewRow]) -> String {
        let counts = IDEDatabasePendingEdits.Counts(
            updatedRows: preview.filter { $0.kind == .update }.count,
            insertedRows: preview.filter { $0.kind == .insert }.count,
            deletedRows: preview.filter { $0.kind == .delete }.count)
        return counts.summary.isEmpty ? "Nothing staged." : counts.summary
    }

    private func heading(_ row: IDEDatabasePendingEdits.PreviewRow) -> String {
        switch row.kind {
        case .update: "\(row.title) · expected count 1"
        case .delete: "\(row.title) · expected count 1"
        case .insert: "New row · expected count 1"
        }
    }

    @ViewBuilder private func detail(_ row: IDEDatabasePendingEdits.PreviewRow) -> some View {
        switch row.mutation {
        case .update(let update):
            ForEach(update.changes, id: \.column) { change in
                LabeledContent(change.column) {
                    Text("\(display(change.original)) → \(display(change.replacement))")
                        .font(.caption).lineLimit(3).textSelection(.enabled)
                }
            }
        case .insert(let insert):
            if insert.fields.isEmpty {
                Text("Every column takes its default.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(insert.fields, id: \.column) { field in
                LabeledContent(field.column) { Text(display(field.value)).font(.caption).lineLimit(3).textSelection(.enabled) }
            }
        case .delete(let delete):
            ForEach(delete.keys, id: \.column) { key in
                LabeledContent(key.column) { Text(display(key.value)).font(.caption) }
            }
            Text("Deleted only while \(delete.originals.count.formatted()) loaded values still match"
                 + (row.uncompared > 0 ? "; \(row.uncompared.formatted()) binary or truncated values are not compared." : "."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func conflictView(_ conflict: IDEDatabasePendingEdits.Conflict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(conflict.row.title) found the row changed before submission", systemImage: "exclamationmark.triangle")
                .font(.headline).foregroundStyle(.red)
            if let current = conflict.current {
                switch conflict.row.mutation {
                case .update(let update):
                    ForEach(update.changes.indices, id: \.self) { index in
                        let change = update.changes[index]
                        if current.indices.contains(index) {
                            Text("\(change.column) · Original \(display(change.original)) · Mine \(display(change.replacement)) · Current \(display(current[index]))")
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                case .delete(let delete):
                    ForEach(delete.originals.indices, id: \.self) { index in
                        let original = delete.originals[index]
                        if current.indices.contains(index), current[index] != original.value {
                            Text("\(original.column) · Original \(display(original.value)) · Current \(display(current[index]))")
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                case .insert: EmptyView()
                }
                HStack {
                    Button("Use Current as Baseline") { pending.rebaseConflict() }
                        .disabled(!current.allSatisfy { pending.target.accepts($0) })
                    Button("Drop This Row's Changes") { pending.discardConflictedRow() }
                }
            } else {
                Text("The key no longer identifies a row. Drop its changes or reopen the table.").font(.caption)
                Button("Drop This Row's Changes") { pending.discardConflictedRow() }
            }
        }
    }

    private func rejectionView(_ rejection: IDEDatabasePendingEdits.Rejection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("The database rejected \(rejection.row.title.lowercased())", systemImage: "xmark.octagon")
                .font(.headline).foregroundStyle(.red)
            Text(rejection.message).font(.caption).textSelection(.enabled)
            Text("Nothing was written. Your staged changes are kept; fix or revert that row and submit again.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func commit() {
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                if try await submit() { dismiss() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func copy(_ preview: [IDEDatabasePendingEdits.PreviewRow]) {
        let statements = preview.compactMap { pending.target.statement(for: $0.mutation)?.sql }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(statements.joined(separator: "\n\n"), forType: .string)
    }

    private func display(_ cell: SQLiteCellValue) -> String {
        switch cell {
        case .value(let value): display(value)
        case .expression(let expression): expression.title
        }
    }

    private func display(_ value: DatabaseValue) -> String {
        if value.isNull { return "NULL" }
        if value.presence == .empty { return "Empty string" }
        return value.displayText() ?? "Unavailable"
    }
}
