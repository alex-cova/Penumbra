import SwiftUI

/// The left sidebar: one card with a tab bar (the `IDESidebarTabs`: Explorer, Structure, Changes, Breakpoints, History) over the
/// selected tab's content. Which tabs exist and which one shows is `IDEWorkspace`'s
/// `sidebarTabs` / `activeSidebarTab`.
struct IDELeftSidebar: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let _ = IDEBodyDiagnostics.note("IDELeftSidebar")
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

                // The selected tab's content; the Explorer is the one mounted above.
                if active != .explorer, let descriptor = IDESidebarTabs.descriptor(for: active) {
                    descriptor.content(workspace)
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
        HStack(spacing: IDEAppearance.Spacing.xxs) {
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

            addMenu
                .disabled(workspace.reopenableSidebarTabs.isEmpty)
                .opacity(workspace.reopenableSidebarTabs.isEmpty ? IDEAppearance.Opacity.disabled : 1)
        }
        .padding(.horizontal, IDEAppearance.Spacing.xs)
        .frame(height: IDEAppearance.Spacing.tabHeight + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func badge(for tab: IDESidebarTab) -> Int {
        IDESidebarTabs.descriptor(for: tab)?.badge(workspace) ?? 0
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

    private var descriptor: IDESidebarTabDescriptor? { IDESidebarTabs.descriptor(for: tab) }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: IDEAppearance.Spacing.compact) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: descriptor?.iconSize ?? 11, weight: .medium))
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
                } else if badge > 0 {
                    // Unselected tabs still surface their count as a compact badge.
                    Text("\(badge)")
                        .font(IDEAppearance.Typography.monoSmall)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .padding(.horizontal, IDEAppearance.Spacing.xs)
                        .background(IDEAppearance.ColorToken.controlHover, in: Capsule())
                }
                if isHovering, tab.isClosable {
                    Image(systemName: "xmark")
                        .font(.system(size: IDEAppearance.IconSize.microGlyph, weight: .semibold))
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                        .onTapGesture { onClose() }
                        .help("Close Tab")
                        .accessibilityLabel("Close \(tab.title) Tab")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.horizontal, isSelected ? IDEAppearance.Spacing.sm : 6)
            .frame(minHeight: IDEAppearance.Spacing.iconButton - 2)
            .background(background, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(badge > 0 ? "\(tab.title) (\(badge))" : tab.title)
        .contextMenu {
            if tab.isClosable {
                Button("Close Tab", action: onClose)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge > 0 ? "\(tab.title), \(badge)" : tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var iconColor: Color {
        if let color = descriptor?.iconColor { return color }
        return isSelected || isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted
    }

    private var background: Color {
        if isSelected { return IDEAppearance.ColorToken.card }
        return isHovering ? IDEAppearance.ColorToken.controlHover : .clear
    }
}
