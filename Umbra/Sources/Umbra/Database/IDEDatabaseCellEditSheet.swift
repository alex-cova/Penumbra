import DatabaseKit
import SwiftUI

struct IDEDatabaseCellEditSheet: View {
    let draft: IDEDatabaseCellEditDraft
    var allowsClock = true
    let onStage: (SQLiteCellValue) throws -> Void
    private let revert: ((Bool) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var value: IDEDatabaseValueDraft
    @State private var error: String?

    init(draft: IDEDatabaseCellEditDraft, existing: SQLiteCellValue?, allowsClock: Bool = true,
         revert: ((Bool) -> Void)? = nil, onStage: @escaping (SQLiteCellValue) throws -> Void) {
        self.draft = draft
        self.allowsClock = allowsClock
        self.onStage = onStage
        self.revert = revert
        _value = State(initialValue: IDEDatabaseValueDraft(existing ?? .value(draft.original)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(draft.column.name)").font(.headline)
            Text("Row \((draft.row + 1).formatted())").font(.caption).foregroundStyle(.secondary)
            IDEDatabaseValueField(name: draft.column.name, allowsNull: !draft.column.required,
                                  allowsDefault: draft.column.defaultExpression != nil, allowsClock: allowsClock,
                                  draft: $value)
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.caption) }
            HStack {
                if let revert {
                    Menu("Revert") {
                        Button("Revert This Cell") { revert(false); dismiss() }
                        Button("Revert This Row") { revert(true); dismiss() }
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Stage Change") { stage() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func stage() {
        switch value.resolve(column: draft.column.name, defaultExpression: draft.column.defaultExpression, insert: false) {
        case .set(let cell):
            do {
                try onStage(cell)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        case .invalid(let message): error = message
        case .omit: break
        }
    }
}
