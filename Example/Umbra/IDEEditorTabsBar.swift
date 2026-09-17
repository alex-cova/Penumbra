import SwiftUI

struct IDEEditorTabsBar: View {
    let paneID: UUID
    var leadingInset: CGFloat = 0
    /// Shows the sidebar collapse/expand affordance at the leading edge — only the top-leading
    /// pane's tab bar carries it, since that's the one adjacent to where the sidebar lives.
    var showsSidebarToggle: Bool = false
    @EnvironmentObject private var workspace: IDEWorkspace

    private var tabs: [IDETabRow] {
        workspace.tabsByPane[paneID] ?? []
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebarToggle {
                sidebarToggleButton
                    .padding(.leading, leadingInset + IDEAppearance.Spacing.xs)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        IDEEditorTabItem(tab: tab) {
                            workspace.selectTab(tab.id, in: paneID)
                        } onClose: {
                            workspace.closeTab(tab.id, in: paneID)
                        }
                    }
                }
                .padding(.leading, showsSidebarToggle ? IDEAppearance.Spacing.xs : leadingInset)
                .padding(.horizontal, IDEAppearance.Spacing.sm)
            }
        }
        .frame(height: IDEAppearance.Spacing.tabHeight)
        .background(IDEAppearance.ColorToken.tabBar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
        .focusable(false)
    }

    private var sidebarToggleButton: some View {
        Button {
            workspace.toggleSidebar()
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(workspace.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(workspace.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityAddTraits(.isButton)
    }
}

private struct IDEEditorTabItem: View {
    let tab: IDETabRow
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @State private var isCloseHovered = false

    /// Fixed regardless of dirty/hover state, so the tab itself never resizes as the pointer
    /// crosses it — only what's drawn inside this slot changes.
    private let trailingSlotSide: CGFloat = 14

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.title)
                .foregroundStyle(tab.isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .font(IDEAppearance.Typography.tabLabel.weight(tab.isSelected ? .medium : .regular))

            trailingSlot
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .focusable(false)
    }

    /// Always shows a close button — the dirty dot only takes over the same slot while it isn't
    /// hovered, and swaps back to the "x" the moment the pointer lands on it.
    private var trailingSlot: some View {
        Button(action: onClose) {
            ZStack {
                if tab.isDirty && !isCloseHovered {
                    Circle()
                        .fill(IDEAppearance.ColorToken.accent)
                        .frame(width: 6, height: 6)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isCloseHovered ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                }
            }
            .frame(width: trailingSlotSide, height: trailingSlotSide)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovered = $0 }
        .accessibilityLabel(tab.isDirty ? "Close Tab (Edited)" : "Close Tab")
        .accessibilityAddTraits(.isButton)
    }

    private var backgroundColor: Color {
        if tab.isSelected {
            return IDEAppearance.ColorToken.tabActive
        }
        if isHovering {
            return IDEAppearance.ColorToken.tabHover
        }
        return IDEAppearance.ColorToken.tabInactive
    }
}

#Preview {
    IDEEditorTabsBar(paneID: UUID())
        .environmentObject({
            let workspace = IDEWorkspace()
            let paneID = UUID()
            workspace.tabsByPane = [
                paneID: [
                    IDETabRow(id: UUID(), title: "sample.js", isDirty: true, isSelected: true),
                    IDETabRow(id: UUID(), title: "README.md", isDirty: false, isSelected: false)
                ]
            ]
            return workspace
        }())
        .preferredColorScheme(.dark)
}
