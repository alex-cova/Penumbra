import Foundation

package class org_eclipse_elk_alg_layered_intermediate_compaction_HorizontalGraphCompactor {
    package init() {}

    package func process(_ layeredGraph: LGraph, _ progressMonitor: IElkProgressMonitor) {
        let strategy = layeredGraph.getProperty(LayeredOptions.COMPACTION_POST_COMPACTION_STRATEGY)
            as? GraphCompactionStrategy ?? .NONE
        if strategy == .NONE {
            return
        }

        // Full compaction requires OneDimensionalCompactor, LGraphToCGraphTransformer, etc.
        // which are not yet transpiled. For now, only the NONE early-exit is functional.
        _ = progressMonitor.begin("Horizontal Compaction", 1)
        progressMonitor.done()
    }
}
