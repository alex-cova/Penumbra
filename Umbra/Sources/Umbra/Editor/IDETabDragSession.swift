import CoreGraphics
import Foundation
import Observation

/// An editor tab being dragged: what the floating copy looks like, where the pointer is, and where
/// the tab would land if dropped now. A model of its own, like `IDEEditorPosition`, so the pointer
/// moving does not invalidate the workspace: the tab bars read `tab`, `sourcePaneID` and `target`
/// (which change when the slot does), and only the ghost reads `location`.
@MainActor
@Observable
final class IDETabDragSession {
    /// What the floating copy of the tab shows.
    struct Ghost: Equatable {
        var title: String
        var symbolName: String
        var isDirty: Bool
        /// The dragged tab's width, which is also how wide the gap it leaves is, and its height.
        var width: CGFloat
        var height: CGFloat
        /// How far below the top of its bar the tab starts.
        var top: CGFloat
    }

    private(set) var tab: UUID?
    private(set) var sourcePaneID: UUID?
    private(set) var ghost: Ghost?
    /// Where the pointer took hold of the tab, from the tab's top-left.
    private(set) var grabOffset: CGPoint = .zero
    /// The pointer, in the editor panes' space.
    private(set) var location: CGPoint = .zero
    private(set) var target: IDETabDropTarget?

    var isActive: Bool { tab != nil }

    func begin(tab: UUID, sourcePaneID: UUID, ghost: Ghost, grabOffset: CGPoint, location: CGPoint) {
        self.tab = tab
        self.sourcePaneID = sourcePaneID
        self.ghost = ghost
        self.grabOffset = grabOffset
        self.location = location
        target = nil
    }

    /// Always moves the ghost; `target` is only written when it changed, so the bars stay put
    /// while the pointer travels within one slot.
    func move(to location: CGPoint, target: IDETabDropTarget?) {
        self.location = location
        if self.target != target { self.target = target }
    }

    func end() {
        guard tab != nil else { return }
        tab = nil
        sourcePaneID = nil
        ghost = nil
        grabOffset = .zero
        target = nil
    }
}
