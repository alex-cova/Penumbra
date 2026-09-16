import Foundation

/**
 * A graph layout engine is able to perform automatic layout on a graph or parts of it.
 */
package protocol IGraphLayoutEngine {

    /**
     * Performs layout on the given layout graph.
     *
     * - Parameters:
     *   - layoutGraph: the top-level node of the graph to be laid out
     *   - progressMonitor: monitor to which progress of the layout algorithms is reported
     * - Throws:
     *   - UnsupportedGraphException: if the given graph is not supported by this algorithm
     *   - UnsupportedConfigurationException: if the layout configuration included in the graph is inconsistent or incompatible
     */
    func layout(layoutGraph: ElkNode, progressMonitor: IElkProgressMonitor) throws
}
