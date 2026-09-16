import Foundation

/**
 * Internal representation of a constraint graph.
 * The `LGraphToCGraphTransformer` returns a `CGraph` to be compacted by the
 * `OneDimensionalCompactor`.
 */
package final class CGraph {
    // Variables are package for convenience reasons since this class is used internally only.
    /// the list of `CNode`s modeling the constraints in this graph.
    package var cNodes: [CNode] = []
    /// groups of elements that are supposed to stay in the configuration they are.
    package var cGroups: [CGroup] = []
    /// the directions that are supported for compaction.
    package let supportedDirections: Set<Direction>
    
    /**
     * Constructor sets the supported directions.
     *
     * - Parameter supportedDirections: the directions that are supported for compaction
     */
    package init(_ supportedDirections: Set<Direction>) {
        self.supportedDirections = supportedDirections
    }
    
    /**
     * Checks whether the `CGraph` supports compaction in the direction specified by the parameter.
     *
     * - Parameter direction: the direction to check
     * - Returns: `true` if compaction is supported, `false` otherwise
     */
    package func supports(_ direction: Direction) -> Bool {
        return supportedDirections.contains(direction)
    }
}
