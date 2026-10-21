import AgentKit
import AgentKitMLX
import LocalModelStore
import SwiftUI

/// Which half of AI mode a picker serves. Chat can use any model; Code needs one that can call tools,
/// and can also hand the work to an external agent.
enum IDEAIModelPickerMode {
    case chat
    case code
}

/// The model of a chat, as a menu under the message field: "Opus 5.5 High". Lists the Claude models,
/// the configured OpenAI ones, the installed Ollama models, the on-device ones and, for Code, the
/// external agents; reasoning effort and model management are at the bottom.
struct IDEAIModelPicker: View {
    let settings: IDEAgentSettings
    let choice: IDEAIModelChoice
    let mode: IDEAIModelPickerMode
    let onSelect: (IDEAIModelChoice) -> Void
    let onManage: () -> Void

    private var store: IDELocalModelsStore { IDELocalModelsStore.shared }

    var body: some View {
        Menu {
            anthropicSection
            openAISection
            ollamaSection
            onDeviceSection
            if mode == .code { externalAgentSection }
            Divider()
            if !choice.isACP { effortMenu }
            Button("Manage Models…", action: onManage)
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpText)
        .accessibilityLabel("Model: \(plainLabel)")
        // The list of Ollama models is read when the menu is first shown, not on every redraw.
        .task { await settings.refreshOllamaModels(adjustSelection: false) }
    }

    // MARK: - Label

    private var plainLabel: String {
        if let agent = settings.acpAgents.first(where: { $0.id == choice.acpAgentID }) { return agent.displayName }
        return IDEAIModelNames.display(provider: choice.provider, model: choice.model)
    }

    /// One `Text`: a menu's label is flattened to a title and an icon, so a stack of views would lose its second part.
    private var label: some View {
        Text(labelText)
            .font(IDEAppearance.Typography.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 220)
    }

    private var labelText: AttributedString {
        var name = AttributedString(plainLabel)
        name.foregroundColor = IDEAppearance.ColorToken.foreground
        if !choice.isACP, let effort = IDEAIModelNames.effortLabel(choice.reasoningEffort) {
            var level = AttributedString("  " + effort)
            level.foregroundColor = IDEAppearance.ColorToken.muted
            name.append(level)
        }
        return name
    }

    private var helpText: String {
        choice.isACP ? "An external agent runs this session." : "\(choice.provider.title) · \(choice.model.isEmpty ? "no model chosen" : choice.model)"
    }

    // MARK: - Sections

    private func isCurrent(_ provider: IDEAgentProvider, _ model: String) -> Bool {
        !choice.isACP && choice.provider == provider && choice.model == model
    }

    private func pick(_ provider: IDEAgentProvider, _ model: String) {
        let effort = provider == choice.provider ? choice.reasoningEffort : settings.reasoningEffort(for: provider)
        onSelect(IDEAIModelChoice(provider: provider, model: model, reasoningEffort: effort))
    }

    private func item(_ title: String, provider: IDEAgentProvider, model: String, isEnabled: Bool = true) -> some View {
        Button {
            pick(provider, model)
        } label: {
            if isCurrent(provider, model) { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        .disabled(!isEnabled)
    }

    @ViewBuilder private var anthropicSection: some View {
        Section("Anthropic") {
            let needsKey = settings.hasAPIKey(for: .anthropic) ? "" : " · add key"
            ForEach(IDEAIModelNames.claude, id: \.id) { model in
                item(model.name + needsKey, provider: .anthropic, model: model.id)
            }
            let custom = settings.model(for: .anthropic)
            if !custom.isEmpty, !IDEAIModelNames.claude.contains(where: { $0.id == custom }) {
                item(custom + needsKey, provider: .anthropic, model: custom)
            }
        }
    }

    @ViewBuilder private var openAISection: some View {
        let responses = settings.model(for: .openAIResponses)
        let compatible = settings.model(for: .chatCompletions)
        let needsKey = settings.hasAPIKey(for: .openAIResponses) ? "" : " · add key"
        Section("OpenAI") {
            if !responses.isEmpty { item(responses + needsKey, provider: .openAIResponses, model: responses) }
            // The compatible endpoint is a different server when its address was changed.
            if !compatible.isEmpty, settings.baseURL(for: .chatCompletions) != IDEAgentProvider.chatCompletions.defaultBaseURL {
                let host = settings.endpointHost(for: .chatCompletions)
                let compatibleNeedsKey = settings.requiresAPIKey(for: .chatCompletions) && !settings.hasAPIKey(for: .chatCompletions)
                item("\(compatible) · \(host)" + (compatibleNeedsKey ? " · add key" : ""), provider: .chatCompletions, model: compatible)
            }
        }
    }

    @ViewBuilder private var ollamaSection: some View {
        Section("Ollama") {
            if settings.ollamaModels.isEmpty {
                Text(settings.ollamaError ?? "No models installed").foregroundStyle(.secondary)
            }
            ForEach(settings.ollamaModels) { model in
                let usable = mode == .chat || model.supportsTools
                item(
                    mode == .code && !model.supportsTools ? model.name + " (no tool support)" : model.name,
                    provider: .ollama, model: model.name, isEnabled: usable)
            }
        }
    }

    @ViewBuilder private var onDeviceSection: some View {
        Section("On This Mac") {
            if store.installed.isEmpty { Text("No models downloaded").foregroundStyle(.secondary) }
            ForEach(store.installed) { model in
                let info = store.info(for: model)
                let lacksTools = info.hasChatTemplate && !info.supportsTools
                item(
                    LocalModelFormat.shortName(model.id) + (mode == .code && lacksTools ? " (no tool support)" : ""),
                    provider: .mlx, model: model.id, isEnabled: mode == .chat || !lacksTools)
            }
        }
    }

    @ViewBuilder private var externalAgentSection: some View {
        if !settings.acpAgents.isEmpty {
            Section("External Agents") {
                ForEach(settings.acpAgents) { agent in
                    let isCurrent = choice.acpAgentID == agent.id
                    Button {
                        select(agent: agent)
                    } label: {
                        let name = settings.acpAllowedAgentIDs.contains(agent.id) ? agent.displayName : agent.displayName + " · allow…"
                        if isCurrent { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            }
        }
    }

    /// Running an external agent starts a program on this Mac, so the first use asks.
    private func select(agent: IDEACPDefinition) {
        if !settings.acpAllowedAgentIDs.contains(agent.id) {
            let alert = NSAlert()
            alert.messageText = "Allow “\(agent.displayName)” to run?"
            alert.informativeText = "Umbra starts \(([agent.command] + agent.args).joined(separator: " ")) as a process on this Mac when you send a message. Its changes to files and commands still ask you first. Stop ends the process."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            settings.setACPAllowed(true, agentID: agent.id)
        }
        onSelect(IDEAIModelChoice(provider: choice.provider, model: choice.model, reasoningEffort: choice.reasoningEffort, acpAgentID: agent.id))
    }

    private var effortMenu: some View {
        Menu("Reasoning") {
            ForEach(choice.provider.reasoningEfforts, id: \.self) { effort in
                Button {
                    var updated = choice
                    updated.reasoningEffort = effort
                    onSelect(updated)
                } label: {
                    if effort == choice.reasoningEffort { Label(effort.capitalized, systemImage: "checkmark") } else { Text(effort.capitalized) }
                }
            }
        }
    }
}
