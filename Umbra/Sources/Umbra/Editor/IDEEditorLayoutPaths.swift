import Foundation
import Penumbra

/// Where each pane sits in the editor layout, to tell a change the panes can animate through from
/// one that rebuilds them.
///
/// The chain draws a pane as the first side of the link at its index (`IDEEditorSplitChain`), so a
/// pane keeps its view while its path stays the same. Opening or closing the last pane of a
/// container does that for every other pane, and the layout animates. Opening before another pane,
/// closing one in front of another, or nesting a pane in a split of the other direction moves a
/// pane to a different place, and animating that would show it vanish and come back, so those
/// changes happen at once.
enum IDEEditorLayoutPaths {
    /// Each pane's child indices from the top of the layout. A bare pane at the top is the first
    /// child of a chain of one, as it is drawn.
    static func paths(of layout: EditorLayout) -> [UUID: [Int]] {
        var result: [UUID: [Int]] = [:]
        func walk(_ layout: EditorLayout, _ path: [Int]) {
            switch layout {
            case .pane(let pane):
                result[pane.id] = path
            case .horizontal(let data), .vertical(let data):
                for (index, child) in data.children.enumerated() {
                    walk(child, path + [index])
                }
            }
        }
        if case .pane = layout {
            walk(layout, [0])
        } else {
            walk(layout, [])
        }
        return result
    }

    /// Whether every pane in both layouts stays where it was.
    static func keepsPlaces(from before: [UUID: [Int]], to after: [UUID: [Int]]) -> Bool {
        before.allSatisfy { id, path in after[id].map { $0 == path } ?? true }
    }
}
