import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// The chat's permission mode. A menu to pick one; ⇧Tab in the message field walks through them.
struct IDEAgentPermissionChip: View {
    let mode: PermissionMode
    let select: (PermissionMode) -> Void

    private var tint: Color {
        switch mode {
        case .manual: IDEAppearance.ColorToken.muted
        case .acceptEdits: IDEAppearance.ColorToken.accent
        case .auto: .orange
        case .plan: .teal
        }
    }

    var body: some View {
        Menu {
            ForEach(PermissionMode.allCases, id: \.self) { candidate in
                Button {
                    select(candidate)
                } label: {
                    Label(candidate.title, systemImage: candidate == mode ? "checkmark" : candidate.symbol)
                }
                .help(candidate.detail)
            }
        } label: {
            Label(mode.title, systemImage: mode.symbol)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(tint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(mode.title): \(mode.detail)\nPress ⇧Tab in the message field to switch.")
        .accessibilityLabel("Permission mode: \(mode.title)")
    }
}
