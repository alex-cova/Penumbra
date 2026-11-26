import SwiftUI

struct IDEDatabaseQueryHistoryView: View {
    let history: IDEDatabaseQueryHistory
    let source: UUID
    @State private var entries: [IDEDatabaseQueryHistory.Entry]?

    var body: some View {
        Group {
            if let entries {
                if entries.isEmpty {
                    ContentUnavailableView("No Query History", systemImage: "clock",
                                           description: Text("Run a statement on this data source to start its history."))
                } else {
                    List(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.preview)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(4)
                                .textSelection(.enabled)
                            HStack {
                                Text(entry.status.rawValue)
                                Text(entry.date, format: .dateTime.month().day().hour().minute().second())
                                Text(Duration.seconds(entry.seconds), format: .units(allowed: [.seconds, .milliseconds], width: .abbreviated))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                ProgressView("Loading Query History")
            }
        }
        .frame(width: 500, height: 320)
        .task(id: source) { entries = await history.entries(source: source) }
    }
}
