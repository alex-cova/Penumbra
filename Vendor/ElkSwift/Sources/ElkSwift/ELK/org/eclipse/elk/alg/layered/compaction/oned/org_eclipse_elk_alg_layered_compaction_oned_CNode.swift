/*******************************************************************************
 * Copyright (c) 2016 Kiel University and others.
 * 
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

import Foundation

/**
 * Internal representation of a node in the constraint graph.
 * 
 * For instance, this class is extended to handle specific
 * `LGraphElement`s.
 * 
 * @see CLNode
 * @see CLEdge
 */
package class CNode: Hashable {

    package static func == (lhs: CNode, rhs: CNode) -> Bool { lhs === rhs }
    package func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    
    // Variables are package for convenience reasons since this class is used internally only.
    
    /// containing `CGroup`.
    package weak var cGroup: CGroup?
    
    /// refers to the parent node of a north/south segment.
    package var parentNode: CNode? = nil
    
    /// representation of constraints.
    package var constraints: [CNode] = []
    
    /// the area occupied by this element including margins for ports and labels.
    package var hitbox: ElkRectangle
    
    /// offset to the root position of the containing `CGroup`.
    package var cGroupOffset = KVector()
    
    /// leftmost possible position for this `CNode` to be drawn. 
    /// This position can be intermediate and is increased to its final value by updateStartPos().
    package var startPos: Double = -Double.infinity
    
    /// flags a `CNode` to be repositioned in the case of left/right balanced compaction.
    package var reposition: Bool = true
    
    /// a 4-tuple stating if the `CNode` should locked in a particular direction based on
    /// conditions defined in an extended class.
    package var lock = Quadruplet()
    
    /// Whether no spacing should be applied to a certain side of this node.
    package var spacingIgnore = Quadruplet()
    
    /// An id for package use. There is no warranty, use at your own risk.
    package var id: Int = 0
    
    package init(hitbox: ElkRectangle) {
        self.hitbox = hitbox
    }
    
    /**
     * Returns the required horizontal spacing to the specified `CNode`.
     * 
     * @return the spacing
     */
    package func getHorizontalSpacing() -> Double { assertionFailure("Subclass must override"); return 0 }
    
    /**
     * Returns the required vertical spacing to the specified `CNode`.
     * 
     * @return the spacing
     */
    package func getVerticalSpacing() -> Double { assertionFailure("Subclass must override"); return 0 }
    
    /**
     * Getter for the position.
     * 
     * @return position of the hitbox
     */
    package func getPosition() -> Double {
        return hitbox.x
    }
    
    /**
     * Applies the compacted starting position to the hitbox. Used after compaction to allow
     * reverse transformation of hitboxes.
     */
    package func applyPosition() {
        hitbox.x = startPos
    }
    
    /**
     * Sets the position of the `LGraphElement` according to the hitbox.
     */
    package func applyElementPosition() { assertionFailure("Subclass must override") }
    
    /**
     * Returns the position of the `LGraphElement`.
     * 
     * @return the position
     */
    package func getElementPosition() -> Double { assertionFailure("Subclass must override"); return 0 }
    
    /**
     * @return an svg representation of this `CNode` to the output for debugging.
     */
    func getDebugSVG() -> String {
        var sb = ""
        sb += "<rect x=\"\(hitbox.x)\" y=\"\(hitbox.y)\" width=\""
        sb += "\(max(1, hitbox.width))\" height=\"\(max(1, hitbox.height))\" fill=\""
        sb += "\(reposition ? "green" : "orange")"
        sb += "\" stroke=\"black\" opacity=\"0.5\"/>"
        sb += "<text x=\"\(hitbox.x + 2)\" y=\""
        sb += "\(hitbox.y + 2 * 2 * 2 + 2 + 1)\">"
        sb += "(\(Int(round(hitbox.x))), \(Int(round(hitbox.y))))\\n\(self)</text>"
        return sb
    }
}
