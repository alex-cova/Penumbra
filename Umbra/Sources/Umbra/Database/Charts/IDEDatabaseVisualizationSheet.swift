import SwiftUI

struct IDEDatabaseVisualizationSheet: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case chart = "Chart", map = "Map"
        var id: Self { self }
    }

    let source: IDEDatabaseVisualizationSource
    let query: IDEDatabaseChartQuery?
    let runQuery: ((String, IDEDatabaseConsoleBinding) -> Void)?
    let onRow: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .chart

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            HStack {
                Text("Visualize Query Results").font(.headline)
                Spacer()
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if mode == .chart {
                IDEDatabaseChartBuilder(source: source, query: query, runQuery: runQuery, onRow: onRow)
            } else {
                IDEDatabaseMapBuilder(source: source, onRow: onRow)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(minWidth: 760, idealWidth: 940, minHeight: 460, idealHeight: 620)
    }
}
