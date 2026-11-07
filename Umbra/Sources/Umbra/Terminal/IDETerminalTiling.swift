import CoreGraphics
import Foundation

/// Where the terminal panes sit in the bottom panel: a tree of splits whose leaves are shell tabs.
/// Pure value type, so the arithmetic is tested without a view.
///
/// The panel draws the leaves itself instead of through `SplitPanes`: a shell ends when its view is
/// dismantled, and `SplitPanes` takes its panes as structural content, so splitting or moving a pane
/// would remount (and kill) the shells whose place in the tree changed.
struct IDETerminalTiling: Equatable {
    enum Axis: Equatable {
        /// Children sit side by side.
        case horizontal
        /// Children are stacked.
        case vertical
    }

    /// The side of a pane a new pane is placed on.
    enum Edge: CaseIterable {
        case leading, trailing, top, bottom

        var axis: Axis {
            switch self {
            case .leading, .trailing: return .horizontal
            case .top, .bottom: return .vertical
            }
        }

        var placesBefore: Bool { self == .leading || self == .top }
    }

    indirect enum Node: Equatable {
        case pane(UUID)
        /// `fractions` is each child's share of the length along `axis`; it sums to 1.
        case split(axis: Axis, children: [Node], fractions: [Double])
    }

    /// Ready-made arrangements: halves, thirds and quarters of the panel.
    enum Preset: CaseIterable {
        case single, twoColumns, threeColumns, twoRows, threeRows, quarters

        var paneCount: Int {
            switch self {
            case .single: return 1
            case .twoColumns, .twoRows: return 2
            case .threeColumns, .threeRows: return 3
            case .quarters: return 4
            }
        }

        var title: String {
            switch self {
            case .single: return "Single Pane"
            case .twoColumns: return "2 Columns"
            case .threeColumns: return "3 Columns"
            case .twoRows: return "2 Rows"
            case .threeRows: return "3 Rows"
            case .quarters: return "2 × 2 Grid"
            }
        }
    }

    /// A draggable line between two children of one split.
    struct Divider: Equatable, Identifiable {
        /// Child indices from the root to the split holding this divider.
        var path: [Int]
        /// The divider sits between children `index` and `index + 1`.
        var index: Int
        var axis: Axis
        /// The rectangle of the split it belongs to.
        var container: CGRect
        /// Its coordinate along the split's axis.
        var position: CGFloat

        var id: String { path.map(String.init).joined(separator: ".") + "/\(index)" }
    }

    var root: Node?

    init(root: Node? = nil) {
        self.root = root
    }

    static func single(_ id: UUID) -> IDETerminalTiling {
        IDETerminalTiling(root: .pane(id))
    }

    /// `ids` laid out as `preset`, in reading order (rows left to right, top to bottom). `ids` must
    /// hold at least `preset.paneCount` tabs; extras are not placed.
    static func preset(_ preset: Preset, ids: [UUID]) -> IDETerminalTiling {
        precondition(ids.count >= preset.paneCount, "a preset needs \(preset.paneCount) tabs")
        func panes(_ range: Range<Int>) -> [Node] { range.map { .pane(ids[$0]) } }
        func even(_ axis: Axis, _ children: [Node]) -> Node {
            .split(axis: axis, children: children, fractions: Array(repeating: 1 / Double(children.count), count: children.count))
        }
        switch preset {
        case .single: return .single(ids[0])
        case .twoColumns: return IDETerminalTiling(root: even(.horizontal, panes(0..<2)))
        case .threeColumns: return IDETerminalTiling(root: even(.horizontal, panes(0..<3)))
        case .twoRows: return IDETerminalTiling(root: even(.vertical, panes(0..<2)))
        case .threeRows: return IDETerminalTiling(root: even(.vertical, panes(0..<3)))
        case .quarters:
            return IDETerminalTiling(root: even(.vertical, [even(.horizontal, panes(0..<2)), even(.horizontal, panes(2..<4))]))
        }
    }

    // MARK: Reading

    /// The panes in reading order.
    var paneIDs: [UUID] {
        var ids: [UUID] = []
        if let root { Self.collect(root, into: &ids) }
        return ids
    }

    var paneCount: Int { paneIDs.count }

    var isEmpty: Bool { root == nil }

    func contains(_ id: UUID) -> Bool { paneIDs.contains(id) }

    // MARK: Editing

