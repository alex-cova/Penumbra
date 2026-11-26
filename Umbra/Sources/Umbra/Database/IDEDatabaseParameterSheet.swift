import DatabaseKit
import SwiftUI

struct IDEDatabaseParameterPrompt: Identifiable {
    let id = UUID()
    let labels: [String]
    let onSubmit: ([DatabaseValue]) -> Void
}

struct IDEDatabaseParameterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: IDEDatabaseParameterPrompt
    @State private var inputs: [IDEDatabaseParameterInput]

    init(prompt: IDEDatabaseParameterPrompt) {
        self.prompt = prompt
        _inputs = State(initialValue: prompt.labels.map { _ in IDEDatabaseParameterInput() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            Text("Query Parameters").font(.headline)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: IDEAppearance.Spacing.sm, verticalSpacing: IDEAppearance.Spacing.sm) {
                    ForEach(inputs.indices, id: \.self) { index in
                        GridRow {
                            Text(prompt.labels[index]).font(IDEAppearance.Typography.monoSmall)
                            Picker("Type for \(prompt.labels[index])", selection: $inputs[index].kind) {
                                ForEach(IDEDatabaseParameterInput.Kind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                            TextField("Value for \(prompt.labels[index])", text: $inputs[index].text)
                                .textFieldStyle(.roundedBorder)
                                .disabled(inputs[index].kind == .null)
                        }
                    }
                }
            }
            .frame(maxHeight: min(360, CGFloat(inputs.count) * 34))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(inputs.contains { $0.value == nil })
            }
        }
        .padding(IDEAppearance.Spacing.md)
        .frame(width: 520)
    }

    private func submit() {
        let values = inputs.compactMap(\.value)
        guard values.count == inputs.count else { return }
        dismiss()
        prompt.onSubmit(values)
    }
}
