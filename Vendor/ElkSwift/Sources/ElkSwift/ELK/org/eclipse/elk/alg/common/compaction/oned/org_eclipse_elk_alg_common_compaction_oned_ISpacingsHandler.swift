/**
 * An implementation of this protocol is able to report both the vertical and the horizontal spacing
 * between any pair of `CNode`s. Different implementations of `CNode`s may have
 * different special requirements. In such a case a special spacings handler should be implemented.
 * For a default implementation, use the `DEFAULT_SPACING_HANDLER`. It returns for either spacing
 * the maximum of the two spacings returned by the nodes (e.g. `CNode.getVerticalSpacing()`).
 */
package protocol ISpacingsHandler {
    
    /**
     * Returns the horizontal spacing that should be preserved between the two passed nodes.
     *
     * - Parameters:
     *   - cNode1: the first involved node.
     *   - cNode2: the second involved node.
     * - Returns: the horizontal spacing that should be preserved between the two passed nodes.
     */
    func getHorizontalSpacing(_ cNode1: CNode, _ cNode2: CNode) -> Double
    
    /**
     * Returns the vertical spacing that should be preserved between the two passed nodes.
     *
     * - Parameters:
     *   - cNode1: the first involved node.
     *   - cNode2: the second involved node.
     * - Returns: the vertical spacing that should be preserved between the two passed nodes.
     */
    func getVerticalSpacing(_ cNode1: CNode, _ cNode2: CNode) -> Double
}

extension ISpacingsHandler {
    /**
     * A default implementation, returning **no** spacing in either direction.
     */
    package static var DEFAULT_SPACING_HANDLER: ISpacingsHandler {
        return DefaultSpacingsHandler()
    }
}

package class DefaultSpacingsHandler: ISpacingsHandler {
    package func getHorizontalSpacing(_ cNode1: CNode, _ cNode2: CNode) -> Double {
        return 0.0
    }
    
    package func getVerticalSpacing(_ cNode1: CNode, _ cNode2: CNode) -> Double {
        return 0.0
    }
}
