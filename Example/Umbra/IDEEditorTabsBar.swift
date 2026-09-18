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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    IDEEditorTabItem(tab: tab, paneID: paneID) {
                        workspace.selectTab(tab.id, in: paneID)
                    } onClose: {
                        workspace.closeTab(tab.id, in: paneID)
                    }
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
        }
        .opacity(isActivePane ? 1 : 0.55)
        .frame(height: IDEAppearance.Spacing.tabHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.tabBar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
        .focusable(false)
    }
}

private struct IDEEditorTabItem: View {
    let tab: IDETabRow
    let paneID: UUID
    let onSelect: () -> Void
    let onClose: () -> Void

    @Environment(IDEWorkspace.self) private var workspace
    @State private var isHovering = false

    /// Fixed regardless of dirty/hover state, so the tab itself never resizes as the pointer
    /// crosses it — only what's drawn inside this slot changes.
    private let trailingSlotSide: CGFloat = 14

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: IDEFileIcon.systemName(forFilename: tab.title))
                .font(.system(size: 10))
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .frame(width: 12)

            Text(tab.title)
                .foregroundStyle(tab.isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .font(IDEAppearance.Typography.tabLabel.weight(tab.isSelected ? .medium : .regular))

            IDEEditorTabCloseButton(isDirty: tab.isDirty, side: trailingSlotSide, onClose: onClose)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
        .overlay(alignment: .top) {
            if tab.isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(IDEAppearance.ColorToken.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Split Editor Right") { workspace.splitRight(in: paneID) }
            Button("Split Editor Down") { workspace.splitDown(in: paneID) }
            Divider()
            Button("Rename File…") { workspace.renameTab(tab.id, in: paneID) }
            Divider()
            Button("Close") { workspace.closeTab(tab.id, in: paneID) }
            Button("Close Other Tabs") { workspace.closeOtherTabs(tab.id, in: paneID) }
                .disabled(!hasOtherTabs)
            Button("Close Tabs to the Right") { workspace.closeTabsToRight(tab.id, in: paneID) }
                .disabled(!hasTabsToRight)
            Button("Close All") { workspace.closeAllTabs(in: paneID) }
            Divider()
            Button("Unsplit") { workspace.unsplit(from: paneID) }
                .disabled(!hasMultiplePanes)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .focusable(false)
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

    private var paneTabs: [IDETabRow] {
        workspace.tabsByPane[paneID] ?? []
    }

    private var hasOtherTabs: Bool {
        paneTabs.count > 1
    }

    private var hasTabsToRight: Bool {
        guard let index = paneTabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        return index < paneTabs.count - 1
    }

    private var hasMultiplePanes: Bool {
        workspace.tabsByPane.count > 1
    }
}

/// Always shows a close button — the dirty dot only takes over the same slot while it isn't
/// hovered, and swaps back to the "x" the moment the pointer lands on it.
private struct IDEEditorTabCloseButton: View {
    let isDirty: Bool
    let side: CGFloat
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onClose) {
            ZStack {
                if isDirty && !isHovering {
                    Circle()
                        .fill(IDEAppearance.ColorToken.accent)
                        .frame(width: 6, height: 6)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isHovering ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(isDirty ? "Close Tab (Edited)" : "Close Tab")
        .accessibilityAddTraits(.isButton)
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
        .preferredColorScheme(.dark)
}
