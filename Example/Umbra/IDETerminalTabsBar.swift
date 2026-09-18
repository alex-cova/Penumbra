import SwiftUI

struct IDETerminalTabsBar: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(workspace.terminalTabs) { tab in
                    IDETerminalTabItem(
                        tab: tab,
                        isSelected: tab.id == workspace.selectedTerminalTabID,
                        onSelect: { workspace.selectTerminalTab(tab.id) },
                        onClose: { workspace.closeTerminalTab(tab.id) }
                    )
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
        }
        .frame(height: IDEAppearance.Spacing.tabHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IDETerminalTabItem: View {
    let tab: IDETerminalTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    private let trailingSlotSide: CGFloat = 14

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 12)

            Text(tab.title)
                .foregroundStyle(isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .font(IDEAppearance.Typography.tabLabel.weight(isSelected ? .medium : .regular))

            IDETerminalTabCloseButton(side: trailingSlotSide, onClose: onClose)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .overlay(alignment: .top) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(IDEAppearance.ColorToken.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    private var backgroundColor: Color {
        if isSelected {
            return IDEAppearance.ColorToken.tabActive
        }
        if isHovering {
            return IDEAppearance.ColorToken.tabHover
        }
        return IDEAppearance.ColorToken.tabInactive
    }
}

private struct IDETerminalTabCloseButton: View {
    let side: CGFloat
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Close Tab")
        .accessibilityAddTraits(.isButton)
    }
}