    /// Takes `id` out. The split it was in gives its share to the others and disappears when one is left.
    /// Returns whether it was there.
    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        guard contains(id), let root else { return false }
        self.root = Self.removing(id, from: root)
        return true
    }

    /// Places `id`, which must not be in the tiling, on `edge` of `target`. A neighbour in a split of
    /// the same direction joins that split and the panes in it share the length evenly.
    mutating func insert(_ id: UUID, beside target: UUID, edge: Edge) {
        guard let root, !contains(id), contains(target) else { return }
        self.root = Self.inserting(id, beside: target, edge: edge, into: root)
    }

    /// Moves `id` (new or already shown) onto `edge` of `target`.
    mutating func move(_ id: UUID, beside target: UUID, edge: Edge) {
        guard id != target, contains(target) else { return }
        remove(id)
        insert(id, beside: target, edge: edge)
    }

    /// Shows `new` in the place of `old`.
    mutating func replace(_ old: UUID, with new: UUID) {
        guard contains(old), !contains(new), let root else { return }
        self.root = Self.replacing(old, with: new, in: root)
    }

    /// Exchanges the places of two panes.
    mutating func swap(_ first: UUID, _ second: UUID) {
        guard first != second, contains(first), contains(second), let root else { return }
        self.root = Self.mapping(root) { $0 == first ? second : ($0 == second ? first : $0) }
    }

    /// Drops panes whose tab is gone.
    mutating func keep(_ ids: Set<UUID>) {
        for id in paneIDs where !ids.contains(id) { remove(id) }
    }

    /// The least a pane may be given along its split's axis, in points: a column keeps room for a
    /// usable line, a row keeps its 24 pt header (when split) and some 48 pt of shell.
    static func minimumPaneLength(along axis: Axis) -> CGFloat {
        axis == .horizontal ? 120 : 72
    }

    /// `minimumPaneLength` as a fraction of `divider`'s split, so a short panel keeps the same
    /// point floor that a tall one does.
    static func minimumFraction(for divider: Divider) -> Double {
        let length = divider.axis == .horizontal ? divider.container.width : divider.container.height
        guard length > 0 else { return 0.08 }
        return Double(minimumPaneLength(along: divider.axis) / length)
    }

    /// Where `divider` sits in its split, as a fraction of the split's length.
    static func fraction(of divider: Divider) -> Double {
        let horizontal = divider.axis == .horizontal
        let origin = horizontal ? divider.container.minX : divider.container.minY
        let length = horizontal ? divider.container.width : divider.container.height
        guard length > 0 else { return 0 }
        return Double((divider.position - origin) / length)
    }

    /// Moves the divider between children `index` and `index + 1` of the split at `path` so the first
    /// `index + 1` children take `fraction` of the split, never leaving a child under `minimum`.
    /// When the pair cannot hold two minimums the boundary settles at the middle of the pair.
    mutating func moveDivider(path: [Int], index: Int, toFraction fraction: Double, minimum: Double = 0.08) {
        guard let root else { return }
        self.root = Self.updating(root, path: path[...]) { node in
            guard case .split(let axis, let children, var fractions) = node,
                  index >= 0, index + 1 < children.count else { return node }
            let before = fractions[..<index].reduce(0, +)
            let pair = fractions[index] + fractions[index + 1]
            let floor = min(minimum, pair / 2)
            let lower = before + floor
            let upper = before + pair - floor
            let boundary = min(max(fraction, lower), upper)
            fractions[index] = boundary - before
            fractions[index + 1] = pair - fractions[index]
            return .split(axis: axis, children: children, fractions: fractions)
        }
    }

    /// Gives the two children either side of a divider an even share of what they hold together.
    mutating func resetDivider(path: [Int], index: Int) {
        guard let root else { return }
        self.root = Self.updating(root, path: path[...]) { node in
            guard case .split(let axis, let children, var fractions) = node,
                  index >= 0, index + 1 < children.count else { return node }
            let pair = fractions[index] + fractions[index + 1]
            fractions[index] = pair / 2
            fractions[index + 1] = pair / 2
            return .split(axis: axis, children: children, fractions: fractions)
        }
    }

    // MARK: Geometry

    /// Each pane's rectangle in `rect`. Panes tile it exactly; the divider lines are drawn over the seams.
    func rects(in rect: CGRect) -> [UUID: CGRect] {
        arranged(in: rect).rects
    }

    func dividers(in rect: CGRect) -> [Divider] {
        arranged(in: rect).dividers
    }

    private func arranged(in rect: CGRect) -> Arrangement {
        var arrangement = Arrangement()
        if let root { Self.layout(root, in: rect, path: [], into: &arrangement) }
        return arrangement
    }

    /// The pane next to `id` in a direction, preferring the one that overlaps it most.
    func neighbor(of id: UUID, toward edge: Edge) -> UUID? {
        let all = rects(in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        guard let from = all[id] else { return nil }
        let epsilon: CGFloat = 0.5
        var best: (id: UUID, overlap: CGFloat, distance: CGFloat)?
        for (other, rect) in all where other != id {
            let distance: CGFloat
            let overlap: CGFloat
            switch edge {
            case .leading: distance = from.minX - rect.maxX
            case .trailing: distance = rect.minX - from.maxX
            case .top: distance = from.minY - rect.maxY
            case .bottom: distance = rect.minY - from.maxY
            }
            switch edge.axis {
            case .horizontal: overlap = min(from.maxY, rect.maxY) - max(from.minY, rect.minY)
            case .vertical: overlap = min(from.maxX, rect.maxX) - max(from.minX, rect.minX)
            }
            guard distance > -epsilon, overlap > epsilon else { continue }
            if best == nil || distance < best!.distance - epsilon
                || (abs(distance - best!.distance) <= epsilon && overlap > best!.overlap) {
                best = (other, overlap, distance)
            }
        }
        return best?.id
    }

    /// The part of a `size` pane a dragged tab is over: the outer quarter on a side is that edge (the
    /// nearest one in a corner), the rest is the middle.
    static func dropZone(at point: CGPoint, in size: CGSize) -> IDEBottomPanelModel.DropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let x = point.x / size.width
        let y = point.y / size.height
        let distances: [(Edge, CGFloat)] = [(.leading, x), (.trailing, 1 - x), (.top, y), (.bottom, 1 - y)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < 0.25 else { return .center }
        return .edge(nearest.0)
    }

    // MARK: Tree helpers

    private static func collect(_ node: Node, into ids: inout [UUID]) {
        switch node {
        case .pane(let id): ids.append(id)
        case .split(_, let children, _): children.forEach { collect($0, into: &ids) }
        }
    }

    private static func even(_ count: Int) -> [Double] {
        Array(repeating: 1 / Double(count), count: count)
    }

    /// A split with one child is that child, and a child split in the same direction as its parent
    /// is merged into it, so the tree never holds a split that could be flatter.
    private static func normalized(axis: Axis, children: [Node], fractions: [Double]) -> Node {
        let total = fractions.reduce(0, +)
        let scaled = total > 0 ? fractions.map { $0 / total } : even(children.count)
        guard children.count > 1 else { return children[0] }
        var flatChildren: [Node] = []
        var flatFractions: [Double] = []
        for (child, fraction) in zip(children, scaled) {
            if case .split(let childAxis, let grandChildren, let grandFractions) = child, childAxis == axis {
                flatChildren += grandChildren
                flatFractions += grandFractions.map { $0 * fraction }
            } else {
                flatChildren.append(child)
                flatFractions.append(fraction)
            }
        }
        return .split(axis: axis, children: flatChildren, fractions: flatFractions)
    }

    private static func removing(_ id: UUID, from node: Node) -> Node? {
        switch node {
        case .pane(let pane):
            return pane == id ? nil : node
        case .split(let axis, let children, let fractions):
            var keptChildren: [Node] = []
            var keptFractions: [Double] = []
            for (child, fraction) in zip(children, fractions) {
                if let kept = removing(id, from: child) {
                    keptChildren.append(kept)
                    keptFractions.append(fraction)
                }
            }
            guard !keptChildren.isEmpty else { return nil }
            return normalized(axis: axis, children: keptChildren, fractions: keptFractions)
        }
    }

    private static func inserting(_ id: UUID, beside target: UUID, edge: Edge, into node: Node) -> Node {
        switch node {
        case .pane(let pane):
            guard pane == target else { return node }
            let children: [Node] = edge.placesBefore ? [.pane(id), node] : [node, .pane(id)]
            return .split(axis: edge.axis, children: children, fractions: even(2))
        case .split(let axis, var children, let fractions):
            if axis == edge.axis, let index = children.firstIndex(of: .pane(target)) {
                children.insert(.pane(id), at: edge.placesBefore ? index : index + 1)
                return .split(axis: axis, children: children, fractions: even(children.count))
            }
            return .split(
                axis: axis,
                children: children.map { inserting(id, beside: target, edge: edge, into: $0) },
                fractions: fractions)
        }
    }

    private static func replacing(_ old: UUID, with new: UUID, in node: Node) -> Node {
        mapping(node) { $0 == old ? new : $0 }
    }

    private static func mapping(_ node: Node, _ transform: (UUID) -> UUID) -> Node {
        switch node {
        case .pane(let id): return .pane(transform(id))
        case .split(let axis, let children, let fractions):
            return .split(axis: axis, children: children.map { mapping($0, transform) }, fractions: fractions)
        }
    }

    private static func updating(_ node: Node, path: ArraySlice<Int>, _ change: (Node) -> Node) -> Node {
        guard let next = path.first else { return change(node) }
        guard case .split(let axis, var children, let fractions) = node, children.indices.contains(next) else { return node }
        children[next] = updating(children[next], path: path.dropFirst(), change)
        return .split(axis: axis, children: children, fractions: fractions)
    }

    private struct Arrangement {
        var rects: [UUID: CGRect] = [:]
        var dividers: [Divider] = []
    }

    private static func layout(_ node: Node, in rect: CGRect, path: [Int], into arrangement: inout Arrangement) {
        switch node {
        case .pane(let id):
            arrangement.rects[id] = rect
        case .split(let axis, let children, let fractions):
            let length = axis == .horizontal ? rect.width : rect.height
            var offset: CGFloat = 0
            for index in children.indices {
                let isLast = index == children.count - 1
                let childLength = isLast ? length - offset : (length * fractions[index]).rounded()
                let childRect = axis == .horizontal
                    ? CGRect(x: rect.minX + offset, y: rect.minY, width: childLength, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: childLength)
                layout(children[index], in: childRect, path: path + [index], into: &arrangement)
                offset += childLength
                if !isLast {
                    let position = (axis == .horizontal ? rect.minX : rect.minY) + offset
                    arrangement.dividers.append(
                        Divider(path: path, index: index, axis: axis, container: rect, position: position))
                }
            }
        }
    }
}
