import AgentKit
import SwiftUI

/// Settings ▸ Agent ▸ MCP Servers: the servers the user added (switched on with "Use", which is the
/// consent to run that command), the ones the open project's files list (allowed one by one), and
/// what each did when last started.
struct IDEMCPSettingsSection: View {
    let store: IDEMCPStore
    let manager: IDEMCPManager?
    let projectRoot: URL?
    @State private var nameDraft = ""
    @State private var commandDraft = ""
    @State private var environmentDraft = ""

    var body: some View {
        Section("MCP Servers") {
            Text("MCP servers give the agent more tools (a database, an issue tracker, a browser). Each is a program on this Mac that Umbra starts when a chat first needs it and stops when the window closes. Every tool call still asks first unless a rule allows it.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)

            if store.servers.isEmpty {
                Text("No servers added. Add one by name and command, for example npx -y @modelcontextprotocol/server-filesystem /path.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            ForEach(store.servers) { entry in
                let isOn = store.isEnabled(entry.id)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayName)
                        Text(entry.commandLine)
                            .font(IDEAppearance.Typography.monoSmall)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .lineLimit(1)
                        if !entry.envKeys.isEmpty {
                            Text("Environment: \(entry.envKeys.joined(separator: ", ")) (in the Keychain)")
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                        }
                        stateText(for: "user:\(entry.id)")
                        toolList(server: entry.displayName)
                    }
                    Spacer()
                    Button {
                        store.setEnabled(!isOn, id: entry.id)
                    } label: {
                        Label("Use", systemImage: isOn ? "checkmark.square" : "square")
                    }
                    .buttonStyle(.borderless)
                    .help("Allow running this command on this Mac and offer its tools to the agent. It starts with your next message.")
                    .accessibilityLabel(isOn ? "Stop using \(entry.displayName)" : "Use \(entry.displayName)")
                    Button("Remove") { store.remove(id: entry.id) }
                }
            }
            TextField("Name (e.g. Filesystem)", text: $nameDraft)
            TextField("Command (e.g. npx -y @modelcontextprotocol/server-filesystem ~/Documents)", text: $commandDraft)
                .font(IDEAppearance.Typography.monoSmall)
            TextField("Environment, one KEY=VALUE per line (optional)", text: $environmentDraft, axis: .vertical)
                .font(IDEAppearance.Typography.monoSmall)
                .lineLimit(1...4)
            Button("Add Server") {
                store.add(name: nameDraft, commandLine: commandDraft, environment: environmentDraft)
                nameDraft = ""
                commandDraft = ""
                environmentDraft = ""
            }
            .disabled(commandDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Adding a server does not start it; “Use” does. Environment values go to the Keychain, and the program only sees what is listed here plus a basic PATH, not the rest of Umbra's environment.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)

            if let manager, !manager.project.servers.isEmpty || !manager.project.skipped.isEmpty || !manager.project.problems.isEmpty {
                projectServers(manager)
            }
        }
        .onAppear { manager?.refreshProject(root: projectRoot) }
    }

    @ViewBuilder
    private func projectServers(_ manager: IDEMCPManager) -> some View {
        Divider()
        Text("In this project (\(IDEMCPProjectConfig.fileNames.joined(separator: ", ")))")
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
        ForEach(manager.project.servers, id: \.name) { server in
            let allowed = store.isTrusted(server)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                    Text(server.displayCommand)
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(2)
                    if !server.env.isEmpty {
                        Text("Sets \(server.env.keys.sorted().joined(separator: ", "))")
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                    stateText(for: "project:\(server.name)")
                    toolList(server: server.name)
                }
                Spacer()
                if allowed {
                    Button("Revoke") { manager.revoke(server) }
                } else {
                    Button("Allow") { manager.allow(server) }
                        .help("These are programs from the project's own files. Allow them only if you trust this project.")
                }
            }
        }
        ForEach(manager.project.skipped, id: \.name) { skipped in
            Text("\(skipped.name): not used. \(skipped.reason)")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        ForEach(manager.project.problems, id: \.self) { problem in
            Text(problem)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(.red)
        }
        Text("A project's servers never start on their own: the first chat asks, and a change to a server's command, arguments or environment asks again.")
            .font(IDEAppearance.Typography.caption)
            .foregroundStyle(IDEAppearance.ColorToken.muted)
    }

    /// The server's tools with what each costs, a checkbox to hide it, and how the server is loaded.
    /// From the last start, so it is empty for a server that has never run.
    @ViewBuilder
    private func toolList(server: String) -> some View {
        let live = manager?.toolRows[server]
        let rows = live ?? (store.knownTools[server] ?? []).map {
            IDEMCPToolRow(server: server, name: $0.name, summary: $0.summary, tokens: $0.tokens, isHidden: false, isDeferred: false)
        }
        if !rows.isEmpty {
            let shown = rows.filter { !store.isHidden($0.name, server: server) }
            let tokens = shown.reduce(0) { $0 + $1.tokens }
            DisclosureGroup("Tools: \(shown.count) of \(rows.count) on · about \(tokens) tokens") {
                Picker("Loading", selection: Binding(get: { store.loading(for: server) }, set: { store.setLoading($0, server: server) })) {
                    ForEach(IDEMCPLoading.allCases) { Text($0.title).tag($0) }
                }
                .help("Automatic lists a small server's tools and reaches a big one by search. A listed tool costs tokens in every request; a searched one costs a search first.")
                Button("Hide Tools That Duplicate Umbra's Own") { store.hideDuplicates(server: server) }
                    .help("Hides read, write, edit, list and search file tools, which the agent already has.")
                ForEach(rows) { row in
                    Toggle(isOn: Binding(
                        get: { !store.isHidden(row.name, server: server) },
                        set: { store.setHidden(!$0, tool: row.name, server: server) })
                    ) {
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

    @ViewBuilder
    private func stateText(for id: String) -> some View {
        if let state = manager?.states.first(where: { $0.id == id }) {
            switch state.kind {
            case .running(let tools, let tokens, let searchOnly):
                Text("Running · \(tools) tool\(tools == 1 ? "" : "s")" + (searchOnly
                    ? " · found by search, not listed"
                    : " · listed, about \(tokens) tokens per request"))
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(.green)
            case .failed(let reason):
                Text("Did not start: \(reason)")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            case .waiting(let note):
                Text(note)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            case .off:
                EmptyView()
            }
        }
    }
}
