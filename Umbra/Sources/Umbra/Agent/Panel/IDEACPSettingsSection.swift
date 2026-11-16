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
        @Bindable var settings = settings
        _ = settings.acpDiscoveryEpoch
        return Section("Agents") {
            HStack(alignment: .firstTextBaseline) {
                Text("Agents are found on PATH and in the folders their installers use. Nothing is started until you allow it.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                Spacer()
                Button("Detect Again") { Task { await settings.refreshACPPath() } }
                    .font(IDEAppearance.Typography.caption)
                    .help("Look for installed agent CLIs again. Nothing is run.")
            }
            Text("Umbra Native uses the model above. An external agent runs on this Mac and talks to this panel over the Agent Client Protocol. Each chat keeps its own transcript.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            ForEach($settings.acpAgents) { $definition in
                IDEACPAgentRow(
                    definition: definition, isEnabled: $definition.isEnabled, settings: settings,
                    agent: agent, projectRoot: projectRoot,
                    editingID: $editingID, editName: $editName, editCommand: $editCommand)
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

    private func addCustom() {
        settings.addACPAgent(
            name: nameDraft.trimmingCharacters(in: .whitespaces),
            commandLine: commandDraft.trimmingCharacters(in: .whitespaces))
        nameDraft = ""
        commandDraft = ""
    }

    private func presetSummary(_ preset: IDEACPPreset) -> String {
        let launcher = preset.recordedLauncher
        let probe = IDEACPDefinition(
            name: preset.name, command: launcher.command, args: launcher.args, presetID: preset.id, launchMode: .auto)
        let resolution = manager.resolution(for: probe, pathValue: settings.acpPathValue)
        if resolution.launch != nil { return preset.summary }
        if preset.entry?.isManaged == true && !manager.isSandboxed {
            return "Adapter not installed. Install it under Adapters above. Adding this row does not download anything. \(preset.summary)"
        }
        if case .unavailable(let reason) = resolution, case .cliUnverified = reason { return reason.message }
        return ["Not installed.", preset.entry?.installHint, preset.summary].compactMap { $0 }.joined(separator: " ")
    }

}

extension IDEAgentSettings {
    /// Key names saved for an agent. Values stay in the Keychain.
    func acpEnvKeyNames(for agentID: UUID) -> [String] {
        acpEnvKeys[agentID.uuidString] ?? []
    }
}
