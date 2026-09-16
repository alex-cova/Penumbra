import Foundation

/**
 * Sets the y coordinate of external node dummies representing eastern or western hierarchical ports.
 *
 * Runs before phase 5.
 * Same-slot dependencies: LayerSizeAndGraphHeightCalculator
 */
package final class org_eclipse_elk_alg_layered_intermediate_HierarchicalPortPositionProcessor {

    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        monitor.begin("Hierarchical port position processing", 1)

        let layers = layeredGraph.getLayers()

        // We're interested in EAST and WEST external port dummies only; since they can only be in
        // the first or last layer, only fix coordinates of nodes in those two layers
        if layers.count > 0 {
            fixCoordinates(layers[0], layeredGraph)
        }

        if layers.count > 1 {
            fixCoordinates(layers[layers.count - 1], layeredGraph)
        }

        monitor.done()
    }

    /**
     * Fixes the y coordinates of external port dummies in the given layer.
     */
    private func fixCoordinates(_ layer: Layer, _ layeredGraph: LGraph) {
        let portConstraints = layeredGraph.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .FREE
        if !(portConstraints.isRatioFixed() || portConstraints.isPosFixed()) {
            // If coordinates are free to be set, we're done
            return
        }

        let graphHeight = layeredGraph.getActualSize().y

        // Iterate over the layer's nodes
        for node in layer.getNodes() {
            // We only care about external port dummies...
            if node.getType() != .externalPort {
                continue
            }

            // ...representing eastern or western ports.
            let extPortSide = node.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide
            if extPortSide != .EAST && extPortSide != .WEST {
                continue
            }

            var finalYCoordinate = node.getProperty(InternalProperties.PORT_RATIO_OR_POSITION) as? Double ?? 0.0

            if portConstraints == .FIXED_RATIO {
                // finalYCoordinate is a ratio that must be multiplied with the graph's height
                finalYCoordinate *= graphHeight
            }

            // Apply the node's new Y coordinate
            let anchorY = (node.getProperty(LayeredOptions.PORT_ANCHOR) as? KVector)?.y ?? 0.0
            node.getPosition().y = finalYCoordinate - anchorY
            node.borderToContentAreaCoordinates(false, true)
        }
    }
}
