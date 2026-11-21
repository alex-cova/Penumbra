import SwiftUI

/// The agent this chat uses, in the panel header. Native models stay on their own control.
struct IDEACPProviderMenu: View {
    let agent: IDEAgentController
    let openSettings: () -> Void

    private var settings: IDEAgentSettings { agent.settings }
    private let manager = IDEACPAdapterManager.shared

    var body: some View {
        Menu {
            Button {
                choose(.native)
            } label: {
                item("Umbra Native", isSelected: agent.selected.resolvedACPAgentID == nil, detail: "On-device and API models")
            }
            if !settings.acpAgents.isEmpty {
                Section("Configured") {
                    ForEach(settings.acpAgents) { definition in
                        Button {
                            choose(.agent(definition.id))
                        } label: {
                            item(
                                definition.displayName,
                                isSelected: agent.selected.resolvedACPAgentID == definition.id,
                                detail: availability(of: definition).title)
                        }
                        .disabled(!definition.isEnabled)
                    }
                }
            }
            let available = IDEACPRegistry.presets.filter { preset in
                !settings.acpAgents.contains { $0.presetID == preset.id }
            }
            if !available.isEmpty {
                Section("Add Agent") {
                    ForEach(available) { preset in
                        Button {
                            add(preset)
                        } label: {
                            Text(presetLabel(preset))
                        }
                        .help(presetHelp(preset))
                    }
                }
            }
            Divider()
            if agent.selected.isACPConversation {
                Button("Restart Agent") { agent.selected.restartACP() }
                    .help("Stop the agent's process; it starts again on the next message")
            }
            Button("Manage Agents…", action: openSettings)
        } label: {
            HStack(spacing: IDEAppearance.Spacing.xs) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(title)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 148)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help(helpText)
        .accessibilityIdentifier(IDEACPAccessibility.provider)
        .accessibilityLabel("Agent provider")
        .accessibilityValue("\(title), \(statusTitle)")
        .accessibilityHint("Choose an agent for this chat, or manage agents")
        .task {
            await settings.refreshACPPath()
            await manager.load()
        }
    }

    private var title: String {
        guard let id = agent.selected.resolvedACPAgentID else { return "Umbra Native" }
        return settings.acpAgents.first { $0.id == id }?.displayName ?? "Missing agent"
    }

    private var statusTitle: String {
        guard let id = agent.selected.resolvedACPAgentID,
              let definition = settings.acpAgents.first(where: { $0.id == id })
        else { return "Umbra Native" }
        if agent.selected.isACPConversation {
            switch agent.selected.acpLiveState {
            case .idle: break
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            case .authenticationRequired(let method): return "Authentication required: \(method)"
            case .failed(let message):
                if IDEACPAvailabilityResolver.isProtocolMismatch(message) { return "Incompatible protocol" }
                if IDEACPAvailabilityResolver.isDisconnect(message) { return "Disconnected" }
                return "Error: \(message)"
            }
        }
        return availability(of: definition).title
    }

    private var helpText: String {
        "\(title) · \(statusTitle). Manage Agents changes the command, the default, and this workspace."
    }

    private var statusColor: Color {
        guard let id = agent.selected.resolvedACPAgentID,
              let definition = settings.acpAgents.first(where: { $0.id == id })
        else { return IDEAppearance.ColorToken.muted }
        if agent.selected.isACPConversation {
            switch agent.selected.acpLiveState {
            case .connected: return IDEAppearance.ColorToken.run
            case .connecting: return IDEAppearance.ColorToken.accent
            case .authenticationRequired: return .orange
            case .failed: return IDEAppearance.ColorToken.error
            case .idle: break
            }
        }
        switch availability(of: definition) {
        case .connected: return IDEAppearance.ColorToken.run
        case .authenticationRequired: return .orange
        case .failed: return IDEAppearance.ColorToken.error
        case .incompatibleProtocol, .disconnected: return IDEAppearance.ColorToken.error
        case .installed, .notInstalled, .adapterMissing, .disabled: return IDEAppearance.ColorToken.muted
        }
    }

    private var chooser: IDEACPAgentChooser { IDEACPAgentChooser(agent: agent, openSettings: openSettings) }

    private func isAvailable(_ preset: IDEACPPreset) -> Bool { chooser.isAvailable(preset) }

    private func needsInstall(_ preset: IDEACPPreset) -> Bool { chooser.needsInstall(preset) }

    private func presetLabel(_ preset: IDEACPPreset) -> String {
        if isAvailable(preset) { return preset.name }
        if needsInstall(preset) { return "\(preset.name) · install adapter…" }
        return "\(preset.name) · not installed"
    }

    private func presetHelp(_ preset: IDEACPPreset) -> String {
        if needsInstall(preset) {
            return "The adapter is not installed. Settings ▸ Agent ▸ Adapters installs and verifies it."
        }
        return preset.launchers.first?.note ?? preset.summary
    }

    private func availability(of definition: IDEACPDefinition) -> IDEACPAvailability { chooser.availability(of: definition) }

    private func item(_ name: String, isSelected: Bool, detail: String) -> some View {
        HStack {
            Text(name)
            Spacer(minLength: IDEAppearance.Spacing.sm)
            Text(detail)
                .foregroundStyle(.secondary)
            if isSelected {
                Image(systemName: "checkmark")
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("\(name), \(detail)\(isSelected ? ", selected" : "")")
    }

    private func choose(_ binding: IDEACPBinding) { chooser.choose(binding) }

    private func add(_ preset: IDEACPPreset) { chooser.add(preset) }
}
