import SwiftUI

struct IDEDatabaseLoadedFilterEditor: View {
    let columns: [String]
    let onApply: (IDEDatabaseLoadedFilter) -> Void
    @State private var text: String
    @State private var column: Int?
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(columns: [String], filter: IDEDatabaseLoadedFilter?, onApply: @escaping (IDEDatabaseLoadedFilter) -> Void) {
        self.columns = columns
        self.onApply = onApply
        _text = State(initialValue: filter?.text ?? "")
        let selected = filter?.column.flatMap { columns.indices.contains($0) ? $0 : nil }
        _column = State(initialValue: selected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filter Loaded Grid Rows").font(.headline)
            Text("Searches stored cell previews. Rows that arrive later require a new filter.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Column", selection: $column) {
                Text("All Columns").tag(nil as Int?)
                ForEach(columns.indices, id: \.self) { Text(columns[$0]).tag(Optional($0)) }
            }
            TextField("Contains", text: $text).focused($isFocused)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply(.init(text: text, column: column))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 330)
        .defaultFocus($isFocused, true)
    }
}
