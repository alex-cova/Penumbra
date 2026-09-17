import Foundation

/// Children of a horizontal or vertical split in an ``EditorLayout`` tree.
public final class EditorSplitData: @unchecked Sendable {
    public let axis: EditorLayoutAxis
    public var children: [EditorLayout]

    public init(axis: EditorLayoutAxis, children: [EditorLayout] = []) {
        self.axis = axis
        self.children = children
    }

    /// Inserts a new pane beside the child at `index`, optionally nesting an orthogonal split.
    public func split(_ edge: EditorSplitEdge, at index: Int, new pane: EditorPane) {
        switch (axis, edge) {
        case (.horizontal, .trailing), (.vertical, .bottom):
            children.insert(.pane(pane), at: index + 1)
        case (.horizontal, .leading), (.vertical, .top):
            children.insert(.pane(pane), at: index)
        case (.horizontal, .top):
            children[index] = .vertical(EditorSplitData(axis: .vertical, children: [.pane(pane), children[index]]))
        case (.horizontal, .bottom):
            children[index] = .vertical(EditorSplitData(axis: .vertical, children: [children[index], .pane(pane)]))
        case (.vertical, .leading):
            children[index] = .horizontal(EditorSplitData(axis: .horizontal, children: [.pane(pane), children[index]]))
        case (.vertical, .trailing):
            children[index] = .horizontal(EditorSplitData(axis: .horizontal, children: [children[index], .pane(pane)]))
        }
    }

    public func closePane(with id: UUID) {
        children.removeAll { layout in
            if case .pane(let pane) = layout {
                return pane.id == id
            }
            return false
        }
    }

    public func flatten() {
        for index in children.indices {
            var child = children[index]
            child.flatten()
            children[index] = child
        }
        if children.count == 1 {
            // Caller replaces container when collapsing; nested flatten handles descendants.
        }
    }

    public func flattenedPanes() -> [EditorPane] {
        children.flatMap { $0.flattenedPanes() }
    }
}
