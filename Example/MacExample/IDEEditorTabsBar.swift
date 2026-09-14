import SwiftUI

struct IDEEditorTabsBar: View {
    let paneID: UUID
    var leadingInset: CGFloat = 0
    @EnvironmentObject private var workspace: IDEWorkspace

    private var tabs: [IDETabRow] {
        workspace.tabsByPane[paneID] ?? []
    }

    var body: some View {
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
            .padding(.leading, leadingInset)
            .padding(.horizontal, IDEAppearance.Spacing.sm)
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
}

private struct IDEEditorTabItem: View {
    let tab: IDETabRow
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.title)
                .foregroundStyle(tab.isSelected ? IDEAppearance.ColorToken.foreground : IDEAppearance.ColorToken.muted)
                .lineLimit(1)
                .font(.system(size: 12, weight: tab.isSelected ? .medium : .regular))

            if isHovering {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded { onClose() })
                    .accessibilityLabel("Close Tab")
                    .accessibilityAddTraits(.isButton)
            } else if tab.isDirty {
                Circle()
                    .fill(IDEAppearance.ColorToken.accent)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Edited")
            } else {
                Color.clear.frame(width: 6, height: 6)
            }
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
