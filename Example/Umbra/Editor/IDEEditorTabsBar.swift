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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    IDEChromeTabItem(
                        title: tab.title,
                        isSelected: tab.isSelected,
                        onSelect: { workspace.selectTab(tab.id, in: paneID) },
                        leading: {
                            Image(systemName: tab.symbolName ?? IDEFileIcon.systemName(forFilename: tab.title))
                                .font(.system(size: 10))
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
                    .contextMenu { tabMenu(for: tab) }
                }
            }
            .padding(.horizontal, IDEAppearance.Spacing.sm)
        }
        .opacity(isActivePane ? 1 : 0.55)
        .frame(height: IDEAppearance.Spacing.tabHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IDEAppearance.ColorToken.tabBar)
        .focusable(false)
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
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
}
