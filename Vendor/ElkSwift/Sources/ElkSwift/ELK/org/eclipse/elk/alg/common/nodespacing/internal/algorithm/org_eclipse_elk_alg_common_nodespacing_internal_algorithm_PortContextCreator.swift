import Foundation

/**
 * Creates port context objects and assigns volatile IDs to all ports.
 */
package final class PortContextCreator {

    private init() {}

    /**
     * Creates and initializes port context objects for each of the node's ports.
     */
    package static func createPortContexts(_ nodeContext: NodeContext, ignoreInsidePortLabels: Bool) {
        let imPortLabels = !ignoreInsidePortLabels || !nodeContext.portLabelsPlacement.contains(.inside)

        var volatileId = 0
        for port in nodeContext.node.getPorts() {
            guard port.getSide() != .UNDEFINED else {
                assertionFailure("Label and node size calculator can only be used with ports that have port sides assigned.")
                continue
            }

            port.setVolatileId(volatileId)
            volatileId += 1

            createPortContext(nodeContext, port, imPortLabels)
        }
    }

    /**
     * Creates a port context for the given adapter and initializes it properly.
     */
    package static func createPortContext(_ nodeContext: NodeContext, _ port: PortAdapter, _ imPortLabels: Bool) {
        let portContext = PortContext(nodeContext, port)
        let side = port.getSide()
        nodeContext.portContexts.put(side, portContext)

        // If the port has labels and if port labels are to be placed, we need to remember them
        if imPortLabels && !PortLabelPlacement.isFixed(nodeContext.portLabelsPlacement) {
            portContext.portLabelCell = LabelCell(gap: nodeContext.labelLabelSpacing)
            for label in port.getLabels() {
                portContext.portLabelCell?.addLabel(label)
            }
        }
    }
}
