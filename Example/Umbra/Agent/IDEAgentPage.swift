import SwiftUI

/// Where the agent chat is drawn. Docked is the trailing side panel. Page covers the editor.
enum IDEAgentPlacement {
    case docked
    case page
}

/// The agent chat opened over the editor. The bar is the way back to the side panel; the conversation
/// stays a readable column. The editor underneath stays mounted.
struct IDEAgentPage: View {
    let agent: IDEAgentController
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            IDEAgentPageBar(onDock: dock, onClose: onClose)
            IDEAgentPanel(agent: agent, placement: .page)
                .frame(maxWidth: Self.columnWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, IDEAppearance.Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IDEAppearance.ColorToken.panel)
    }

    /// Long lines stay readable. Wider than the side panel, short of a full editor width.
    private static let columnWidth: CGFloat = 800

    private func dock() {
        guard agent.settings.opensAsPage else { return }
        if reduceMotion {
            agent.settings.opensAsPage = false
        } else {
            withAnimation(.easeOut(duration: 0.15)) { agent.settings.opensAsPage = false }
        }
    }
}

/// Tab strip for the expanded chat: the Agent tab closes it, and Side Panel docks it beside the editor.
private struct IDEAgentPageBar: View {
    let onDock: () -> Void
    let onClose: () -> Void
    @State private var isHoveringClose = false
    @State private var isHoveringDock = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: IDEAppearance.Spacing.sm) {
                Image(systemName: "brain")
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .accessibilityHidden(true)
                Text("Agent")
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .accessibilityAddTraits(.isHeader)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: IDEAppearance.IconSize.breadcrumbChevron, weight: .semibold))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
                        .background(
                            isHoveringClose ? IDEAppearance.ColorToken.controlHover : .clear,
                            in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHoveringClose = $0 }
                .help("Close Agent")
                .accessibilityLabel("Close Agent")
            }
            .font(IDEAppearance.Typography.tabLabel)
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .frame(maxHeight: .infinity)
            .background(IDEAppearance.ColorToken.tabActive)

            Spacer(minLength: IDEAppearance.Spacing.sm)

            Button(action: onDock) {
                Label("Side Panel", systemImage: "sidebar.trailing")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .padding(.horizontal, IDEAppearance.Spacing.sm)
                    .padding(.vertical, 3)
                    .background(
                        isHoveringDock ? IDEAppearance.ColorToken.controlHover : IDEAppearance.ColorToken.card,
                        in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .onHover { isHoveringDock = $0 }
            .help("Show the chat beside the editor.")
            .accessibilityLabel("Side Panel")
            .padding(.trailing, IDEAppearance.Spacing.sm)
        }
        .frame(height: IDEAppearance.Spacing.tabHeight)
        .background(IDEAppearance.ColorToken.tabBar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }
}
