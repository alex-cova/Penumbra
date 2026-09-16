import Foundation

/**
 * Adds to each LNode the layerID and positionID that has been computed by ELK Layered.
 * <dl>
 *   <dt>Precondition:</dt>
 *      <dd>none</dd>
 *   <dt>Postcondition:</dt>
 *      <dd>Nodes have a layer and position id based on the layout.</dd>
 *   <dt>Slots:</dt>
 *      <dd>After phase 5.</dd>
 * </dl>
 */
package final class ConstraintsPostprocessor: ILayoutProcessor {

    package typealias G = LGraph

    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {

        _ = progressMonitor.begin("Constraints Postprocessor", 1)

        var layerIndex = 0

        for layer in graph.layers {
            var posIndex = 0
            var nodeLayer = false

            for currentNode in layer.nodes {
                if currentNode.type == .normal {
                    nodeLayer = true
                    currentNode.setProperty(LayeredOptions.LAYERING_LAYER_ID, layerIndex)
                    currentNode.setProperty(LayeredOptions.CROSSING_MINIMIZATION_POSITION_ID, posIndex)
                    posIndex += 1
                }
            }

            // layers with no nodes in it should not increase the layer id
            if nodeLayer {
                layerIndex += 1
            }
        }


        progressMonitor.done()
    }
}
