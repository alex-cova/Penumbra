import Foundation

/// Typed wrapper around `TreeMultimap<PortSide, PortContext>` matching Java's
/// `NodeContext.portContexts` field — a `TreeMultimap` with `comparePortSides`
/// as key comparator and `comparePortContexts` as value comparator.
///
/// Sort order per Java's `NodeContext.comparePortContexts`:
/// - NORTH/EAST: ascending volatile ID (top-to-bottom / left-to-right)
/// - SOUTH/WEST: descending volatile ID (visually still top-to-bottom / left-to-right)
package struct PortContextMultimap: Sequence {

    private var tree = TreeMultimap<PortSide, PortContext>(
        keyComparator: { $0.ordinal < $1.ordinal },
        valueComparator: { lhs, rhs in
            let sideCmp = lhs.port.getSide().ordinal - rhs.port.getSide().ordinal
            if sideCmp != 0 { return sideCmp < 0 }
            switch lhs.port.getSide() {
            case .NORTH, .EAST:
                return lhs.port.getVolatileId() < rhs.port.getVolatileId()
            case .SOUTH, .WEST:
                return lhs.port.getVolatileId() > rhs.port.getVolatileId()
            default:
                return false
            }
        }
    )

    package init() {}

    /// Insert a port context, maintaining sorted order.
    package mutating func put(_ side: PortSide, _ portContext: PortContext) {
        tree.put(side, portContext)
    }

    /// Read-only subscript matching `[PortSide]` dictionary access.
    package subscript(_ side: PortSide) -> [PortContext]? {
        tree[side]
    }

    /// All port context arrays (one per side), for iterating all ports.
    /// Used by `NodeLabelAndSizeUtilities` via `portContexts.values`.
    package var values: [[PortContext]] {
        tree.sortedKeys.compactMap { tree[$0] }
    }

    /// Sequence conformance — iterates as `(PortSide, [PortContext])` pairs.
    package func makeIterator() -> IndexingIterator<[(PortSide, [PortContext])]> {
        tree.makeIterator()
    }
}
