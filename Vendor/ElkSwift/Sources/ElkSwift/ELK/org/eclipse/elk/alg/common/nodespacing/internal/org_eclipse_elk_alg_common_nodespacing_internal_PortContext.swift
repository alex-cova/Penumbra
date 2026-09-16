import Foundation

/**
 * Data holder class to be passed around to avoid having too much state in the size calculation classes. Port contexts
 * are part of {@link NodeContext node contexts}. The position of a port calculated as part of the algorithm should
 * first be stored in {@link #portPosition} and only be applied at the end of the algorithm, if required.
 */
package final class PortContext: Hashable {

    // MARK: - Hashable

    private let id = UUID()

    package static func == (lhs: PortContext, rhs: PortContext) -> Bool {
        return lhs.id == rhs.id
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Convenience Access to Things

    /** The node the port belongs to. */
    package let parentNodeContext: NodeContext
    /** The port we calculate stuff for. */
    package let port: PortAdapter
    /** The port's position, to be modified by the algorithm and possibly applied later. */
    package let portPosition: KVector
    /** Whether the port's labels need to be placed next to the port. */
    package let labelsNextToPort: Bool

    // MARK: - Calculated Things

    /**
     * Margin around the port to assume when placing the port. If node labels are taken into consideration, this will
     * for example include the label cell. When placing the ports, this is the size the port will be assumed to have.
     */
    package var portMargin = ElkMargin()
    /** The cell we place our port labels in. */
    package var portLabelCell: LabelCell?

    // MARK: - Creation

    /**
     * Creates a new context object for the given port, fully initialized with the port's settings.
     */
    package init(_ parentNodeContext: NodeContext, _ port: PortAdapter) {
        self.parentNodeContext = parentNodeContext
        self.port = port
        self.portPosition = KVector(port.getPosition())

        let portLabelsNextToPort = parentNodeContext.portLabelsPlacement.contains(.nextToPortIfPossible)

        if parentNodeContext.portLabelsPlacement.contains(.inside) {
            if parentNodeContext.treatAsCompoundNode {
                self.labelsNextToPort = portLabelsNextToPort && !port.hasCompoundConnections()
            } else {
                self.labelsNextToPort = true
            }
        } else if parentNodeContext.portLabelsPlacement.contains(.outside) {
            if portLabelsNextToPort {
                self.labelsNextToPort = !(port.getIncomingEdges().count > 0 || port.getOutgoingEdges().count > 0)
            } else {
                self.labelsNextToPort = false
            }
        } else {
            self.labelsNextToPort = false
        }
    }

    /// Convenience initializer with named parameters
    package convenience init(nodeContext: NodeContext, port: PortAdapter) {
        self.init(nodeContext, port)
    }

    // MARK: - Application

    /**
     * Applies the port position stored in this context to the actual port.
     */
    package func applyPortPosition() {
        port.setPosition(portPosition)
    }
}
