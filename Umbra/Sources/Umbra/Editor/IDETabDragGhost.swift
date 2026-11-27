import SwiftUI

/// The copy of a dragged tab that follows the pointer over the editor panes. Mounted over the panes
/// (`IDERootView`), so its offsets are in `IDEEditorTabsBar.panesSpace`. Its own view, so the root
/// does not read the pointer.
struct IDETabDragGhostLayer: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let session = workspace.tabDrag
        if let ghost = session.ghost {
            let origin = origin(of: ghost, in: session)
            IDETabDragGhost(ghost: ghost)
                .offset(x: origin.x, y: origin.y)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Where the pointer carries the tab, except over a tab bar where it lines up with the row, so
    /// it reads as sitting in the bar it will drop into.
    private func origin(of ghost: IDETabDragSession.Ghost, in session: IDETabDragSession) -> CGPoint {
        var origin = CGPoint(x: session.location.x - session.grabOffset.x, y: session.location.y - session.grabOffset.y)
        if let target = session.target, target.edge == nil, target.index != nil,
           let frame = workspace.editorPaneFrames[target.paneID] {
            origin.y = frame.minY + ghost.top
        }
        return origin
    }
}

private struct IDETabDragGhost: View {
    let ghost: IDETabDragSession.Ghost

    var body: some View {
        IDEChromeTabItem(
            title: ghost.title,
            isSelected: true,
            onSelect: {},
            leading: {
                Image(systemName: ghost.symbolName)
                    .font(.system(size: IDEAppearance.IconSize.smallGlyph))
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            },
            trailing: {
                ZStack {
                    if ghost.isDirty {
                        Circle()
                            .fill(IDEAppearance.ColorToken.accent)
                            .frame(width: IDEAppearance.Spacing.dirtyDotSize, height: IDEAppearance.Spacing.dirtyDotSize)
                    } else {
                        Image(systemName: "xmark")
                            .font(.system(size: IDEAppearance.IconSize.closeGlyph, weight: .bold))
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                }
                .frame(width: IDEEditorTabsBar.trailingSlotSide, height: IDEEditorTabsBar.trailingSlotSide)
            }
        )
        .frame(width: ghost.width, height: ghost.height)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}
