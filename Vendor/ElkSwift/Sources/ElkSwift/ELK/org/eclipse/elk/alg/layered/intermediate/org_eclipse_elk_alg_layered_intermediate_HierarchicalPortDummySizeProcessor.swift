import Foundation

/**
 * Sets the width of hierarchical port dummies and sets the layer alignment of North/South port dummies
 * to Center.
 *
 * Runs before phase 4.
 */
package final class org_eclipse_elk_alg_layered_intermediate_HierarchicalPortDummySizeProcessor {

    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        monitor.begin("Hierarchical port dummy size processing", 1)

        var northernDummies: [LNode] = []
        var southernDummies: [LNode] = []

        // Calculate the width difference (this assumes CENTER node alignment).
        // Ports are stacked on top of each other at the center of the node.
        // By iteratively increasing their size by twice the edgeEdge spacing between layers,
        // vertical edge segments are spaced by that amount.
        let edgeSpacing = layeredGraph.getProperty(LayeredOptions.SPACING_EDGE_EDGE_BETWEEN_LAYERS) as? Double ?? 0.0
        let delta = edgeSpacing * 2

        // Iterate through the layers
        for layer in layeredGraph.getLayers() {
            northernDummies.removeAll()
            southernDummies.removeAll()

            // Collect northern and southern hierarchical port dummies
            for node in layer.getNodes() {
                if node.getType() == .externalPort {
                    let side = node.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide

                    if side == .NORTH {
                        northernDummies.append(node)
                    } else if side == .SOUTH {
                        southernDummies.append(node)
                    }
                }
            }

            // Set widths
            setWidths(northernDummies, topDown: true, delta: delta)
            setWidths(southernDummies, topDown: false, delta: delta)
        }

        monitor.done()
    }

    /**
     * Sets the widths of the given list of nodes and sets their layer alignment properly.
     *
     * @param nodes the list of nodes.
     * @param topDown true if the nodes should widen with increasing index, false
     *                if it should be the other way round.
     * @param delta the width difference from one node to the next.
     */
    private func setWidths(_ nodes: [LNode], topDown: Bool, delta: Double) {
        var currentWidth = 0.0
        var step = delta

        if !topDown {
            // Start with the widest node, decreasing node size
            currentWidth = delta * Double(nodes.count - 1)
            step *= -1.0
        }

        for node in nodes {
            node.setProperty(LayeredOptions.ALIGNMENT, Alignment.center)
            node.getSize().x = currentWidth

            // Move eastern ports to the node's right border
            for port in node.getPorts(PortSide.EAST) {
                port.getPosition().x = currentWidth
            }

            currentWidth += step
        }
    }
}
