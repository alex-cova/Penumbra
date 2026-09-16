import Foundation

/**
 * A data holder used to pass information on hierarchy crossing edges from the
 * CompoundGraphPreprocessor to the CompoundGraphPostprocessor.
 * Instances of this class are held in a multimap attached to the top-level graph via the
 * CROSS_HIERARCHY_MAP property.
 */
package class CrossHierarchyEdge {

    /** the edge used in the layered graph to compute a layout. */
    package var newEdge: LEdge
    /** the layered graph in which the layout was computed. */
    package var graph: LGraph
    /** the flow direction: input or output. */
    package var type: PortType

    /**
     * Create a cross-hierarchy edge segment.
     *
     * @param newEdge the edge used in the layered graph to compute a layout
     * @param graph the layered graph in which the layout is computed
     * @param type the flow direction: input or output
     */
    package init(_ newEdge: LEdge, _ graph: LGraph, _ type: PortType) {
        self.newEdge = newEdge
        self.graph = graph
        self.type = type
    }

    var description: String {
        return "\(type):\(newEdge)"
    }

    /**
     * Return the dummy edge used to compute a layout in one segment of the cross-hierarchy edge.
     *
     * @return the dummy edge
     */
    package func getEdge() -> LEdge {
        return newEdge
    }

    /**
     * Return the graph in which the dummy edge getEdge() is used.
     *
     * @return the graph in which the dummy edge is used
     */
    package func getGraph() -> LGraph {
        return graph
    }

    /**
     * Return the type of cross-hierarchy edge segment (input or output). An input segment is one
     * that points to deeper hierarchy levels, while an output segment is one that points to
     * shallower hierarchy levels.
     *
     * @return the edge segment type
     */
    package func getType() -> PortType {
        return type
    }

    /**
     * Return the actual source port of the edge. In case the source port of the dummy edge is
     * an external port, the corresponding port of the containing node is returned.
     *
     * @return the actual source port
     */
    package func getActualSource() -> LPort {
        guard let src = newEdge.source else { return LPort() }
        if src.node?.type == NodeType.EXTERNAL_PORT,
           let port = src.node?.getProperty(InternalProperties.ORIGIN) as? LPort {
            return port
        }
        return src
    }

    /**
     * Return the actual target port of the edge. In case the target port of the dummy edge is
     * an external port, the corresponding port of the containing node is returned.
     *
     * @return the actual target port
     */
    package func getActualTarget() -> LPort {
        guard let tgt = newEdge.target else { return LPort() }
        if tgt.node?.type == NodeType.EXTERNAL_PORT,
           let port = tgt.node?.getProperty(InternalProperties.ORIGIN) as? LPort {
            return port
        }
        return tgt
    }

}
