import SwiftUI

/// One server's tools in Settings: what each costs, a checkbox to hide it, and how the server
/// is loaded. The rows come from the last start, so the list is empty for a server that never ran.
///
/// A dedicated view (rather than a `@ViewBuilder` helper on the settings section) so the
/// filtering and token totals recompute only when this list's inputs change.
struct IDEMCPToolListView: View {
    @Bindable var store: IDEMCPStore
    let server: String
    let rows: [IDEMCPToolRow]

    private var shown: [IDEMCPToolRow] {
        rows.filter { !store.isHidden($0.name, server: server) }
    }

    private var tokens: Int {
        shown.reduce(0) { $0 + $1.tokens }
    }

    var body: some View {
        if !rows.isEmpty {
            DisclosureGroup("Tools: \(shown.count) of \(rows.count) on · about \(tokens) tokens") {
                Picker("Loading", selection: store.loadingBinding(server: server)) {
                    ForEach(IDEMCPLoading.allCases) { Text($0.title).tag($0) }
                }
                .help("Automatic lists a small server's tools and reaches a big one by search. A listed tool costs tokens in every request; a searched one costs a search first.")
                Button("Hide Tools That Duplicate Umbra's Own") { store.hideDuplicates(server: server) }
                    .help("Hides read, write, edit, list and search file tools, which the agent already has.")
                ForEach(rows) { row in
                    Toggle(isOn: store.shownBinding(tool: row.name, server: server)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(row.name) · \(row.tokens) tokens")
                                .font(IDEAppearance.Typography.monoSmall)
                            if !row.summary.isEmpty {
                                Text(row.summary)
                                    .font(IDEAppearance.Typography.caption)
                                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                Text("A change applies to your next message, in a new session that keeps the conversation.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
    }
}
