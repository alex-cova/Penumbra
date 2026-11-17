import AgentKit
import AgentKitApple
import AgentKitMLX
import AppKit
import LocalModelStore
import SwiftUI

/// The Browser tab's open notes, going with the next message: "📌 3 notes · localhost:3000/dashboard". ✕ keeps
/// them out of that message (they stay on the page); click shows the Browser tab.
struct IDEAgentBrowserNotesChip: View {
    let notes: [IDEAIAnnotation]
    let isAttached: Bool
    let toggle: () -> Void
    let show: () -> Void

    private var title: String {
        let page = notes.first.map { "\($0.pageURL.host() ?? "page")\($0.pageURL.path)" } ?? ""
        return "\(notes.count) note\(notes.count == 1 ? "" : "s") · \(page)"
    }

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.xs) {
            Image(systemName: "pin.fill")
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 2))
                .foregroundStyle(isAttached ? Color.orange : IDEAppearance.ColorToken.muted)
            Button(action: show) {
                Text(title)
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground.opacity(isAttached ? 1 : 0.55))
                    .strikethrough(!isAttached)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Show the notes in the Browser tab")
            Spacer(minLength: 0)
            Text(isAttached ? "sent with your next message" : "kept out of the next message")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
            Button(
                isAttached ? "Leave browser notes out of the next message" : "Send browser notes with the next message",
                systemImage: isAttached ? "xmark" : "arrow.uturn.backward",
                action: toggle
            )
            .labelStyle(.iconOnly)
            .font(IDEAppearance.Typography.caption)
            .bold()
            .foregroundStyle(IDEAppearance.ColorToken.muted)
            .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .help(isAttached ? "Leave these notes out of the next message" : "Send these notes with the next message")
        }
        .padding(IDEAppearance.Spacing.xs + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.card)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
