import Foundation

/**
 * Represents a group of `CNode`s whose relative distances to each other are preserved.
 * For instance, when compacting a layered graph, CGroups are used to ensure that vertical edge segments,
 * that are connected to north/south ports, are kept at the position of the port.
 * 
 * @see HorizontalGraphCompactor
 */
package final class CGroup {
    
    // Variables are package for convenience reasons since this class is used internally only.
    /** root position of the `CGroup`. */
    package var startPos: Double = -Double.infinity
    /**
     * The field can be used to determine whether a group has moved during compaction. It has to be
     * reset externally and is updated during compaction, for instance by the
     * `LongestPathCompaction`.
     * Bear in mind that not every compaction algorithm updates this field.
     */
    package var delta: Double = 0.0
    /**
     * Similar to `delta` with the difference that it does not represent the direction-less
     * sum of a this group's movements but instead considers the compaction direction. Thus, if a
     * node moves back and forth the same distance this field's value will be zero.
     */
    package var deltaNormalized: Double = 0.0
    /** grouped `CNode`s. */
    package var cNodes: Set<CNode>
    /** constraints pointing from within the `CGroup` to CNodes outside the `CGroup`. */
    package var incomingConstraints: Set<CNode>
    /** number of constraints originating from within the `CGroup`. */
    package var outDegree: Int = 0
    /** the reference node of this group, i.e. the reference for the group offset of other nodes. */
    package var reference: CNode?
    /** An id for package use. There is no warranty, use at your own risk. */
    package var id: Int = 0
    /** flags this group to be repositioned in the case of left/right balanced compaction. */
    package var reposition: Bool = true

    /**
     * The constructor for a `CGroup` receives `CNode`s to group.
     * 
     * - Parameter inputCNodes: the `CNode`s to add
     */
    package init(_ inputCNodes: CNode...) {
        cNodes = Set<CNode>()
        incomingConstraints = Set<CNode>()
        outDegree = 0
        for cNode in inputCNodes {
            if reference == nil {
                reference = cNode
            }
            addCNode(cNode)
        }
    }

    /**
     * Adds a `CNode` to the `CGroup` and updates the incoming constraints.
     * 
     * - Parameter cNode: the `CNode` to add
     */
    package func addCNode(_ cNode: CNode) {
        cNodes.insert(cNode)
        if cNode.cGroup != nil {
            assertionFailure("CNode belongs to another CGroup.")
            return
        }
        cNode.cGroup = self
    }
    
    /**
     * Removes the passed `CNode` from this group and sets the `cNode.cGroup` field to
     * nil (if it belongs to this group).
     * 
     * - Parameter cNode: the `CNode` to remove.
     * - Returns: true if this `CGroup` actually contained the passed `CNode`, false otherwise.
     */
    package func removeCNode(_ cNode: CNode) -> Bool {
        let removed = cNodes.remove(cNode) != nil
        if removed {
            cNode.cGroup = nil
        }
        return removed
    }
}
