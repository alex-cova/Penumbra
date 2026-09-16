import Foundation

/**
 * Utility functions for reuse across different size approximators.
 */
package class TopdownSizeApproximatorUtil {

    /**
     * Dynamically calculate the multiplier to be applied for the side length of the input node based on the number
     * of children (with and without hierarchy) it and its siblings have. The distribution is mapped to a log scale,
     * which is divided into a number of categories that determine the multiplier.
     *
     * @param originalGraph the graph to obtain the category multiplier for
     * @return the sidelength multiplier according to the category i.e. Category i => 2^i
     */
    package static func getSizeCategoryMultiplier(_ originalGraph: any ElkNode) -> Double {
        guard let parent = originalGraph.parent else {
            return 1.0
        }

        let thisGraphsSize = getGraphSize(originalGraph)
        let categories = (originalGraph.getProperty(CoreOptions.TOPDOWN_SIZE_CATEGORIES) as? Int) ?? 4

        // 1. compute distribution of node sizes
        var sizeMinFound = Int.max
        var sizeMaxFound = Int.min

        for child in parent.children {
            let size = getGraphSize(child)
            sizeMaxFound = max(sizeMaxFound, size)
            sizeMinFound = min(sizeMinFound, size)
        }

        let sizeMin = 1.0
        var sizeMax = pow(4.0, Double(categories))

        // shift the range to encompass the largest graph in the local neighbourhood
        if Double(sizeMaxFound) > sizeMax {
            sizeMax = Double(sizeMaxFound)
        }

        // 2. set cutoffs at quarter percentiles on logarithmic scale
        let x = (log(sizeMax) - log(sizeMin)) / Double(categories)
        let factor = exp(x)

        // 3. assign node size according to dynamic cutoffs
        var cutoff = sizeMin * factor
        for i in 0..<categories {
            if thisGraphsSize < Int(cutoff) {
                return pow(2.0, Double(i))
            } else {
                cutoff *= factor
            }
        }
        // largest category
        return pow(2.0, Double(categories - 1))
    }

    /**
     * Returns the "size" of the graph defined as the sum of the children's weights.
     * Each simple node containing no children is counted with a weight of 1.
     * Each node with further children is counted with a weight defined in
     * `CoreOptions.TOPDOWN_SIZE_CATEGORIES_HIERARCHICAL_NODE_WEIGHT`
     * @param originalGraph the graph
     * @return the size of the graph
     */
    package static func getGraphSize(_ originalGraph: any ElkNode) -> Int {
        var sum = 0
        let hierarchicalNodeWeight = (originalGraph.getProperty(CoreOptions.TOPDOWN_SIZE_CATEGORIES_HIERARCHICAL_NODE_WEIGHT) as? Int) ?? 50

        for child in originalGraph.children {
            if !child.children.isEmpty {
                sum += hierarchicalNodeWeight
            } else {
                sum += 1
            }
        }
        return sum
    }
}
