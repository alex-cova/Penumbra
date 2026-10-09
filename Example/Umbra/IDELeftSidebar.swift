import SwiftUI

/// The left sidebar: one card with a tab bar (Explorer, Structure, Changes, Breakpoints, History) over the
/// selected tab's content. Which tabs exist and which one shows is `IDEWorkspace`'s
/// `sidebarTabs` / `activeSidebarTab`.
struct IDELeftSidebar: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let active = workspace.activeSidebarTab
        VStack(spacing: 0) {
            IDESidebarTabBar()

            ZStack {
                // The Explorer stays mounted so its filter, scroll position and pending reveal
                // requests survive a visit to another tab.
                IDESidebarPanel()
                    .opacity(active == .explorer ? 1 : 0)
                    .allowsHitTesting(active == .explorer)
                    .accessibilityHidden(active != .explorer)

                switch active {
                case .explorer:
                    EmptyView()
                case .structure:
                    IDEStructurePanel()
                case .changes:
                    IDEChangesPanel(gitStatus: workspace.gitStatus)
                case .breakpoints:
                    IDEBreakpointsPanel()
                case .history:
                    IDELocalHistoryPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(IDEAppearance.ColorToken.panel)
    }
}

/// The selected tab shows its title; the others are icons, so four tabs fit the narrowest sidebar.
private struct IDESidebarTabBar: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let active = workspace.activeSidebarTab
        HStack(spacing: 2) {
            ForEach(workspace.sidebarTabs) { tab in
                IDESidebarTabItem(
                    tab: tab,
                    isSelected: tab == active,
                    badge: badge(for: tab),
                    onSelect: { workspace.showSidebarTab(tab) },
                    onClose: { workspace.closeSidebarTab(tab) }
                )
            }

            Spacer(minLength: 0)

            if !workspace.reopenableSidebarTabs.isEmpty {
                addMenu
            }
        }
        .padding(.horizontal, IDEAppearance.Spacing.xs)
        .frame(height: IDEAppearance.Spacing.tabHeight + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func badge(for tab: IDESidebarTab) -> Int {
        switch tab {
        case .changes: workspace.gitStatus.changes.count
        case .breakpoints: workspace.breakpoints.count
        case .explorer, .structure, .history: 0
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(workspace.reopenableSidebarTabs) { tab in
                Button {
                    workspace.showSidebarTab(tab)
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph, weight: .medium))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add Tab")
        .accessibilityLabel("Add Sidebar Tab")
    }
}

private struct IDESidebarTabItem: View {
    let tab: IDESidebarTab
    let isSelected: Bool
    let badge: Int
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.systemImage)
                // The breakpoint glyph is a dot: at the size of the other icons it reads as a blob.
                .font(.system(size: tab == .breakpoints ? 8 : 11, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 14)

            if isSelected {
                Text(tab.title)
                    .font(IDEAppearance.Typography.panelTab)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    .lineLimit(1)
                if badge > 0 {
                    Text("\(badge)")
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
        }
        .padding(.horizontal, isSelected ? IDEAppearance.Spacing.sm : 6)
        .frame(minHeight: IDEAppearance.Spacing.iconButton - 2)
        .background(background, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(badge > 0 ? "\(tab.title) (\(badge))" : tab.title)
        .contextMenu {
            if tab.isClosable {
                Button("Close Tab", action: onClose)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge > 0 ? "\(tab.title), \(badge)" : tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .focusable(false)
    }

    private var iconColor: Color {
        if tab == .breakpoints { return IDEAppearance.ColorToken.error }
        return isSelected || isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted
    }

    private var background: Color {
        if isSelected { return IDEAppearance.ColorToken.card }
        return isHovering ? IDEAppearance.ColorToken.controlHover : .clear
    }
}
