import Foundation

/**
 * Interface for importer classes for the layered graph structure.
 *
 * <p>Graph importers are encouraged to set the {@link LayeredOptions#GRAPH_PROPERTIES}
 * property on imported graphs.</p>
 *
 * @param T the type of graph that this importer can transform into a layered graph.
 */
package protocol IGraphTransformer {
    
    /**
     * Create a layered graph from the given graph.
     *
     * @param graph the graph to turn into a layered graph.
     * @return a layered graph, or `nil` if the input was not recognized
     */
    func importGraph(_ graph: Any) throws -> LGraph?
    
    /**
     * Apply the computed layout of the given layered graph to the original input graph.
     *
     * <dl>
     *   <dt>Precondition:</dt><dd>the graph has all its dummy nodes and edges removed;
     *     edges that were reversed during layout have been restored to their original
     *     orientation</dd>
     *   <dt>Postcondition:</dt><dd>none</dd>
     * </dl>
     *
     * @param layeredGraph a graph for which layout is applied
     */
    func applyLayout(_ layeredGraph: LGraph)
}
