import SwiftUI

/// The narrow icon column on the window's left or right edge (IntelliJ's tool window bar,
/// VS Code's activity bar). Each button opens or hides one tool window; the top group holds side
/// panels, the bottom group the bottom-panel tabs.
struct IDEToolWindowStripe: View {
    enum Edge {
        case leading
        case trailing
    }

    let edge: Edge

    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        IDEToolWindowStripeLegacy(
            edge: edge,
            topItems: topItems,
            bottomItems: bottomItems
        )
    }

    /// True when the stripe has any button; the right stripe is left out otherwise.
    static func hasItems(edge: Edge, workspace: IDEWorkspace) -> Bool {
        let items = IDEToolWindowStripe(edge: edge).items(workspace)
        return !items.top.isEmpty || !items.bottom.isEmpty
    }

    private var topItems: [IDEToolWindowStripeItem] { items(workspace).top }
    private var bottomItems: [IDEToolWindowStripeItem] { items(workspace).bottom }

    private func items(_ workspace: IDEWorkspace) -> (top: [IDEToolWindowStripeItem], bottom: [IDEToolWindowStripeItem]) {
        let (topPlacement, bottomPlacement): (IDEToolWindow.Placement, IDEToolWindow.Placement) = switch edge {
        case .leading: (.leadingTop, .leadingBottom)
        case .trailing: (.trailingTop, .trailingBottom)
        }
        let windows = workspace.toolWindows
        func stripeItems(_ placement: IDEToolWindow.Placement) -> [IDEToolWindowStripeItem] {
            windows.filter { $0.placement == placement }.map {
                IDEToolWindowStripeItem(
                    id: $0.id, systemImage: $0.systemImage, title: $0.title, isOpen: $0.isOpen, action: $0.toggle
                )
            }
        }
        return (stripeItems(topPlacement), stripeItems(bottomPlacement))
    }
}

struct IDEToolWindowStripeItem: Identifiable {
    let id: String
    let systemImage: String
    let title: String
    let isOpen: Bool
    let action: () -> Void
}

private struct IDEToolWindowStripeLegacy: View {
    let edge: IDEToolWindowStripe.Edge
    let topItems: [IDEToolWindowStripeItem]
    let bottomItems: [IDEToolWindowStripeItem]

    var body: some View {
        VStack(spacing: IDEAppearance.Spacing.xs) {
            ForEach(topItems) { IDEToolWindowStripeLegacyButton(item: $0) }
            Spacer(minLength: IDEAppearance.Spacing.sm)
            ForEach(bottomItems) { IDEToolWindowStripeLegacyButton(item: $0) }
        }
        .padding(.vertical, IDEAppearance.Spacing.sm)
        .frame(width: IDEAppearance.Spacing.toolWindowStripeWidth)
        .frame(maxHeight: .infinity)
        .background(IDEAppearance.ColorToken.frame)
        .focusable(false)
    }
}

private struct IDEToolWindowStripeButtonLabel: View {
    let item: IDEToolWindowStripeItem

    var body: some View {
        Image(systemName: item.systemImage)
            .font(.system(size: IDEAppearance.IconSize.toolWindowGlyph, weight: .regular))
            .frame(width: IDEAppearance.Spacing.toolWindowButton, height: IDEAppearance.Spacing.toolWindowButton)
            .contentShape(Rectangle())
    }
}

private struct IDEToolWindowStripeLegacyButton: View {
    let item: IDEToolWindowStripeItem

    @State private var isHovering = false

    var body: some View {
        Button(action: item.action) {
            IDEToolWindowStripeButtonLabel(item: item)
                .foregroundStyle(item.isOpen || isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(item.isOpen ? "Hide \(item.title)" : item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(item.isOpen ? [.isButton, .isSelected] : .isButton)
        .focusable(false)
    }

    @ViewBuilder
    private var background: some View {
        if item.isOpen {
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                }
        } else if isHovering {
            RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous)
                .fill(IDEAppearance.ColorToken.controlHover)
        } else {
            Color.clear
        }
    }
}

#Preview {
    HStack(spacing: 0) {
        IDEToolWindowStripe(edge: .leading)
        Color.clear
    }
    .environment(IDEWorkspace())
    .frame(width: 300, height: 480)
    .preferredColorScheme(.dark)
}
