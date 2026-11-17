import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// Messages written while the agent works, waiting for its next step. ✕ takes one back.
struct IDEAgentQueuedMessages: View {
    let queue: [IDEAgentConversation.QueuedMessage]
    let remove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(queue) { message in
                HStack(spacing: IDEAppearance.Spacing.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 1))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                    Text(message.text)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button("Remove queued message", systemImage: "xmark") { remove(message.id) }
                    .labelStyle(.iconOnly)
                    .font(IDEAppearance.Typography.caption)
                    .bold()
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .help("Take this message back")
                }
            }
            Text("Sent at the agent's next step")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        .padding(IDEAppearance.Spacing.xs + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
    }
}
