import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// The row of chips under the agent panel's field: project/branch (AI mode), permission mode,
/// ACP mode/config, model, context meter and model picker. Extracted from `IDEAgentPanel`.
struct IDEAgentPanelChipRow: View {
    let agent: IDEAgentController
    let settings: IDEAgentSettings
    let isAIMode: Bool
    let openSettings: () -> Void

    @Environment(IDEWorkspace.self) private var workspace

    private var choice: IDEAIModelChoice { agent.selected.effectiveChoice }

    var body: some View {
        HStack {
            if isAIMode {
                IDEAIProjectChip()
                IDEAIBranchChip()
            }
            IDEAgentModeChip(mode: agent.mode) { agent.selected.setMode($0) }
            if agent.selected.isACPConversation {
                IDEACPModeChip(conversation: agent.selected)
                if !agent.selected.acpConfigOptions.isEmpty {
                    IDEACPConfigChip(conversation: agent.selected)
                }
                Button("Restart Agent") { agent.selected.restartACP() }
                    .buttonStyle(.borderless)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .help("Kill the ACP agent process; it restarts on the next message")
            } else if !isAIMode {
                IDEAgentModelChip(settings: settings, openSettings: openSettings)
            }
            Spacer(minLength: IDEAppearance.Spacing.sm)
            if let fraction = agent.selected.contextFraction {
                IDEAgentContextMeter(
                    fraction: fraction, tokens: agent.selected.contextTokens ?? 0,
                    window: settings.contextWindow(for: choice) ?? 0,
                    isBusy: agent.selected.isRunning || agent.selected.isCompacting
                ) {
                    let chat = agent.selected
                    Task { await chat.compact(focus: nil) }
                }
            }
            if isAIMode, !agent.selected.isACPConversation {
                IDEAIModelPicker(
                    settings: settings, choice: choice, mode: .code,
                    onSelect: { workspace.selectAIModel($0, for: .code) },
                    onManage: { workspace.isAIModelsPresented = true })
            }
        }
    }
}
