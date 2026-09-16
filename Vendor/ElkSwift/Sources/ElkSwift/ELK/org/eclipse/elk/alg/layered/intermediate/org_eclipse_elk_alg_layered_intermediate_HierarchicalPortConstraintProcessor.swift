import Foundation

/**
 * Processes constraints imposed on hierarchical node dummies.
 *
 * Eastern and western ports cannot be ordered arbitrarily by the crossing minimizer if
 * the port order is fixed. Thus, this processor inserts appropriate in-layer successor
 * constraints to restrict the node ordering.
 *
 * Northern and southern external ports are replaced by new external port dummies. For each
 * node connected to a northern or southern hierarchical port dummy, a new dummy is placed
 * in the adjacent layer, rerouting the edges appropriately. The original dummies are removed,
 * to be reinserted later by HierarchicalPortOrthogonalEdgeRouter.
 *
 * Runs before phase 3.
 * Same-slot dependencies: LayerConstraintProcessor
 */
package final class org_eclipse_elk_alg_layered_intermediate_HierarchicalPortConstraintProcessor {

    /** Index of the input port in the list of ports of newly created north / south port dummy nodes. */
    private static let DUMMY_INPUT_PORT = 0

    /** Index of the output port in the list of ports of newly created north / south port dummy nodes. */
    private static let DUMMY_OUTPUT_PORT = 1

    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        monitor.begin("Hierarchical port constraint processing", 1)

        processEasternAndWesternPortDummies(layeredGraph)
        processNorthernAndSouthernPortDummies(layeredGraph)

        monitor.done()
    }

    // MARK: - East / West Hierarchical Port Dummies

    /**
     * Process eastern and western hierarchical port dummies.
     */
    private func processEasternAndWesternPortDummies(_ layeredGraph: LGraph) {
        // If the port constraints are not at least FIXED_ORDER, there's nothing to be done here
        let portConstraints = layeredGraph.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .FREE
        if !portConstraints.isOrderFixed() {
            return
        }

        let layers = layeredGraph.getLayers()

        // This affects the first and last layer
        processEasternAndWesternPortDummiesInLayer(layers[0])
        processEasternAndWesternPortDummiesInLayer(layers[layers.count - 1])
    }

    /**
     * Process the eastern and western hierarchical port dummies present in the given layer.
     */
    private func processEasternAndWesternPortDummiesInLayer(_ layer: Layer) {
        // Put the nodes into an array
        var nodes = LGraphUtil.toNodeArray(layer.getNodes())

        // Sort the array; hierarchical port dummies are at the top, sorted by
        // position or ratio in ascending order
        nodes.sort { node1, node2 in
            let nodeType1 = node1.getType()
            let nodePos1 = node1.getProperty(InternalProperties.PORT_RATIO_OR_POSITION) as? Double ?? 0.0
            let nodeType2 = node2.getType()
            let nodePos2 = node2.getProperty(InternalProperties.PORT_RATIO_OR_POSITION) as? Double ?? 0.0

            if nodeType2 != .externalPort {
                return true  // node1 before node2 (non-ext-port sorted to bottom)
            } else if nodeType1 != .externalPort {
                return false  // node2 before node1
            } else {
                return nodePos1 < nodePos2
            }
        }

        // Insert in-layer successor constraints where appropriate
        var lastHierarchicalDummy: LNode? = nil

        for node in nodes {
            if node.getType() != .externalPort {
                // No hierarchical port dummy nodes any more
                break
            }

            // Only process dummies created for eastern or western external ports
            let externalPortSide = node.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide
            if externalPortSide != .WEST && externalPortSide != .EAST {
                continue
            }

            if let lastDummy = lastHierarchicalDummy {
                var constraints = lastDummy.getProperty(InternalProperties.IN_LAYER_SUCCESSOR_CONSTRAINTS) as? [LNode] ?? []
                constraints.append(node)
                lastDummy.setProperty(InternalProperties.IN_LAYER_SUCCESSOR_CONSTRAINTS, constraints as Any)
            }

            lastHierarchicalDummy = node
        }
    }

    // MARK: - North / South Hierarchical Port Dummies

    /**
     * Process northern and southern hierarchical port dummies.
     */
    private func processNorthernAndSouthernPortDummies(_ layeredGraph: LGraph) {
        // If the port constraints are not at least FIXED_SIDE, there's nothing to do here
        let portConstraints = layeredGraph.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .FREE
        if !portConstraints.isSideFixed() {
            return
        }

        let layers = layeredGraph.getLayers()
        let layerCount = layers.count

        // For each layer, we keep a map of dummy nodes created for a given original external port
        // dummy. This lets us remember which new dummy node was created for which original external
        // port dummy in which layer.
        // We keep enough space to hold layerCount + 2 instances because we might have to add a new
        // first and last layer.
        var extPortToDummyNodeMap: [[AnyHashable: LNode]] = []
        var newDummyNodes: [[LNode]] = []

        // Add maps and lists for a new first layer that might have to be created as well as for the
        // current first layer
        extPortToDummyNodeMap.append([:])
        extPortToDummyNodeMap.append([:])
        newDummyNodes.append([])
        newDummyNodes.append([])

        // We remember each original external port dummy we encounter
        var originalExternalPortDummies: [LNode] = []

        // Iterate through each layer
        for currLayerIdx in 0..<layerCount {
            let currentLayer = layers[currLayerIdx]

            // Dummy node maps and lists for the previous and next layer
            var prevExtPortToDummyNodesMap = extPortToDummyNodeMap[currLayerIdx]
            var nextExtPortToDummyNodesMap: [AnyHashable: LNode] = [:]
            extPortToDummyNodeMap.append(nextExtPortToDummyNodesMap)

            var prevNewDummyNodes = newDummyNodes[currLayerIdx]
            var nextNewDummyNodes: [LNode] = []
            newDummyNodes.append(nextNewDummyNodes)

            // Iterate through the layer's nodes, looking for normal nodes connected to
            // northern / southern hierarchical port dummies
            for currentNode in currentLayer.getNodes() {
                if isNorthernOrSouthernDummy(currentNode) {
                    // It's a northern or southern external port dummy. Schedule for removal.
                    originalExternalPortDummies.append(currentNode)
                    continue
                }

                // Iterate over the node's incoming edges
                for edge in currentNode.getIncomingEdges() {
                    guard let sourceNode = edge.getSource()?.getNode() else { continue }

                    // Check if it's a northern / southern dummy node
                    if !isNorthernOrSouthernDummy(sourceNode) {
                        continue
                    }

                    // See if a dummy has already been created for the previous layer
                    let originKey = ObjectIdentifier(sourceNode.getProperty(InternalProperties.ORIGIN) as AnyObject)
                    let prevLayerDummy: LNode
                    if let existing = prevExtPortToDummyNodesMap[originKey] {
                        prevLayerDummy = existing
                    } else {
                        // No. Create one.
                        prevLayerDummy = createDummy(layeredGraph, sourceNode)
                        prevExtPortToDummyNodesMap[originKey] = prevLayerDummy
                        prevNewDummyNodes.append(prevLayerDummy)
                    }

                    // Reroute the edge
                    edge.setSource(prevLayerDummy.getPorts()[Self.DUMMY_OUTPUT_PORT])
                }

                // Iterate over the node's outgoing edges
                for edge in currentNode.getOutgoingEdges() {
                    guard let targetNode = edge.getTarget()?.getNode() else { continue }

                    // Check if it's a northern / southern dummy node
                    if !isNorthernOrSouthernDummy(targetNode) {
                        continue
                    }

                    // See if a dummy has already been created for the next layer
                    let originKey = ObjectIdentifier(targetNode.getProperty(InternalProperties.ORIGIN) as AnyObject)
                    let nextLayerDummy: LNode
                    if let existing = nextExtPortToDummyNodesMap[originKey] {
                        nextLayerDummy = existing
                    } else {
                        // No. Create one.
                        nextLayerDummy = createDummy(layeredGraph, targetNode)
                        nextExtPortToDummyNodesMap[originKey] = nextLayerDummy
                        nextNewDummyNodes.append(nextLayerDummy)
                    }

                    // Reroute the edge
                    edge.setTarget(nextLayerDummy.getPorts()[Self.DUMMY_INPUT_PORT])
                }
            }

            // Write back modified maps/lists
            extPortToDummyNodeMap[currLayerIdx] = prevExtPortToDummyNodesMap
            extPortToDummyNodeMap[currLayerIdx + 2] = nextExtPortToDummyNodesMap
            newDummyNodes[currLayerIdx] = prevNewDummyNodes
            newDummyNodes[currLayerIdx + 2] = nextNewDummyNodes
        }

        // Add the newly created dummy nodes
        for i in 0..<newDummyNodes.count {
            let nodeList = newDummyNodes[i]
            if nodeList.isEmpty {
                continue
            }

            // Find the layer the dummy nodes should be added to
            var layer: Layer
            if i == 0 {
                // A new first layer must be created
                layer = Layer(layeredGraph)
                layeredGraph.layers.insert(layer, at: 0)
            } else if i == extPortToDummyNodeMap.count - 1 {
                // A new last layer must be created
                layer = Layer(layeredGraph)
                layeredGraph.layers.append(layer)
            } else {
                layer = layeredGraph.layers[i - 1]
            }

            for dummy in nodeList {
                dummy.setLayer(layer)
            }
        }

        // Iterate through the hierarchical port dummies and remove them
        for originalDummy in originalExternalPortDummies {
            originalDummy.setLayer(nil)
        }

        // Remember the original external port dummies in the graph
        layeredGraph.setProperty(InternalProperties.EXT_PORT_REPLACED_DUMMIES, originalExternalPortDummies as Any)
    }

    /**
     * Checks if the node represents a northern or southern external port.
     */
    private func isNorthernOrSouthernDummy(_ node: LNode) -> Bool {
        let nodeType = node.getType()

        if nodeType == .externalPort {
            let portSide = node.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide
            return portSide == .NORTH || portSide == .SOUTH
        }

        return false
    }

    /**
     * Creates a dummy for the given original dummy. The dummy's ORIGIN property will point to the
     * original dummy's origin. The EXT_PORT_REPLACED_DUMMY property points to the original dummy.
     */
    private func createDummy(_ layeredGraph: LGraph, _ originalDummy: LNode) -> LNode {
        let newDummy = LNode(layeredGraph)
        newDummy.copyProperties(originalDummy)
        newDummy.setProperty(InternalProperties.EXT_PORT_REPLACED_DUMMY, originalDummy as Any)
        newDummy.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FIXED_POS as Any)
        newDummy.setProperty(LayeredOptions.ALIGNMENT, Alignment.center as Any)
        newDummy.setType(.externalPort)

        let inputPort = LPort()
        inputPort.setNode(newDummy)
        inputPort.setSide(.WEST)

        let outputPort = LPort()
        outputPort.setNode(newDummy)
        outputPort.setSide(.EAST)

        return newDummy
    }
}
