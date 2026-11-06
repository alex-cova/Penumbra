import SwiftUI

struct IDEEditorTabsBar: View {
    let paneID: UUID
    @Environment(IDEWorkspace.self) private var workspace

    private var tabs: [IDETabRow] {
        workspace.tabsByPane[paneID] ?? []
    }

    private var isActivePane: Bool {
        workspace.activePaneID == paneID
    }

    /// Fixed regardless of dirty/hover state, so the tab itself never resizes as the pointer
    /// crosses it — only what's drawn inside this slot changes.
    private let trailingSlotSide: CGFloat = 14

    @State private var barWidth: CGFloat = 0
    @State private var tabsWidth: CGFloat = 0

    private var selectedTabID: UUID? {
        tabs.first(where: \.isSelected)?.id
    }

    /// The strip is wider than the pane. Measured against the whole bar, not the scroll view, so
    /// showing the overflow menu cannot change the answer.
    private var isOverflowing: Bool {
        tabsWidth > barWidth + 1
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        ForEach(tabs) { tab in
                            IDEChromeTabItem(
                                title: tab.title,
                                isSelected: tab.isSelected,
                                isDimmed: !isActivePane,
                                onSelect: { workspace.selectTab(tab.id, in: paneID) },
                                leading: {
                                    Image(systemName: tab.symbolName ?? IDEFileIcon.systemName(forFilename: tab.title))
                                        .font(.system(size: IDEAppearance.IconSize.smallGlyph))
                                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                                },
                                trailing: {
                                    IDEEditorTabCloseButton(
                                        isDirty: tab.isDirty && workspace.preferences.markModifiedTabs,
                                        side: trailingSlotSide,
                                        onClose: { workspace.requestCloseTab(tab.id, in: paneID) }
                                    )
                                }
                            )
                            .id(tab.id)
                            .contextMenu { tabMenu(for: tab) }
                        }
                    }
                    .padding(.horizontal, IDEAppearance.Spacing.sm)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabsWidth = $0 }
                }
                // A tab chosen from the menu, a keyboard shortcut or a file opened elsewhere must
                // not stay out of sight.
                .onChange(of: selectedTabID) { _, id in
                    guard let id else { return }
                    IDEAppearance.Motion.animate(IDEAppearance.Motion.standard) { proxy.scrollTo(id) }
                }
                .onAppear {
                    if let id = selectedTabID { proxy.scrollTo(id) }
                }
            }

            if isOverflowing {
                overflowMenu
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
        .frame(height: IDEAppearance.Spacing.tabHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.tabBar)
        .focusable(false)
    }

    /// Every tab of the pane in one list, for the ones scrolled out of view.
    private var overflowMenu: some View {
        Menu {
            ForEach(tabs) { tab in
                Button {
                    workspace.selectTab(tab.id, in: paneID)
                } label: {
                    let title = tab.isDirty && workspace.preferences.markModifiedTabs ? "\(tab.title) •" : tab.title
                    if tab.isSelected {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: IDEAppearance.IconSize.toolbarGlyph - 2, weight: .semibold))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: IDEAppearance.Spacing.iconButton, height: IDEAppearance.Spacing.iconButton)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.trailing, IDEAppearance.Spacing.xs)
        .help("Show All Tabs")
        .accessibilityLabel("Show All Tabs")
    }

    @ViewBuilder
    private func tabMenu(for tab: IDETabRow) -> some View {
        Button("Split Editor Right") { workspace.splitRight(in: paneID) }
        Button("Split Editor Down") { workspace.splitDown(in: paneID) }
        Divider()
        Button("Rename File…") { workspace.renameTab(tab.id, in: paneID) }
        if let document = workspace.workbench.panes.flatMap(\.documents).first(where: { $0.id == tab.id }),
           let url = document.url {
            if document.contentKind == .text {
                Button("Reload from Disk") { workspace.reloadTabFromDisk(tab.id, in: paneID) }
                Button("Reopen as Hex") { workspace.reopenDocumentAsHex(tab.id) }
            }
            if document.contentKind == .binary {
                Button("Reload from Disk") { workspace.reloadTabFromDisk(tab.id, in: paneID) }
                Button("Reopen as Text") { workspace.reopenDocumentAsText(tab.id) }
            }
            Button("Show History") { workspace.showLocalHistory(for: url) }
        }
        Divider()
        Button("Close") { workspace.requestCloseTab(tab.id, in: paneID) }
        Button("Close Other Tabs") { workspace.requestCloseOtherTabs(tab.id, in: paneID) }
            .disabled(!hasOtherTabs)
        Button("Close Tabs to the Right") { workspace.requestCloseTabsToRight(tab.id, in: paneID) }
            .disabled(!hasTabsToRight(tab))
        Button("Close All") { workspace.requestCloseAllTabs(in: paneID) }
        Divider()
        Button("Unsplit") { workspace.unsplit(from: paneID) }
            .disabled(!hasMultiplePanes)
    }

    private var hasOtherTabs: Bool {
        tabs.count > 1
    }

    private func hasTabsToRight(_ tab: IDETabRow) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        return index < tabs.count - 1
    }

    private var hasMultiplePanes: Bool {
        workspace.tabsByPane.count > 1
    }
}

/// Always shows a close button. A dirty tab shows its dot in the slot until the pointer is over
/// it; then the × takes the slot and the dot moves to its corner, so "unsaved" never disappears.
private struct IDEEditorTabCloseButton: View {
    let isDirty: Bool
    let side: CGFloat
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onClose) {
            ZStack {
                if isDirty && !isHovering {
                    dot
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: IDEAppearance.IconSize.closeGlyph, weight: .bold))
                        .foregroundStyle(isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                }
            }
            .frame(width: side, height: side)
            .overlay(alignment: .topTrailing) {
                if isDirty && isHovering {
                    dot.offset(x: IDEAppearance.Spacing.xxs, y: -IDEAppearance.Spacing.xxs)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isDirty ? "Close (unsaved changes)" : "Close")
        .accessibilityLabel(isDirty ? "Close Tab (Edited)" : "Close Tab")
        .accessibilityAddTraits(.isButton)
    }

    private var dot: some View {
        Circle()
            .fill(IDEAppearance.ColorToken.accent)
            .frame(width: IDEAppearance.Spacing.dirtyDotSize, height: IDEAppearance.Spacing.dirtyDotSize)
    }
}

#Preview {
    IDEEditorTabsBar(paneID: UUID())
        .environment({
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
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
}
