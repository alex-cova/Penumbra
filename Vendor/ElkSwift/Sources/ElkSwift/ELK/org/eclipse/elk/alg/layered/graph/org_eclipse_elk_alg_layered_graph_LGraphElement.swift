import Foundation

/**
 * Abstract superclass for the layers, nodes, ports, and edges of a layered graph.
 */
package class LGraphElement: MapPropertyHolder, Hashable {

    package static func == (lhs: LGraphElement, rhs: LGraphElement) -> Bool { lhs === rhs }
    package func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    /** Identifier value, may be arbitrarily used by algorithms. */
    package var id: Int = 0

    /**
     * Returns a string that is useful to identify the element while debugging.
     */
    package func getDesignation() -> String? {
        return nil
    }
}
