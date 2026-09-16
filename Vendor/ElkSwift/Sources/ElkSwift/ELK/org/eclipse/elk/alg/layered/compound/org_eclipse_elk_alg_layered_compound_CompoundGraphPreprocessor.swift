/*******************************************************************************
 * Copyright (c) 2013, 2020 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

import Foundation

/// Preprocess a compound graph by splitting cross-hierarchy edges. The result is stored in
/// `InternalProperties.CROSS_HIERARCHY_MAP`, which is attached to the top-level graph.
package class CompoundGraphPreprocessor: ILayoutProcessor {

    // MARK: - Variables

    /// Map of original edges to generated cross-hierarchy edges.
    private var crossHierarchyMap: [LEdge: [CrossHierarchyEdge]] = [:]
    /// Map of ports to their assigned dummy nodes in the nested graphs.
    private var dummyNodeMap: [ObjectIdentifier: LNode] = [:]

    // Helper to get/set in dummyNodeMap using LPort identity
    private func getDummyNode(for port: LPort) -> LNode? {
        return dummyNodeMap[ObjectIdentifier(port)]
    }
    private func setDummyNode(_ node: LNode, for port: LPort) {
        dummyNodeMap[ObjectIdentifier(port)] = node
    }

    // MARK: - Processing

    package func process(_ graph: LGraph, _ monitor: IElkProgressMonitor) {
        monitor.begin("Compound graph preprocessor", 1)

        crossHierarchyMap = [:]

        // Create new dummy edges at hierarchy bounds and move the labels around accordingly
        let _ = transformHierarchyEdges(graph, parentNode: nil)
        moveLabelsAndRemoveOriginalEdges(graph)

        setSidesOfPortsToSidesOfDummyNodes()

        // Attach cross hierarchy map to the graph and cleanup
        graph.setProperty(InternalProperties.CROSS_HIERARCHY_MAP, crossHierarchyMap)
        crossHierarchyMap = [:]
        dummyNodeMap.removeAll()

        monitor.done()
    }

    /// Ensures that for each dummy node the external port and vice versa is set.
    private func setSidesOfPortsToSidesOfDummyNodes() {
        // We need to iterate over port->node pairs. Since we use ObjectIdentifier keys,
        // we need a separate collection that tracks the actual port objects.
        // We'll iterate over portToNodeEntries instead.
        for (port, dummyNode) in portToNodeEntries {
            dummyNode.setProperty(InternalProperties.ORIGIN, port)
            port.setProperty(InternalProperties.PORT_DUMMY, dummyNode)
            port.setProperty(InternalProperties.INSIDE_CONNECTIONS, true)
            if let extPortSide: PortSide = dummyNode.getProperty(InternalProperties.EXT_PORT_SIDE) {
                port.setSide(extPortSide)
            }
            if let ownerNode = port.getNode() {
                ownerNode.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FIXED_SIDE)
                if let ownerGraph = ownerNode.graph {
                    var graphProps = ownerGraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []
                    graphProps.insert(.NON_FREE_PORTS)
                    ownerGraph.setProperty(InternalProperties.GRAPH_PROPERTIES, graphProps)
                }
            }
        }
    }

    /// Tracks actual port→node pairs for setSidesOfPortsToSidesOfDummyNodes
    private var portToNodeEntries: [(LPort, LNode)] = []

    private func setDummyNodeTracked(_ node: LNode, for port: LPort) {
        dummyNodeMap[ObjectIdentifier(port)] = node
        portToNodeEntries.append((port, node))
    }

    // MARK: - Hierarchy Edge Transformation

    /// Recursively transform cross-hierarchy edges into sequences of dummy ports and dummy edges.
    private func transformHierarchyEdges(_ graph: LGraph, parentNode: LNode?) -> [ExternalPort] {
        // Process all children and recurse down to gather their external ports
        var containedExternalPorts: [ExternalPort] = []

        for node in graph.getLayerlessNodes() {
            if let nestedGraph = node.getNestedGraph() {
                // Recursively process the child graph
                let childPorts = transformHierarchyEdges(nestedGraph, parentNode: node)
                containedExternalPorts.append(contentsOf: childPorts)

                // Process inside self loops
                processInsideSelfLoops(nestedGraph, node: node)

                // Make sure that all hierarchical ports have had dummy nodes created for them
                let nestedGraphProps = nestedGraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []
                if nestedGraphProps.contains(.EXTERNAL_PORTS) {
                    let portConstraints = node.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .FREE
                    let portLabelsPlacement = node.getProperty(LayeredOptions.PORT_LABELS_PLACEMENT)
                    let insidePortLabels: Bool
                    if let plp = portLabelsPlacement as? PortLabelPlacement {
                        insidePortLabels = plp.contains(.inside)
                    } else {
                        insidePortLabels = false
                    }

                    for port in node.getPorts() {
                        // Make sure that every port has a dummy node created for it
                        var dummyNode = getDummyNode(for: port)
                        if dummyNode == nil {
                            dummyNode = LGraphUtil.createExternalPortDummy(
                                port,
                                portConstraints,
                                port.getSide(),
                                -port.getNetFlow(),
                                KVector(),
                                KVector(),
                                port.size,
                                nestedGraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED,
                                nestedGraph
                            )
                                dummyNode?.setProperty(InternalProperties.ORIGIN, port)
                            if let dn = dummyNode {
                                setDummyNodeTracked(dn, for: port)
                                nestedGraph.layerlessNodes.append(dn)
                            }
                        }

                        guard let resolvedDummyNode = dummyNode else { continue }
                        let dummyNodePort = resolvedDummyNode.getPorts()[0]

                        for extPortLabel in port.labels {
                            let dummyPortLabel = LLabel()
                            dummyPortLabel.size.x = extPortLabel.size.x
                            dummyPortLabel.size.y = extPortLabel.size.y
                            dummyNodePort.labels.append(dummyPortLabel)

                            if !insidePortLabels {
                                let side = port.getSide()
                                var insidePart: Double = 0
                                if let plp = portLabelsPlacement as? PortLabelPlacement,
                                   PortLabelPlacement.isFixed(plp) {
                                    insidePart = ElkUtil.computeInsidePart(
                                        extPortLabel.position,
                                        extPortLabel.size,
                                        port.size,
                                        0,
                                        side
                                    )
                                }
                                if portConstraints == .FREE
                                    || side == .EAST || side == .WEST {
                                    dummyPortLabel.size.x = insidePart
                                } else {
                                    dummyPortLabel.size.y = insidePart
                                }
                            }
                        }
                    }
                }
            }
        }

        // This will be the list of external ports we will export
        var exportedExternalPorts: [ExternalPort] = []

        // Process the cross-hierarchy edges connected to the inside of the child nodes
        processInnerHierarchicalEdgeSegments(graph, parentNode: parentNode,
                                              containedExternalPorts: containedExternalPorts,
                                              exportedExternalPorts: &exportedExternalPorts)

        // Process the cross-hierarchy edges connected to the outside of the parent node
        if let parentNode = parentNode {
            processOuterHierarchicalEdgeSegments(graph, parentNode: parentNode,
                                                  exportedExternalPorts: &exportedExternalPorts)
        }

        return exportedExternalPorts
    }

    // MARK: - Move Labels and Remove Original Edges

    private func moveLabelsAndRemoveOriginalEdges(_ graph: LGraph) {
        for (origEdge, segments) in crossHierarchyMap {
            // If the original edge had any labels, move them to the newly introduced edge segments
            if !origEdge.labels.isEmpty {
                let sortedSegments = segments.sorted { a, b in
                    let comp = CrossHierarchyEdgeComparator(graph)
                    return comp.compare(a, b) == .orderedAscending
                }

                // Iterate over labels and move them
                var labelsToRemove: [Int] = []
                for (labelIdx, currLabel) in origEdge.labels.enumerated() {
                    var targetDummyEdgeIndex = -1
                    let placement: EdgeLabelPlacement? = currLabel.getProperty(LayeredOptions.EDGE_LABELS_PLACEMENT)

                    switch placement {
                    case .head:
                        targetDummyEdgeIndex = sortedSegments.count - 1
                    case .center:
                        targetDummyEdgeIndex = getShallowestEdgeSegment(sortedSegments)
                    case .tail:
                        targetDummyEdgeIndex = 0
                    default:
                        break
                    }

                    if targetDummyEdgeIndex != -1 {
                        let targetSegment = sortedSegments[targetDummyEdgeIndex]
                        targetSegment.getEdge().labels.append(currLabel)

                        if let segGraph = targetSegment.getEdge().source?.getNode()?.graph {
                            var graphProps = segGraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []
                            graphProps.insert(.END_LABELS)
                            graphProps.insert(.CENTER_LABELS)
                            segGraph.setProperty(InternalProperties.GRAPH_PROPERTIES, graphProps)
                        }

                        labelsToRemove.append(labelIdx)
                        currLabel.setProperty(InternalProperties.ORIGINAL_LABEL_EDGE, origEdge)
                    }
                }

                // Remove labels in reverse order
                for idx in labelsToRemove.reversed() {
                    origEdge.labels.remove(at: idx)
                }
            }

            // Remove original edge
            origEdge.setSource(nil)
            origEdge.setTarget(nil)
        }
    }

    /// Determines the index of the shallowest edge segment.
    private func getShallowestEdgeSegment(_ edgeSegments: [CrossHierarchyEdge]) -> Int {
        var result = -1
        var index = 0

        for crossHierarchyEdge in edgeSegments {
            if crossHierarchyEdge.getType() == .INPUT {
                result = index == 0 ? 0 : index - 1
                break
            } else if index == edgeSegments.count - 1 {
                result = index
            }
            index += 1
        }

        return result
    }

    // MARK: - Inner Hierarchical Edge Segment Processing

    private func processInnerHierarchicalEdgeSegments(_ graph: LGraph, parentNode: LNode?,
                                                       containedExternalPorts: [ExternalPort],
                                                       exportedExternalPorts: inout [ExternalPort]) {
        var createdExternalPorts: [ExternalPort] = []

        for externalPort in containedExternalPorts {
            var currentExternalPort: ExternalPort? = nil

            if externalPort.type == .OUTPUT {
                for outEdge in externalPort.origEdges {
                    guard let outTarget = outEdge.target, let targetNode = outTarget.getNode() else { continue }
                    if targetNode.graph === graph {
                        connectChild(graph, externalPort: externalPort, origEdge: outEdge,
                                     sourcePort: externalPort.dummyPort, targetPort: outTarget)
                    } else if parentNode == nil || LGraphUtil.isDescendant(targetNode, parentNode) {
                        // Case 2: edge connects two direct children
                        connectSiblings(graph, externalOutputPort: externalPort,
                                        containedExternalPorts: containedExternalPorts, origEdge: outEdge)
                    } else {
                        guard let pn = parentNode else { continue }
                        let newExternalPort = introduceHierarchicalEdgeSegment(
                            graph, parentNode: pn, origEdge: outEdge,
                            oppositePort: externalPort.dummyPort, portType: .OUTPUT,
                            defaultExternalPort: currentExternalPort)
                        if newExternalPort !== currentExternalPort {
                            createdExternalPorts.append(newExternalPort)
                        }
                        if newExternalPort.exported {
                            currentExternalPort = newExternalPort
                        }
                    }
                }
            } else {
                for inEdge in externalPort.origEdges {
                    guard let inSource = inEdge.source, let sourceNode = inSource.getNode() else { continue }
                    if sourceNode.graph === graph {
                        connectChild(graph, externalPort: externalPort, origEdge: inEdge,
                                     sourcePort: inSource, targetPort: externalPort.dummyPort)
                    } else if parentNode == nil || LGraphUtil.isDescendant(sourceNode, parentNode) {
                        // Case 2: handled by output port code above
                        continue
                    } else {
                        guard let pn = parentNode else { continue }
                        let newExternalPort = introduceHierarchicalEdgeSegment(
                            graph, parentNode: pn, origEdge: inEdge,
                            oppositePort: externalPort.dummyPort, portType: .INPUT,
                            defaultExternalPort: currentExternalPort)
                        if newExternalPort !== currentExternalPort {
                            createdExternalPorts.append(newExternalPort)
                        }
                        if newExternalPort.exported {
                            currentExternalPort = newExternalPort
                        }
                    }
                }
            }
        }

        // Add dummy nodes and exported external ports
        for externalPort in createdExternalPorts {
            if !graph.layerlessNodes.contains(where: { $0 === externalPort.dummyNode }) {
                graph.layerlessNodes.append(externalPort.dummyNode)
            }
            if externalPort.exported {
                exportedExternalPorts.append(externalPort)
            }
        }
    }

    /// Connects an external port with a child node of the given graph.
    private func connectChild(_ graph: LGraph, externalPort: ExternalPort, origEdge: LEdge,
                              sourcePort: LPort, targetPort: LPort) {
        let dummyEdge = createDummyEdge(graph, origEdge: origEdge)
        dummyEdge.setSource(sourcePort)
        dummyEdge.setTarget(targetPort)

        crossHierarchyMap[origEdge, default: []].append(
            CrossHierarchyEdge(dummyEdge, graph, externalPort.type))
    }

    /// Connects external ports of two child nodes of the given graph.
    private func connectSiblings(_ graph: LGraph, externalOutputPort: ExternalPort,
                                  containedExternalPorts: [ExternalPort], origEdge: LEdge) {
        // Find the opposite external port
        var targetExternalPort: ExternalPort? = nil
        for externalPort2 in containedExternalPorts {
            if externalPort2 !== externalOutputPort && externalPort2.origEdges.contains(where: { $0 === origEdge }) {
                targetExternalPort = externalPort2
                break
            }
        }
        guard let targetExtPort = targetExternalPort else { return }
        assert(targetExtPort.type == .INPUT)

        let dummyEdge = createDummyEdge(graph, origEdge: origEdge)
        dummyEdge.setSource(externalOutputPort.dummyPort)
        dummyEdge.setTarget(targetExtPort.dummyPort)

        crossHierarchyMap[origEdge, default: []].append(
            CrossHierarchyEdge(dummyEdge, graph, externalOutputPort.type))
    }

    // MARK: - Outer Hierarchical Edge Segment Processing

    private func processOuterHierarchicalEdgeSegments(_ graph: LGraph, parentNode: LNode,
                                                       exportedExternalPorts: inout [ExternalPort]) {
        var createdExternalPorts: [ExternalPort] = []

        for childNode in graph.getLayerlessNodes() {
            for childPort in childNode.getPorts() {
                // Outgoing edges
                var currentExternalOutputPort: ExternalPort? = nil
                for outEdge in LGraphUtil.toEdgeArray(childPort.outgoingEdges) {
                    guard let outTarget = outEdge.target, let outSource = outEdge.source else { continue }
                    if !LGraphUtil.isDescendant(outTarget.getNode(), parentNode) {
                        let newExternalPort = introduceHierarchicalEdgeSegment(
                            graph, parentNode: parentNode, origEdge: outEdge,
                            oppositePort: outSource, portType: .OUTPUT,
                            defaultExternalPort: currentExternalOutputPort)
                        if newExternalPort !== currentExternalOutputPort {
                            createdExternalPorts.append(newExternalPort)
                        }
                        if newExternalPort.exported {
                            currentExternalOutputPort = newExternalPort
                        }
                    }
                }

                // Incoming edges
                var currentExternalInputPort: ExternalPort? = nil
                for inEdge in LGraphUtil.toEdgeArray(childPort.incomingEdges) {
                    guard let inSource = inEdge.source, let inTarget = inEdge.target else { continue }
                    if !LGraphUtil.isDescendant(inSource.getNode(), parentNode) {
                        let newExternalPort = introduceHierarchicalEdgeSegment(
                            graph, parentNode: parentNode, origEdge: inEdge,
                            oppositePort: inTarget, portType: .INPUT,
                            defaultExternalPort: currentExternalInputPort)
                        if newExternalPort !== currentExternalInputPort {
                            createdExternalPorts.append(newExternalPort)
                        }
                        if newExternalPort.exported {
                            currentExternalInputPort = newExternalPort
                        }
                    }
                }
            }
        }

        // Add dummy nodes and exported external ports
        for externalPort in createdExternalPorts {
            if !graph.layerlessNodes.contains(where: { $0 === externalPort.dummyNode }) {
                graph.layerlessNodes.append(externalPort.dummyNode)
            }
            if externalPort.exported {
                exportedExternalPorts.append(externalPort)
            }
        }
    }

    // MARK: - Inside Self Loop Processing

    private func processInsideSelfLoops(_ nestedGraph: LGraph, node: LNode) {
        let activate: Bool = node.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_ACTIVATE) ?? false
        if !activate {
            return
        }

        for lport in node.getPorts() {
            let outEdges = LGraphUtil.toEdgeArray(lport.outgoingEdges)

            for outEdge in outEdges {
                let isSelfLoop = outEdge.target?.getNode() === node
                let isInsideSelfLoop = isSelfLoop
                    && (outEdge.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_YO) ?? false)

                if isInsideSelfLoop {
                    guard let sourcePort = outEdge.source else { continue }
                    var sourceExtPortDummy = getDummyNode(for: sourcePort)
                    if sourceExtPortDummy == nil {
                        let newDummy = LGraphUtil.createExternalPortDummy(
                            sourcePort, .FREE, sourcePort.getSide(), -1,
                            KVector(), KVector(), sourcePort.size,
                            nestedGraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED,
                            nestedGraph)
                        newDummy.setProperty(InternalProperties.ORIGIN, sourcePort)
                        setDummyNodeTracked(newDummy, for: sourcePort)
                        nestedGraph.layerlessNodes.append(newDummy)
                        sourceExtPortDummy = newDummy
                    }

                    guard let targetPort = outEdge.target else { continue }
                    var targetExtPortDummy = getDummyNode(for: targetPort)
                    if targetExtPortDummy == nil {
                        let newDummy = LGraphUtil.createExternalPortDummy(
                            targetPort, .FREE, targetPort.getSide(), 1,
                            KVector(), KVector(), targetPort.size,
                            nestedGraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED,
                            nestedGraph)
                        newDummy.setProperty(InternalProperties.ORIGIN, targetPort)
                        setDummyNodeTracked(newDummy, for: targetPort)
                        nestedGraph.layerlessNodes.append(newDummy)
                        targetExtPortDummy = newDummy
                    }

                    guard let srcDummy = sourceExtPortDummy, let tgtDummy = targetExtPortDummy else { continue }
                    let dummyEdge = createDummyEdge(nestedGraph, origEdge: outEdge)
                    dummyEdge.setSource(srcDummy.getPorts()[0])
                    dummyEdge.setTarget(tgtDummy.getPorts()[0])

                    crossHierarchyMap[outEdge, default: []].append(
                        CrossHierarchyEdge(dummyEdge, nestedGraph, .OUTPUT))

                    var graphProps = nestedGraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []
                    graphProps.insert(.EXTERNAL_PORTS)
                    nestedGraph.setProperty(InternalProperties.GRAPH_PROPERTIES, graphProps)
                }
            }
        }
    }

    // MARK: - General Hierarchical Edge Segment Processing

    /// Does the actual work of creating a new hierarchical edge segment.
    private func introduceHierarchicalEdgeSegment(_ graph: LGraph, parentNode: LNode,
                                                   origEdge: LEdge, oppositePort: LPort,
                                                   portType: PortType,
                                                   defaultExternalPort: ExternalPort?) -> ExternalPort {
        // Check if external ports are to be merged
        let mergeExternalPorts: Bool = graph.getProperty(LayeredOptions.MERGE_HIERARCHY_EDGES) ?? false

        // Check if the edge connects to the parent node
        var parentEndPort: LPort? = nil
        if portType == .INPUT && origEdge.source?.getNode() === parentNode {
            parentEndPort = origEdge.source
        } else if portType == .OUTPUT && origEdge.target?.getNode() === parentNode {
            parentEndPort = origEdge.target
        }

        var externalPort = defaultExternalPort
        if externalPort == nil || !mergeExternalPorts || parentEndPort != nil {
            // Create a dummy node that will represent the external port
            var externalPortSide = PortSide.UNDEFINED
            if let parentEndPort = parentEndPort {
                externalPortSide = parentEndPort.getSide()
            } else {
                let pc = parentNode.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .FREE
                if pc.isSideFixed() {
                    externalPortSide = portType == .INPUT ? .WEST : .EAST
                }
            }
            let dummyNode = createExternalPortDummy(graph, parentNode: parentNode,
                                                     portType: portType, portSide: externalPortSide, edge: origEdge)

            // Create a dummy edge to be connected to the port
            guard let parentGraph = parentNode.graph else { return externalPort ?? ExternalPort(origEdge: origEdge, newEdge: LEdge(), dummyNode: dummyNode, dummyPort: LPort(), type: portType, exported: false) }
            let dummyEdge = createDummyEdge(parentGraph, origEdge: origEdge)

            if portType == .INPUT {
                dummyEdge.setSource(dummyNode.getPorts()[0])
                dummyEdge.setTarget(oppositePort)
            } else {
                dummyEdge.setSource(oppositePort)
                dummyEdge.setTarget(dummyNode.getPorts()[0])
            }

            // Create the external port (exported if not connecting just to the parent node)
            let dummyPort = dummyNode.getProperty(InternalProperties.ORIGIN) as? LPort ?? LPort()
            externalPort = ExternalPort(origEdge: origEdge, newEdge: dummyEdge, dummyNode: dummyNode,
                                        dummyPort: dummyPort, type: portType, exported: parentEndPort == nil)
        } else if let ep = externalPort {
            ep.origEdges.append(origEdge)

            let existingThickness: Double = ep.newEdge.getProperty(LayeredOptions.EDGE_THICKNESS) ?? 0
            let origThickness: Double = origEdge.getProperty(LayeredOptions.EDGE_THICKNESS) ?? 0
            let thickness = max(existingThickness, origThickness)
            ep.newEdge.setProperty(LayeredOptions.EDGE_THICKNESS, thickness)
        }

        let result = externalPort ?? ExternalPort(origEdge: origEdge, newEdge: LEdge(), dummyNode: LNode(), dummyPort: LPort(), type: portType, exported: false)
        crossHierarchyMap[origEdge, default: []].append(
            CrossHierarchyEdge(result.newEdge, graph, portType))

        return result
    }

    /// Creates and initializes a new dummy edge for the given original hierarchy-crossing edge.
    private func createDummyEdge(_ graph: LGraph, origEdge: LEdge) -> LEdge {
        let dummyEdge = LEdge()
        dummyEdge.copyProperties(origEdge)
        dummyEdge.setProperty(LayeredOptions.JUNCTION_POINTS, nil as KVectorChain?)
        return dummyEdge
    }

    /// Count how many edges want the port to be an output port of the parent and how many want it
    /// to be an input port.
    private func calculateNetFlow(_ port: LPort) -> Int {
        guard let node = port.getNode() else { return 0 }
        let insideSelfLoopsEnabled: Bool = node.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_ACTIVATE) ?? false

        var outputPortVote = 0
        var inputPortVote = 0

        for outgoingEdge in port.outgoingEdges {
            let isSelfLoop = outgoingEdge.isSelfLoop()
            let isInsideSelfLoop = isSelfLoop && insideSelfLoopsEnabled
                && (outgoingEdge.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_YO) ?? false)
            guard let targetNode = outgoingEdge.target?.getNode() else { continue }

            if isSelfLoop && isInsideSelfLoop {
                inputPortVote += 1
            } else if isSelfLoop && !isInsideSelfLoop {
                outputPortVote += 1
            } else if targetNode.graph?.parentNode === node {
                inputPortVote += 1
            } else {
                outputPortVote += 1
            }
        }

        for incomingEdge in port.incomingEdges {
            let isSelfLoop = incomingEdge.isSelfLoop()
            let isInsideSelfLoop = isSelfLoop && insideSelfLoopsEnabled
                && (incomingEdge.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_YO) ?? false)
            guard let sourceNode = incomingEdge.source?.getNode() else { continue }

            if isSelfLoop && isInsideSelfLoop {
                outputPortVote += 1
            } else if isSelfLoop && !isInsideSelfLoop {
                inputPortVote += 1
            } else if sourceNode.graph?.parentNode === node {
                outputPortVote += 1
            } else {
                inputPortVote += 1
            }
        }

        return outputPortVote - inputPortVote
    }

    /// Retrieves a dummy node to be used to represent a new external port of the parent node.
    private func createExternalPortDummy(_ graph: LGraph, parentNode: LNode,
                                          portType: PortType, portSide: PortSide, edge: LEdge) -> LNode {
        var dummyNode: LNode

        let outsidePort: LPort? = portType == .INPUT ? edge.source : edge.target
        let layoutDirection = LGraphUtil.getDirection(graph)

        if let outsidePort = outsidePort, outsidePort.getNode() === parentNode {
            if let existing = getDummyNode(for: outsidePort) {
                dummyNode = existing
            } else {
                let pc = parentNode.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .FREE
                dummyNode = LGraphUtil.createExternalPortDummy(
                    outsidePort,
                    pc,
                    portSide,
                    calculateNetFlow(outsidePort),
                    KVector(),
                    outsidePort.position,
                    outsidePort.size,
                    layoutDirection,
                    graph
                )
                dummyNode.setProperty(InternalProperties.ORIGIN, outsidePort)
                setDummyNodeTracked(dummyNode, for: outsidePort)
            }
        } else {
            let pc = parentNode.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .FREE
            dummyNode = LGraphUtil.createExternalPortDummy(
                createExternalPortProperties(graph),
                pc,
                portSide,
                portType == .INPUT ? -1 : 1,
                KVector(),
                KVector(),
                KVector(0, 0),
                layoutDirection,
                graph
            )
            let dummyPort = createPortForDummy(dummyNode, parentNode: parentNode, type: portType)
            dummyNode.setProperty(InternalProperties.ORIGIN, dummyPort)
            setDummyNodeTracked(dummyNode, for: dummyPort)
        }

        var graphProps = graph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []
        graphProps.insert(.EXTERNAL_PORTS)
        graph.setProperty(InternalProperties.GRAPH_PROPERTIES, graphProps)

        let graphPC = graph.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .FREE
        if graphPC.isSideFixed() {
            graph.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FIXED_SIDE)
        } else {
            graph.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FREE)
        }

        return dummyNode
    }

    /// Create suitable port properties for dummy external ports.
    private func createExternalPortProperties(_ graph: LGraph) -> IPropertyHolder {
        let propertyHolder = MapPropertyHolder()
        let offset: Double = (graph.getProperty(LayeredOptions.SPACING_EDGE_EDGE) ?? 10.0) / 2
        propertyHolder.setProperty(LayeredOptions.PORT_BORDER_OFFSET, offset)
        return propertyHolder
    }

    /// Create a port for an existing external port dummy node.
    private func createPortForDummy(_ dummyNode: LNode, parentNode: LNode, type: PortType) -> LPort {
        guard let graph = parentNode.graph else { return LPort() }
        let layoutDirection = LGraphUtil.getDirection(graph)
        let port = LPort()
        port.setNode(parentNode)
        switch type {
        case .INPUT:
            port.setSide(PortSide.fromDirection(layoutDirection).opposed())
        case .OUTPUT:
            port.setSide(PortSide.fromDirection(layoutDirection))
        default:
            break
        }
        let borderOffset: Double = dummyNode.getProperty(LayeredOptions.PORT_BORDER_OFFSET) ?? 0
        port.setProperty(LayeredOptions.PORT_BORDER_OFFSET, borderOffset)
        return port
    }

    // MARK: - ExternalPort Class

    package class ExternalPort {
        var origEdges: [LEdge] = []
        var newEdge: LEdge
        var dummyNode: LNode
        var dummyPort: LPort
        var type: PortType = .UNDEFINED
        var exported: Bool

        init(origEdge: LEdge, newEdge: LEdge, dummyNode: LNode, dummyPort: LPort,
             type: PortType, exported: Bool) {
            self.origEdges.append(origEdge)
            self.newEdge = newEdge
            self.dummyNode = dummyNode
            self.dummyPort = dummyPort
            self.type = type
            self.exported = exported
        }
    }
}
