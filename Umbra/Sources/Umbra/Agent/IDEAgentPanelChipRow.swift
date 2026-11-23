import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// The chips in the composer card's bar (project and branch sit on the tray above it in AI mode): permission mode,
/// ACP mode, model/effort/speed (`IDEACPModelPicker`) and other options, context meter and model picker.
/// Restart Agent is in the header's provider menu. Extracted from `IDEAgentPanel`.
struct IDEAgentPanelChipRow: View {
    let agent: IDEAgentController
    let settings: IDEAgentSettings
    let isAIMode: Bool
    let openSettings: () -> Void

    @Environment(IDEWorkspace.self) private var workspace

    private var choice: IDEAIModelChoice { agent.selected.effectiveChoice }

    private func compactConversation() {
        let chat = agent.selected
        Task { await chat.compact(focus: nil) }
    }

    /// Left: how the agent may act (permission, the agent's own mode, its other options). Right, beside send:
    /// the context ring and what answers (the model picker), as in Codex's message box.
    var body: some View {
        HStack {
            IDEAgentPermissionChip(mode: agent.mode) { agent.selected.setMode($0) }
            if agent.selected.isACPConversation {
                IDEACPModeChip(conversation: agent.selected)
                if !agent.selected.acpDisplayedConfigOptions.isEmpty {
                    IDEACPConfigChip(conversation: agent.selected)
                }
            }
            Spacer(minLength: IDEAppearance.Spacing.sm)
            if let fraction = agent.selected.contextFraction {
                IDEAgentContextMeter(
                    fraction: fraction, tokens: agent.selected.contextTokens ?? 0,
                    window: settings.contextWindow(for: choice) ?? 0,
                    isBusy: agent.selected.isRunning || agent.selected.isCompacting,
                    compact: compactConversation
                )
            }
            if agent.selected.isACPConversation {
                if agent.selected.acpShowsModelPicker {
                    IDEACPModelPicker(conversation: agent.selected)
                }
            } else if isAIMode {
                IDEAIModelPicker(
                    settings: settings, choice: choice, mode: .code,
                    onSelect: { workspace.selectAIModel($0, for: .code) },
                    onManage: { workspace.isAIModelsPresented = true })
            } else {
                IDEAgentModelChip(settings: settings, openSettings: openSettings)
            }
        }
    }
}
