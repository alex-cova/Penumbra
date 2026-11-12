import SwiftUI

/// One row of Settings ▸ Agent ▸ Agents: status, consent, default, test, edit and remove.
/// Extracted from `IDEACPSettingsSection` so the section stays a composition of subviews.
struct IDEACPAgentRow: View {
    let definition: IDEACPDefinition
    @Binding var isEnabled: Bool
    let settings: IDEAgentSettings
    var agent: IDEAgentController?
    var projectRoot: URL?
    @Binding var editingID: UUID?
    @Binding var editName: String
    @Binding var editCommand: String

    private let manager = IDEACPAdapterManager.shared

    var body: some View {
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
                Toggle("Enabled", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(definition.isEnabled ? "Disable \(definition.displayName)" : "Enable \(definition.displayName)")
                    .accessibilityLabel("\(definition.displayName) enabled")
                    .onChange(of: isEnabled) { _, newValue in
                        if !newValue { agent?.freezeUnpinnedTranscripts() }
                        settings.setACPEnabled(newValue, agentID: definition.id)
                    }
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

    private func makeDefault(_ definition: IDEACPDefinition) {
        agent?.freezeUnpinnedTranscripts()
        settings.setACPAllowed(true, agentID: definition.id)
        settings.acpActiveAgentID = definition.id
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
        case .authenticationRequired(let method):
            return "Authentication required · \(method)"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected. Send a message to start the agent again."
        case .incompatibleProtocol(let message):
            return "Incompatible protocol · \(message)"
        case .failed(let message):
            return "Error · \(message)"
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
