import Foundation

/**
 * Data holder class to be passed around to avoid having too much state in the size calculation classes.
 */
package final class NodeContext {

    // MARK: - Convenience Access to Things

    /** The node we calculate stuff for. */
    package let node: NodeAdapter
    /** The node's size. */
    package let nodeSize: KVector
    /** Whether this node has stuff inside it or not. */
    package let treatAsCompoundNode: Bool
    /** The node's size constraints. */
    package let sizeConstraints: SizeConstraint
    /** The node's size options. */
    package let sizeOptions: SizeOptions
    /** Port constraints set on the node. */
    package let portConstraints: PortConstraints
    /** Whether port labels are placed inside or outside. */
    package let portLabelsPlacement: PortLabelPlacement
    /** Whether to treat port labels as a group when centering them next to eastern or western ports. */
    package let portLabelsTreatAsGroup: Bool
    /** Where node labels are placed by default. */
    package let nodeLabelPlacement: NodeLabelPlacement
    /** Space to leave around the node label area. */
    package let nodeLabelsPadding: ElkPadding
    /** Space between a node and its outside labels. */
    package let nodeLabelSpacing: Double
    /** Space between two labels. */
    package let labelLabelSpacing: Double
    /** Space between two different label cells. */
    package let labelCellSpacing: Double
    /** Space between a port and another port. */
    package let portPortSpacing: Double
    /** Horizontal space between a port and its labels. */
    package let portLabelSpacingHorizontal: Double
    /** Vertical space between a port and its labels. */
    package let portLabelSpacingVertical: Double
    /** Margin to leave around the set of ports on each side. */
    package let surroundingPortMargins: ElkMargin
    /** Whether node is being laid out in top-down layout mode. */
    package let topdownLayout: Bool

    // MARK: - More Contexts

    /** Context objects that hold more information about each port. Sorted left-to-right / top-to-bottom.
        Uses a TreeMultimap equivalent that maintains sorted order per Java's NodeContext.comparePortContexts. */
    package var portContexts = PortContextMultimap()

    // MARK: - The Cell System

    /** The main cell that holds all the cells that make up the node. */
    package let nodeContainer: StripContainerCell
    /** The main cell's middle row, which will contain further cells. */
    package let nodeContainerMiddleRow: StripContainerCell
    /** The grid container that represents the node's area reserved for inside node labels (and the client area). */
    package var insideNodeLabelContainer: GridContainerCell?
    /** All cells that will describe the space required for ports and for inside port labels. */
    package var insidePortLabelCells: [PortSide: AtomicCell] = [:]
    /** All container cells that will hold label cells for outside node labels. */
    package var outsideNodeLabelContainers: [PortSide: StripContainerCell] = [:]
    /** All of the label cells created for possible node labels, both inside and outside. */
    package var nodeLabelCells: [NodeLabelLocation: LabelCell] = [:]

    // MARK: - Creation

    /**
     * Creates a new context object for the given node, fully initialized with the node's settings.
     */
    package init(parentGraph: GraphAdapter, node: NodeAdapter) {
        self.node = node
        self.nodeSize = KVector(node.getSize())

        // Top-down layout
        topdownLayout = node.getProperty(CoreOptions.TOPDOWN_LAYOUT) ?? false

        // Compound node
        treatAsCompoundNode = node.isCompoundNode() || (node.getProperty(CoreOptions.INSIDE_SELF_LOOPS_ACTIVATE) ?? false)

        // Core size settings
        sizeConstraints = node.getProperty(CoreOptions.NODE_SIZE_CONSTRAINTS) ?? SizeConstraint()
        sizeOptions = node.getProperty(CoreOptions.NODE_SIZE_OPTIONS) ?? SizeOptions()
        portConstraints = node.getProperty(CoreOptions.PORT_CONSTRAINTS) ?? .free
        portLabelsPlacement = node.getProperty(CoreOptions.PORT_LABELS_PLACEMENT) ?? PortLabelPlacement()
        if !PortLabelPlacement.isValid(portLabelsPlacement) {
            // Use default instead of fatal
        }

        portLabelsTreatAsGroup = node.getProperty(CoreOptions.PORT_LABELS_TREAT_AS_GROUP) ?? true
        nodeLabelPlacement = node.getProperty(CoreOptions.NODE_LABELS_PLACEMENT) ?? NodeLabelPlacement()
        if !NodeLabelPlacement.isValid(nodeLabelPlacement) {
            // Use default instead of fatal
        }

        // Copy spacings for convenience
        nodeLabelsPadding = (IndividualSpacings.getIndividualOrInherited(node, CoreOptions.NODE_LABELS_PADDING) as? ElkPadding) ?? ElkPadding()
        nodeLabelSpacing = (IndividualSpacings.getIndividualOrInherited(node, CoreOptions.SPACING_LABEL_NODE) as? Double) ?? 0.0
        labelLabelSpacing = (IndividualSpacings.getIndividualOrInherited(node, CoreOptions.SPACING_LABEL_LABEL) as? Double) ?? 0.0
        portPortSpacing = (IndividualSpacings.getIndividualOrInherited(node, CoreOptions.SPACING_PORT_PORT) as? Double) ?? 0.0
        portLabelSpacingHorizontal =
                (IndividualSpacings.getIndividualOrInherited(node, CoreOptions.SPACING_LABEL_PORT_HORIZONTAL) as? Double) ?? 0.0
        portLabelSpacingVertical =
                (IndividualSpacings.getIndividualOrInherited(node, CoreOptions.SPACING_LABEL_PORT_VERTICAL) as? Double) ?? 0.0
        surroundingPortMargins = (IndividualSpacings.getIndividualOrInherited(
                node, CoreOptions.SPACING_PORTS_SURROUNDING) as? ElkMargin) ?? ElkMargin()

        labelCellSpacing = 2 * labelLabelSpacing

        // Create main cells (the others will be created later)
        let symmetry = !sizeOptions.contains(.asymmetrical)
        nodeContainer = StripContainerCell(mode: .VERTICAL, symmetrical: symmetry, gap: 0)

        nodeContainerMiddleRow = StripContainerCell(mode: .HORIZONTAL, symmetrical: symmetry, gap: 0)
        nodeContainer.setCell(.center, cell: nodeContainerMiddleRow)
    }


    // MARK: - Application

    /**
     * Applies the node size stored in this context to the actual node.
     */
    package func applyNodeSize() {
        node.setSize(nodeSize)
    }


    // MARK: - Utility Methods

    /**
     * Returns the port alignment that applies to the given side of the node.
     */
    package func getPortAlignment(portSide: PortSide) -> PortAlignment {
        var alignment: PortAlignment? = nil

        switch portSide {
        case .NORTH:
            if node.hasProperty(CoreOptions.PORT_ALIGNMENT_NORTH) {
                alignment = node.getProperty(CoreOptions.PORT_ALIGNMENT_NORTH)
            }

        case .SOUTH:
            if node.hasProperty(CoreOptions.PORT_ALIGNMENT_SOUTH) {
                alignment = node.getProperty(CoreOptions.PORT_ALIGNMENT_SOUTH)
            }

        case .EAST:
            if node.hasProperty(CoreOptions.PORT_ALIGNMENT_EAST) {
                alignment = node.getProperty(CoreOptions.PORT_ALIGNMENT_EAST)
            }

        case .WEST:
            if node.hasProperty(CoreOptions.PORT_ALIGNMENT_WEST) {
                alignment = node.getProperty(CoreOptions.PORT_ALIGNMENT_WEST)
            }

        default:
            break
        }

        // Fall back to basic port alignment if we haven't found a more specific one yet
        if alignment == nil {
            alignment = node.getProperty(CoreOptions.PORT_ALIGNMENT_DEFAULT)
        }

        return alignment ?? .begin
    }

    /// Convenience overload without label
    package func getPortAlignment(_ portSide: PortSide) -> PortAlignment {
        return getPortAlignment(portSide: portSide)
    }
}
