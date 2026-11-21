import SwiftUI

/// Choosing an external agent for the selected chat, shared by the header's provider menu and the empty
/// chat's suggestions: an adapter that is not installed goes to Settings (nothing downloads from here), and
/// the first use of an agent asks before Umbra starts its program.
@MainActor
struct IDEACPAgentChooser {
    let agent: IDEAgentController
    let openSettings: () -> Void

    private var settings: IDEAgentSettings { agent.settings }
    private var manager: IDEACPAdapterManager { IDEACPAdapterManager.shared }

    /// An agent found on this Mac that the empty chat can offer.
    struct Suggestion: Identifiable {
        enum Source { case configured(IDEACPDefinition), preset(IDEACPPreset) }
        let source: Source
        let name: String
        /// What would run, for the help text.
        let commandLine: String

        var id: String {
            switch source {
            case .configured(let definition): "row:\(definition.id.uuidString)"
            case .preset(let preset): "preset:\(preset.id)"
            }
        }
    }

    /// Enabled rows that can start, then catalog agents installed on this Mac and not yet added. Discovery only
    /// looks at the disk and `PATH`; nothing is started.
    var suggestions: [Suggestion] {
        var found: [Suggestion] = []
        for definition in settings.acpAgents where definition.isEnabled {
            switch availability(of: definition) {
            case .installed, .connected:
                let command = manager.resolution(for: definition, pathValue: settings.acpPathValue).launch?.commandLine
                    ?? definition.commandLine
                found.append(Suggestion(source: .configured(definition), name: definition.displayName, commandLine: command))
            default:
                break
            }
        }
        for preset in IDEACPRegistry.presets where !settings.acpAgents.contains(where: { $0.presetID == preset.id }) {
            guard let launch = manager.resolution(for: probe(preset), pathValue: settings.acpPathValue).launch else { continue }
            found.append(Suggestion(source: .preset(preset), name: preset.name, commandLine: launch.commandLine))
        }
        return found
    }

    func use(_ suggestion: Suggestion) {
        switch suggestion.source {
        case .configured(let definition): choose(.agent(definition.id))
        case .preset(let preset): add(preset)
        }
    }

    /// A row as it would be created from the preset, to ask the resolver what it would launch.
    private func probe(_ preset: IDEACPPreset) -> IDEACPDefinition {
        let launcher = preset.recordedLauncher
        return IDEACPDefinition(
            name: preset.name, command: launcher.command, args: launcher.args, presetID: preset.id, launchMode: .auto)
    }

    func isAvailable(_ preset: IDEACPPreset) -> Bool {
        manager.resolution(for: probe(preset), pathValue: settings.acpPathValue).launch != nil
    }

    func needsInstall(_ preset: IDEACPPreset) -> Bool {
        !isAvailable(preset) && preset.entry?.isManaged == true && !manager.isSandboxed
    }

    func availability(of definition: IDEACPDefinition) -> IDEACPAvailability {
        let live = agent.conversations.contains {
            $0.isACPConversation && $0.resolvedACPAgentID == definition.id && $0.acpLiveState == .connected
        }
        return manager.availability(of: definition, settings: settings, isLive: live)
    }

    func choose(_ binding: IDEACPBinding) {
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

    func add(_ preset: IDEACPPreset) {
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
