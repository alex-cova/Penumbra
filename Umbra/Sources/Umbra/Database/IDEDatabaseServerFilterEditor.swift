import EditorIntelligence
import SwiftUI

struct IDEDatabaseServerFilterEditor: View {
    let source: IDEDatabaseServerFilter
    let run: (IDEDatabaseResultQuery) -> Void
    @State private var column = 0
    @State private var comparison = IDEDatabaseServerFilter.Comparison.equals
    @State private var input = IDEDatabaseParameterInput()
    @State private var preview: IDEDatabaseResultQuery?
    @State private var isPreparing = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filter on Server").font(.headline)
            Text("Preview a WHERE clause and run it in a new console.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Column", selection: $column) {
                    ForEach(source.columns.indices, id: \.self) { Text(source.columns[$0]).tag($0) }
                }
                Picker("Condition", selection: $comparison) {
                    ForEach(IDEDatabaseServerFilter.Comparison.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            HStack {
                Picker("Type", selection: $input.kind) {
                    ForEach(IDEDatabaseParameterInput.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                if input.kind != .null { TextField("Value", text: $input.text) }
            }
            if let preview {
                ScrollView {
                    Text(preview.sql).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
                if input.kind != .null {
                    LabeledContent("Filter value", value: input.value?.displayText() ?? "Unavailable").font(.caption)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if let preview {
                    Button("Run in New Console") { dismiss(); run(preview) }
                } else {
                    Button("Preview SQL", action: prepare).disabled(input.value == nil || isPreparing)
                }
            }
        }
        .padding(16)
        .frame(width: 520)
        .onChange(of: column) { preview = nil }
        .onChange(of: comparison) { preview = nil }
        .onChange(of: input) { preview = nil }
    }

    private func prepare() {
        guard let value = input.value else { return }
        let column = column
        let comparison = comparison
        let input = input
        let source = source
        isPreparing = true
        error = nil
        Task {
            defer { isPreparing = false }
            do {
                let result = try await runDetached { try source.query(column: column, comparison: comparison, value: value) }
                if self.column == column, self.comparison == comparison, self.input == input { preview = result }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
