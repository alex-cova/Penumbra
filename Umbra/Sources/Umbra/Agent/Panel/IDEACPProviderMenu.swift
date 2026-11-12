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

    /// A row as it would be created from the preset, to ask the resolver what it would launch.
    private func probe(_ preset: IDEACPPreset) -> IDEACPDefinition {
        let launcher = preset.recordedLauncher
        return IDEACPDefinition(
            name: preset.name, command: launcher.command, args: launcher.args, presetID: preset.id, launchMode: .auto)
    }

    private func isAvailable(_ preset: IDEACPPreset) -> Bool {
        manager.resolution(for: probe(preset), pathValue: settings.acpPathValue).launch != nil
    }

    private func needsInstall(_ preset: IDEACPPreset) -> Bool {
        !isAvailable(preset) && preset.entry?.isManaged == true && !manager.isSandboxed
    }

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

    private func availability(of definition: IDEACPDefinition) -> IDEACPAvailability {
        let live = agent.conversations.contains {
            $0.isACPConversation && $0.resolvedACPAgentID == definition.id && $0.acpLiveState == .connected
        }
        return manager.availability(of: definition, settings: settings, isLive: live)
    }

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

    private func choose(_ binding: IDEACPBinding) {
        if let id = binding.agentID {
            guard let definition = settings.acpAgents.first(where: { $0.id == id }) else { return }
            // A catalog agent whose adapter is not installed cannot start: Settings installs it.
            if availability(of: definition) == .adapterMissing {
                openSettings()
                return
            }
            guard ensureAllowed(definition) else { return }
        }
        agent.selectProvider(binding)
    }

    private func add(_ preset: IDEACPPreset) {
        // An adapter that is not installed is installed in Settings, with the approval sheet.
        // Choosing it here never downloads anything.
        guard !needsInstall(preset) else {
            openSettings()
            return
        }
        let definition = settings.materializePreset(preset)
        guard ensureAllowed(definition) else { return }
        agent.selectProvider(.agent(definition.id))
    }

    /// Running an external agent starts a program on this Mac, so the first use asks.
    private func ensureAllowed(_ definition: IDEACPDefinition) -> Bool {
        guard !settings.acpAllowedAgentIDs.contains(definition.id) else { return true }
        var alert = IDEAlert.confirm(
            "Allow “\(definition.displayName)” to run?",
            detail: consentDetail(definition),
            confirm: "Allow")
        guard alert.confirms() else { return false }
        settings.setACPAllowed(true, agentID: definition.id)
        return true
    }

    private func consentDetail(_ definition: IDEACPDefinition) -> String {
        let command = manager.resolution(for: definition, pathValue: settings.acpPathValue).launch?.commandLine
            ?? definition.commandLine
        return "Umbra starts \(command) when you send a message or test the connection. File changes and commands still ask you first. Stop ends the process."
    }
}
