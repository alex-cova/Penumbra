import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// The external agent's own mode (`session/set_mode`), visibly separate from Umbra's
/// `PermissionMode` chip: the agent's modes are agent-defined, local gating stays Umbra's.
struct IDEACPModeChip: View {
    let conversation: IDEAgentConversation

    var body: some View {
        if conversation.acpAvailableModes.isEmpty {
            Text(conversation.acpAgentName ?? "ACP agent")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .lineLimit(1)
        } else {
            Menu {
                ForEach(conversation.acpAvailableModes, id: \.id) { candidate in
                    Button {
                        conversation.setACPMode(candidate.id)
                    } label: {
                        if candidate.id == conversation.acpCurrentModeID {
                            Label(candidate.name, systemImage: "checkmark")
                        } else {
                            Text(candidate.name)
                        }
                    }
                    .help(candidate.description ?? candidate.name)
                }
            } label: {
                Label(
                    conversation.acpAvailableModes.first { $0.id == conversation.acpCurrentModeID }?.name ?? "Agent mode",
                    systemImage: "person.crop.circle")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.accent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("The external agent's mode. Umbra's permission mode (left) still gates file and terminal effects on this Mac.")
            .accessibilityLabel("ACP agent mode")
        }
    }
}
