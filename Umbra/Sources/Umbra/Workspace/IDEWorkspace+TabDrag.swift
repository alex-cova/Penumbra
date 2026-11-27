import CoreGraphics
import Foundation
import Penumbra
import SwiftUI

/// Dragging an editor tab: the pointer comes from `IDETabDragTracker`, the bars draw the gap from
/// `tabDrag.target`, and the drop lands here. Points are in the editor panes' space
/// (`IDEEditorTabsBar.panesSpace`).
extension IDEWorkspace {
    /// What dropping a tab dragged out of `paneID` at a point in the editor panes' space would do.
    /// Frames of panes that have since closed are ignored. Over a tab bar the place in it comes from
    /// the dragged tab's centre (where the pointer took hold of it), not from the pointer itself.
    func tabDropTarget(at point: CGPoint, from paneID: UUID) -> IDETabDropTarget? {
        guard let source = workbench.layout.findPane(id: paneID) else { return nil }
        let frames = editorPaneFrames.compactMap { entry in
            workbench.layout.findPane(id: entry.key) != nil ? (id: entry.key, frame: entry.value) : nil
        }
        let dragged = tabDrag.tab
        let centerX = point.x - tabDrag.grabOffset.x + (tabDrag.ghost?.width ?? 0) / 2
        return IDEEditorTabDrop.target(
            at: point,
            panes: frames,
            from: paneID,
            sourceTabCount: source.documents.count,
            tabBarHeight: IDEAppearance.Spacing.tabHeight,
            canSplit: { canSplitActivePane(along: $0) },
            insertionIndex: { id in
                tabBarGeometry[id].map {
                    $0.layout.insertionIndex(forCenterX: centerX - $0.origin.x, excluding: dragged)
                }
            }
        )
    }

    /// Starts dragging `documentID` out of `paneID`, which the pointer took hold of `grabOffset` in.
    func beginTabDrag(_ documentID: UUID, in paneID: UUID, ghost: IDETabDragSession.Ghost, grabOffset: CGPoint, at point: CGPoint) {
        selectTab(documentID, in: paneID)
        tabDrag.begin(tab: documentID, sourcePaneID: paneID, ghost: ghost, grabOffset: grabOffset, location: point)
        retargetTabDrag(at: point)
    }

    /// The pointer moved to `point`.
    func updateTabDrag(to point: CGPoint) {
        retargetTabDrag(at: point)
    }

    /// Works the target out again, for a pointer that has not moved but whose bar has (the row
    /// autoscrolled, a tab changed width).
    func retargetTabDrag() {
        guard tabDrag.isActive else { return }
        retargetTabDrag(at: tabDrag.location)
    }

    private func retargetTabDrag(at point: CGPoint) {
        guard let source = tabDrag.sourcePaneID else { return }
        tabDrag.move(to: point, target: tabDropTarget(at: point, from: source))
    }

    /// The pointer was released: the tab goes where the gap is, or stays where it was.
    func dropDraggedTab() {
        guard let id = tabDrag.tab, let source = tabDrag.sourcePaneID else { return }
        let target = tabDrag.target
        guard let target else {
            cancelTabDrag()
            return
        }
        if let edge = target.edge {
            tabDrag.end()
            moveTab(id, from: source, toNewPaneAt: edge, of: target.paneID)
        } else if target.paneID == source {
            // The bar and the order change together, so the tabs settle into the order they showed.
            IDEAppearance.Motion.animate(Self.tabReorderAnimation) {
                tabDrag.end()
                if let index = target.index { reorderTab(id, in: source, to: index) }
            }
        } else {
            tabDrag.end()
            moveTab(id, from: source, toPane: target.paneID, at: target.index)
        }
    }

    /// Esc, or the bar went away mid-drag: nothing moves, the tabs settle back.
    func cancelTabDrag() {
        guard tabDrag.isActive else { return }
        IDEAppearance.Motion.animate(Self.tabReorderAnimation) { tabDrag.end() }
    }

    static let tabReorderAnimation = Animation.snappy(duration: 0.2)
}
