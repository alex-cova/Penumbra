import SwiftUI

/// A short message at the bottom of the agent panel, gone after `timeout`: "Closed “Parser work” · Undo",
/// "Couldn't copy the path". Not a notification: it is not in the bell's list, Do Not Disturb does not
/// hide it, and only the panel shows it. One at a time; a new one replaces the one showing.
struct IDEAgentToast: Identifiable, Equatable {
    enum Kind: Equatable {
        case info
        case error
    }

    struct Action {
        let label: String
        let perform: @MainActor () -> Void
    }

    let id = UUID()
    var title: String
    var detail: String?
    var kind: Kind = .info
    var timeout: Duration = .seconds(4)
    var action: Action?

    static func == (lhs: IDEAgentToast, rhs: IDEAgentToast) -> Bool { lhs.id == rhs.id }
}

/// Shows the controller's toast, announced to VoiceOver when it appears, like the banners.
struct IDEAgentToastLane: View {
    let agent: IDEAgentController

    var body: some View {
        Group {
            if let toast = agent.toast {
                IDEAgentToastCard(toast: toast, dismiss: { agent.dismissToast(toast.id) })
                    .ideTransition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear { announce(toast) }
                    .id(toast.id)
            }
        }
        .ideAnimation(IDEAppearance.Motion.standard, value: agent.toast)
    }

    private func announce(_ toast: IDEAgentToast) {
        let text = [toast.title, toast.detail].compactMap(\.self).joined(separator: ". ")
        AccessibilityNotification.Announcement(text).post()
    }
}

private struct IDEAgentToastCard: View {
    let toast: IDEAgentToast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.sm) {
            Image(systemName: toast.kind == .error ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(toast.kind == .error ? IDEAppearance.ColorToken.error : IDEAppearance.ColorToken.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(2)
                if let detail = toast.detail {
                    Text(detail)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if let action = toast.action {
                Button(action.label) {
                    action.perform()
                    dismiss()
                }
                .controlSize(.small)
            }
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, IDEAppearance.Spacing.md)
        .padding(.vertical, IDEAppearance.Spacing.sm)
        .background(
            IDEAppearance.ColorToken.card,
            in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.panel, style: .continuous)
                .strokeBorder(IDEAppearance.ColorToken.border, lineWidth: 1)
        }
        .shadow(color: IDEAppearance.Shadow.cardColor, radius: 10, y: 4)
        .accessibilityElement(children: .contain)
    }
}
