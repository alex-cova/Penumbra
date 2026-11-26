import CoreGraphics
import Foundation
import Penumbra

/// Where a dragged editor tab would land: in a pane's tab bar (`edge` nil), or in a new pane split off
/// the pane's `edge`.
struct IDETabDropTarget: Equatable {
    var paneID: UUID
    var edge: EditorSplitEdge?
}

/// The part of an editor pane a dragged tab is over. The same rule as the terminal panes
/// (`IDETerminalTiling.dropZone`): the outer quarter of a side is that edge, the nearest one in a
/// corner, and the rest is the middle.
enum IDEEditorTabDrop {
    enum Zone: Equatable {
        /// Over the pane's own tab bar: the tab goes into this bar (reordering, for the pane it came from).
        case tabBar
        case center
        case edge(EditorSplitEdge)
    }

    /// How far in from a side the edge zone runs, as a share of the pane's editor area.
    static let edgeShare: CGFloat = 0.25

    /// `point` and `frame` are in the same space. The tab bar is the strip along the top of the pane;
    /// the edges are measured on the editor area under it, so the top edge is not the tab bar.
    static func zone(at point: CGPoint, in frame: CGRect, tabBarHeight: CGFloat) -> Zone {
        let content = contentFrame(of: frame, tabBarHeight: tabBarHeight)
        guard frame.contains(point) else { return .center }
        guard point.y >= content.minY else { return .tabBar }
        guard content.width > 0, content.height > 0 else { return .center }
        let x = (point.x - content.minX) / content.width
        let y = (point.y - content.minY) / content.height
        let distances: [(EditorSplitEdge, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < edgeShare else { return .center }
        return .edge(nearest.0)
    }

    /// The area the new pane would take: the half of the editor area on `edge`, or the whole pane
    /// when the tab goes into its bar.
    static func highlight(for edge: EditorSplitEdge?, in frame: CGRect, tabBarHeight: CGFloat) -> CGRect {
        guard let edge else { return frame }
        let content = contentFrame(of: frame, tabBarHeight: tabBarHeight)
        switch edge {
        case .leading: return CGRect(x: content.minX, y: content.minY, width: content.width / 2, height: content.height)
        case .trailing: return CGRect(x: content.midX, y: content.minY, width: content.width / 2, height: content.height)
        case .top: return CGRect(x: content.minX, y: content.minY, width: content.width, height: content.height / 2)
        case .bottom: return CGRect(x: content.minX, y: content.midY, width: content.width, height: content.height / 2)
        }
    }

    private static func contentFrame(of frame: CGRect, tabBarHeight: CGFloat) -> CGRect {
        let bar = min(max(tabBarHeight, 0), frame.height)
        return CGRect(x: frame.minX, y: frame.minY + bar, width: frame.width, height: frame.height - bar)
    }

    /// What dropping at `point` would do for a tab dragged out of `sourcePaneID`, which holds
    /// `sourceTabCount` tabs. Nothing to do on the pane the tab came from, except an edge split of it
    /// that leaves a tab behind; a split the window has no room for is the middle of that pane instead.
    static func target(
        at point: CGPoint,
        panes: [(id: UUID, frame: CGRect)],
        from sourcePaneID: UUID,
        sourceTabCount: Int,
        tabBarHeight: CGFloat,
        canSplit: (EditorSplitEdge) -> Bool
    ) -> IDETabDropTarget? {
        guard let hit = panes.first(where: { $0.frame.contains(point) }) else { return nil }
        let isSource = hit.id == sourcePaneID
        let fallback: IDETabDropTarget? = isSource ? nil : IDETabDropTarget(paneID: hit.id, edge: nil)
        switch zone(at: point, in: hit.frame, tabBarHeight: tabBarHeight) {
        case .tabBar, .center:
            return fallback
        case .edge(let edge):
            if isSource && sourceTabCount < 2 { return nil }
            return canSplit(edge) ? IDETabDropTarget(paneID: hit.id, edge: edge) : fallback
        }
    }
}
