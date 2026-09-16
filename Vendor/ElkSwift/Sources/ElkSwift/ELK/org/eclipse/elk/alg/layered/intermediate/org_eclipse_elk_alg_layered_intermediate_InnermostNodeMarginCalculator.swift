import Foundation

/// Computes and sets the inner node margins.
///
/// Node margins are the space around a node that must not overlap with other diagram elements.
/// This processor only computes the space required for ports and port labels.
/// The margins are extended by SelfLoopRouter, CommentNodeMarginCalculator, and EndLabelPreprocessor.
package final class org_eclipse_elk_alg_layered_intermediate_InnermostNodeMarginCalculator {
    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        monitor.begin("Node margin calculation", 1)

        // Calculate the margins using ELK's utility methods
        NodeDimensionCalculation.getNodeMarginCalculator(LGraphAdapters.adapt(layeredGraph, transparentNorthSouthEdges: false))
            .excludeEdgeHeadTailLabels()
            .process()

        monitor.done()
    }
}
