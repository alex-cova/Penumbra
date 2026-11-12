import SwiftUI

/// Settings ▸ Agent ▸ Agents. Lists Umbra Native, configured agents and presets.
/// A connection test is the user's consent to start the process; discovery only looks up `PATH`.
struct IDEACPSettingsSection: View {
    let settings: IDEAgentSettings
    var agent: IDEAgentController?
    var projectRoot: URL?

    @State private var nameDraft = ""
    @State private var commandDraft = ""
    @State private var editingID: UUID?
    @State private var editName = ""
    @State private var editCommand = ""

    private let manager = IDEACPAdapterManager.shared

    var body: some View {
        Section("Agents") {
            Text("Umbra Native uses the model above. An external agent runs on this Mac and talks to this panel over the Agent Client Protocol. Each chat keeps its own transcript.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            ForEach(settings.acpAgents) { definition in
                agentRow(definition)
            }
            let available = IDEACPRegistry.presets.filter { preset in
                !settings.acpAgents.contains { $0.presetID == preset.id }
            }
            if !available.isEmpty {
                ForEach(available) { preset in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                            Text(presetSummary(preset))
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Add") { _ = settings.materializePreset(preset) }
                            .help(preset.launchers.first?.note ?? preset.summary)
                    }
                }
            }
            TextField("Name", text: $nameDraft)
            TextField("Command", text: $commandDraft)
                .font(IDEAppearance.Typography.monoSmall)
            Button("Add Custom Agent") { addCustom() }
                .disabled(IDEACPDefinition.parseCommandLine(commandDraft.trimmingCharacters(in: .whitespaces)) == nil)
            Text("Adding a command does not run it. Allow is the consent to start that program. Secrets go to the Keychain and are not written into the transcript or the log.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .task { await settings.refreshACPPath() }
    }

    @ViewBuilder private func agentRow(_ definition: IDEACPDefinition) -> some View {
        let status = availability(of: definition)
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.displayName)
                    Text(launchText(definition))
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(1)
                    Text(statusLine(status, definition: definition))
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(statusColor(status))
                        .lineLimit(2)
                }
                Spacer()
                Toggle("Enabled", isOn: enabledBinding(definition))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(definition.isEnabled ? "Disable \(definition.displayName)" : "Enable \(definition.displayName)")
                    .accessibilityLabel("\(definition.displayName) enabled")
            }
            if let launch = manager.resolution(for: definition, pathValue: settings.acpPathValue).launch {
                Text("\(launch.sourceTitle) · \(launch.executable)")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .help(launch.commandLine)
            }
            if let preset = definition.presetID.flatMap(IDEACPRegistry.preset(id:)) {
                Text(preset.authHint)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            HStack {
                Button(settings.acpAllowedAgentIDs.contains(definition.id) ? "Allowed" : "Allow") {
                    settings.setACPAllowed(!settings.acpAllowedAgentIDs.contains(definition.id), agentID: definition.id)
                }
                .help("Allow is the consent to run this command.")
                .accessibilityLabel("Allow \(definition.displayName)")
                Button("Default") { makeDefault(definition) }
                    .accessibilityLabel("Make \(definition.displayName) the default")
                    .disabled(!definition.isEnabled || settings.acpActiveAgentID == definition.id && settings.acpAllowedAgentIDs.contains(definition.id))
                if let projectRoot {
                    let isOverride = settings.workspaceDefaultID(for: projectRoot) == definition.id
                    Button(isOverride ? "Workspace Default" : "Use in This Workspace") {
                        agent?.freezeUnpinnedTranscripts()
                        settings.setWorkspaceDefault(agentID: isOverride ? nil : definition.id, workspace: projectRoot)
                    }
                }
                Button("Test") { test(definition) }
                    .disabled(!definition.isEnabled || settings.acpProbes[definition.id]?.phase == .running)
                    .accessibilityLabel("Test \(definition.displayName)")
                Button("Edit") {
                    editingID = definition.id
                    editName = definition.name
                    editCommand = definition.commandLine
                }
                Button("Remove") { settings.removeACPAgent(id: definition.id) }
                    .accessibilityLabel("Remove \(definition.displayName)")
            }
            .font(IDEAppearance.Typography.caption)
            if editingID == definition.id {
                TextField("Name", text: $editName)
                TextField("Command", text: $editCommand)
                    .font(IDEAppearance.Typography.monoSmall)
                HStack {
                    Button("Save") {
                        if settings.updateACPAgent(id: definition.id, name: editName, commandLine: editCommand) {
                            editingID = nil
                        }
                    }
                    .disabled(IDEACPDefinition.parseCommandLine(editCommand.trimmingCharacters(in: .whitespaces)) == nil)
                    Button("Cancel") { editingID = nil }
                }
            }
            IDEACPSecretEditor(settings: settings, agentID: definition.id)
        }
        .padding(.vertical, IDEAppearance.Spacing.xxs)
    }

    private func enabledBinding(_ definition: IDEACPDefinition) -> Binding<Bool> {
        Binding(
            get: { settings.acpAgents.first { $0.id == definition.id }?.isEnabled ?? false },
            set: { enabled in
                if !enabled { agent?.freezeUnpinnedTranscripts() }
                settings.setACPEnabled(enabled, agentID: definition.id)
            })
    }

    private func makeDefault(_ definition: IDEACPDefinition) {
        agent?.freezeUnpinnedTranscripts()
        settings.setACPAllowed(true, agentID: definition.id)
        settings.acpActiveAgentID = definition.id
    }

    private func addCustom() {
        settings.addACPAgent(
            name: nameDraft.trimmingCharacters(in: .whitespaces),
            commandLine: commandDraft.trimmingCharacters(in: .whitespaces))
        nameDraft = ""
        commandDraft = ""
    }

    private func test(_ definition: IDEACPDefinition) {
        if !settings.acpAllowedAgentIDs.contains(definition.id) {
            let command = manager.resolution(for: definition, pathValue: settings.acpPathValue).launch?.commandLine
                ?? definition.commandLine
            var alert = IDEAlert.confirm(
                "Allow “\(definition.displayName)” to run?",
                detail: "Test starts \(command), checks the ACP handshake, and then quits the process.",
                confirm: "Allow and Test")
            guard alert.confirms() else { return }
            settings.setACPAllowed(true, agentID: definition.id)
        }
        Task {
            let environment: [String: String]
            if let fromHost = await agent?.host?.agentCommandEnvironment() {
                environment = fromHost
            } else {
                let login = await IDELoginShellPath.shared.entries()
                environment = AgentCommandEnvironment.make(javaHome: nil, loginPath: login)
            }
            // The handshake runs in a temporary folder, never in the project: the agent can read
            // its working directory.
            await manager.testConnection(definition: definition, settings: settings, environment: environment)
        }
    }

    /// What this row runs: the command line for a custom row, the chosen source for a catalog row.
    private func launchText(_ definition: IDEACPDefinition) -> String {
        guard definition.launchMode == .auto else { return definition.commandLine }
        switch manager.resolution(for: definition, pathValue: settings.acpPathValue) {
        case .launch(let launch): return launch.sourceTitle
        case .unavailable: return "Chosen by Umbra · \(definition.commandLine)"
        }
    }

    private func availability(of definition: IDEACPDefinition) -> IDEACPAvailability {
        let live = agent?.conversations.contains {
            $0.resolvedACPAgentID == definition.id && $0.acpLiveState == .connected
        } ?? false
        return manager.availability(of: definition, settings: settings, isLive: live)
    }

    private func presetSummary(_ preset: IDEACPPreset) -> String {
        let launcher = preset.recordedLauncher
        let probe = IDEACPDefinition(
            name: preset.name, command: launcher.command, args: launcher.args, presetID: preset.id, launchMode: .auto)
        if manager.resolution(for: probe, pathValue: settings.acpPathValue).launch != nil { return preset.summary }
        if preset.entry?.isManaged == true && !manager.isSandboxed {
            return "Adapter not installed. Install it under Adapters above. Adding this row does not download anything. \(preset.summary)"
        }
        return "Not installed. \(preset.summary)"
    }

    private func statusLine(_ status: IDEACPAvailability, definition: IDEACPDefinition) -> String {
        if settings.acpProbes[definition.id]?.phase == .running { return "Testing connection…" }
        switch status {
        case .installed:
            if case .connected(let version, let name, let load) = settings.acpProbes[definition.id]?.phase {
                let who = name.map { "\($0), " } ?? ""
                return "Installed · last test \(who)ACP \(version)" + (load ? ", can resume" : "")
            }
            return "Installed"
        case .notInstalled:
            return definition.command.contains("/") ? "Executable not found" : "Not installed"
        case .adapterMissing:
            return "Adapter not installed. Install it under Adapters above."
        case .authenticationRequired(let method): return "Authentication required · \(method)"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected. Send a message to start the agent again."
        case .incompatibleProtocol(let message): return "Incompatible protocol · \(message)"
        case .failed(let message): return "Error · \(message)"
        case .disabled: return "Disabled"
        }
    }

    private func statusColor(_ status: IDEACPAvailability) -> Color {
        switch status {
        case .failed, .incompatibleProtocol, .disconnected: IDEAppearance.ColorToken.error
        case .authenticationRequired: .orange
        case .connected: IDEAppearance.ColorToken.run
        default: IDEAppearance.ColorToken.muted
        }
    }
}

/// One agent's environment secrets. The value field is never shown again after it is saved.
private struct IDEACPSecretEditor: View {
    let settings: IDEAgentSettings
    let agentID: UUID
    @State private var key = ""
    @State private var value = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xxs) {
            let names = settings.acpEnvKeyNames(for: agentID)
            if !names.isEmpty {
                Text("Keychain: \(names.joined(separator: ", "))")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            HStack {
                TextField("ENV name", text: $key)
                SecureField("Value", text: $value)
                Button("Save to Keychain") { save() }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || value.isEmpty)
            }
            if let saveError {
                Text(saveError)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            }
        }
    }

    private func save() {
        let name = key.trimmingCharacters(in: .whitespaces)
        do {
            try settings.saveACPEnvValue(value, agentID: agentID, key: name)
            value = ""
            key = ""
            saveError = nil
        } catch {
            saveError = "Could not save that value to the Keychain."
        }
    }
}

extension IDEAgentSettings {
    /// Key names saved for an agent. Values stay in the Keychain.
    func acpEnvKeyNames(for agentID: UUID) -> [String] {
        acpEnvKeys[agentID.uuidString] ?? []
    }
}
