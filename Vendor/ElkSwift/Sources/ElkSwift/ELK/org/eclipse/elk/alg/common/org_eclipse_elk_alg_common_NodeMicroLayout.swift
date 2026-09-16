import Foundation

/**
 * Utility class to execute "node micro layout" - automatically computing node
 * dimensions, positioning ports, positioning labels, etc.
 */
package final class NodeMicroLayout {

    package let adapter: any GraphAdapter

    private init(_ adapter: any GraphAdapter) {
        self.adapter = adapter
    }

    /**
     * @return a new micro layout instance for the passed graph.
     */
    package static func forGraph(_ elkGraph: ElkNode) -> NodeMicroLayout? {
        guard let adapted = ElkGraphAdapters.adapt(elkGraph) else {
            return nil
        }
        return forGraph(adapted)
    }

    /**
     * @return a new micro layout instance for the passed adapter.
     */
    package static func forGraph(_ adapter: any GraphAdapter) -> NodeMicroLayout {
        return NodeMicroLayout(adapter)
    }

    /**
     * Perform the actual layout.
     */
    package func execute() {
        NodeDimensionCalculation.sortPortLists(adapter)
        NodeDimensionCalculation.calculateLabelAndNodeSizes(adapter)
        NodeDimensionCalculation.calculateNodeMargins(adapter)
    }
}
