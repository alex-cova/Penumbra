// Copyright (c) 2015, 2020 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

// MARK: - Supporting Types and Extensions

// Note: This is a partial translation. Full translation would require the entire ELK graph framework
// and supporting libraries to be available in Swift, which is not the case in a standard Swift environment.

// Placeholder types to allow compilation
package class EcoreUtil {
    package static func getRootContainer(_ obj: AnyObject) -> AnyObject {
        if let node = obj as? ElkNode {
            if let parent = node.parent {
                return getRootContainer(parent as AnyObject)
            }
        }
        return obj
    }

    package static func isAncestor(_ ancestor: AnyObject?, _ obj: AnyObject?) -> Bool {
        guard let anc = ancestor as? ElkNode, let o = obj as? ElkNode else { return false }
        var current: ElkNode? = o
        while let c = current {
            if c === anc { return true }
            current = c.parent
        }
        return false
    }
}
// Enums (simplified placeholders)
// Protocol stubs
// MARK: - Main Class

package class ElkGraphImporter {

    package init() {}

    package var nodeAndPortMap: [ObjectIdentifier: LGraphElement] = [:]

    private func mapKey(_ element: AnyObject) -> ObjectIdentifier {
        return ObjectIdentifier(element)
    }

    package subscript(element: AnyObject) -> LGraphElement? {
        get { return nodeAndPortMap[mapKey(element)] }
        set { nodeAndPortMap[mapKey(element)] = newValue }
    }
    
    // MARK: - Import Entry Points
    
    package func importGraph(_ elkgraph: ElkNode) throws -> LGraph {
        let topLevelGraph = createLGraph(elkgraph)
        
        // Assign defined port sides to all external ports
        elkgraph.ports.forEach { elkport in
            ensureDefinedPortSide(topLevelGraph, elkport)
        }
        
        var graphProperties = topLevelGraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []
        checkExternalPorts(elkgraph, &graphProperties)

        if graphProperties.contains(.EXTERNAL_PORTS) {
            for elkport in elkgraph.ports {
                transformExternalPort(elkgraph, topLevelGraph, elkport)
            }
        }

        if shouldCalculateMinimumGraphSize(elkgraph) {
            calculateMinimumGraphSize(elkgraph, topLevelGraph)
        }

        if topLevelGraph.getProperty(LayeredOptions.PARTITIONING_ACTIVATE) as? Bool ?? false {
            graphProperties.insert(.PARTITIONS)
        }
        topLevelGraph.setProperty(InternalProperties.GRAPH_PROPERTIES, graphProperties)
        
        if topLevelGraph.hasProperty(LayeredOptions.SPACING_BASE_VALUE) {
            let baseValue = topLevelGraph.getProperty(LayeredOptions.SPACING_BASE_VALUE) as? Double ?? 0.0
            LayeredSpacings.withBaseValue(baseValue).apply(topLevelGraph)
        }
        
        if elkgraph.getProperty(LayeredOptions.HIERARCHY_HANDLING) as? HierarchyHandling == .INCLUDE_CHILDREN {
            try importHierarchicalGraph(elkgraph, topLevelGraph)
        } else {
            try importFlatGraph(elkgraph, topLevelGraph)
        }
        
        return topLevelGraph
    }
    
    package func ensureDefinedPortSide(_ lgraph: LGraph, _ elkport: ElkPort) {
        var layoutDirection = lgraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED
        if layoutDirection == .UNDEFINED { layoutDirection = .RIGHT }
        var portSide = elkport.getProperty(LayeredOptions.PORT_SIDE) as? PortSide ?? .UNDEFINED
        let portConstraints = lgraph.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .UNDEFINED
        
        if !portConstraints.isSideFixed() {
            let netFlow = calculateNetFlow(elkport)
            
            if netFlow > 0 {
                portSide = PortSide.fromDirection(layoutDirection)
            } else {
                portSide = PortSide.fromDirection(layoutDirection).opposed()
            }
        } else {
            if portSide == .UNDEFINED {
                portSide = ElkUtil.calcPortSide(elkport, direction: layoutDirection)
                
                if portSide == .UNDEFINED {
                    portSide = PortSide.fromDirection(layoutDirection)
                }
            }
        }
        
        elkport.setProperty(LayeredOptions.PORT_SIDE, portSide)
    }
    
    package func shouldCalculateMinimumGraphSize(_ elkgraph: ElkNode) -> Bool {
        return !(elkgraph.getProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS) as? SizeConstraint ?? []).isEmpty
    }
    
    package func calculateMinimumGraphSize(_ elkgraph: ElkNode, _ lgraph: LGraph) {
        if elkgraph.parent == nil {
            return
        }
        
        var sizeConstraints = lgraph.getProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS) as? SizeConstraint ?? []
        assert(!sizeConstraints.isEmpty)

        if elkgraph.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints == .UNDEFINED {
            elkgraph.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FREE)
        }

        guard let parent = elkgraph.parent,
              let graphAdapter = ElkGraphAdapters.adapt(parent),
              let nodeAdapter = ElkGraphAdapters.adaptSingleNode(elkgraph) else { return }

        let minSize = NodeLabelAndSizeCalculator.process(graphAdapter, nodeAdapter, false, true)

        sizeConstraints.insert(.minimumSize)
        lgraph.setProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS, sizeConstraints)

        let configuredMinSize = lgraph.getProperty(LayeredOptions.NODE_SIZE_MINIMUM) as? KVector ?? KVector()
        configuredMinSize.x = max(minSize.x, configuredMinSize.x)
        configuredMinSize.y = max(minSize.y, configuredMinSize.y)
    }
    
    package func importFlatGraph(_ elkgraph: ElkNode, _ lgraph: LGraph) throws {
        var index = 0
        var cbGroupModelOrders: Set<Int> = []

        for child in elkgraph.children {
            if !(child.getProperty(LayeredOptions.NO_LAYOUT) as? Bool ?? false) {
                if needsModelOrder(child) {
                    child.setProperty(InternalProperties.MODEL_ORDER, index)
                    index += 1
                    if child.hasProperty(LayeredOptions.CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CYCLE_BREAKING_ID) {
                        cbGroupModelOrders.insert(child.getProperty(LayeredOptions.CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CYCLE_BREAKING_ID) as? Int ?? 0)
                    }
                }
                transformNode(child, lgraph)
            }
        }
        
        lgraph.setProperty(InternalProperties.MAX_MODEL_ORDER_NODES, index)
        lgraph.setProperty(InternalProperties.CB_NUM_MODEL_ORDER_GROUPS, cbGroupModelOrders.count)
        
        index = 0
        for elkedge in elkgraph.containedEdges {
            if needsModelOrderBasedOnParent(elkgraph) {
                elkedge.setProperty(InternalProperties.MODEL_ORDER, index)
                index += 1
            }
            
            let source = ElkGraphUtil.connectableShapeToNode(elkedge.sources[0])
            let target = ElkGraphUtil.connectableShapeToNode(elkedge.targets[0])
            
            let enableInsideSelfLoops = source.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_ACTIVATE) as? Bool ?? false
            
            let isToBeLaidOut = !(elkedge.getProperty(LayeredOptions.NO_LAYOUT) as? Bool ?? false)
            let isInsideSelfLoop = enableInsideSelfLoops && elkedge.isSelfloop() &&
                (elkedge.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_YO) as? Bool ?? false)
            let connectsSiblings = source.parent === elkgraph && target.parent === elkgraph
            let connectsToGraph = (source.parent === elkgraph && target === elkgraph) !=
                (target.parent === elkgraph && source === elkgraph)
            
            if isToBeLaidOut && !isInsideSelfLoop && (connectsToGraph || connectsSiblings) {
                try transformEdge(elkedge, elkgraph, lgraph)
            }
        }
        
        if let elkgraphParent = elkgraph.parent {
            for elkedge in elkgraphParent.containedEdges {
                let source = ElkGraphUtil.connectableShapeToNode(elkedge.sources[0])
                if source === elkgraph && elkedge.isSelfloop() {
                    let isInsideSelfLoop = (source.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_ACTIVATE) as? Bool ?? false) &&
                        (elkedge.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_YO) as? Bool ?? false)
                    if isInsideSelfLoop {
                        try transformEdge(elkedge, elkgraph, lgraph)
                    }
                }
            }
        }

    }
    
    package func importHierarchicalGraph(_ elkgraph: ElkNode, _ lgraph: LGraph) throws {
        var elkGraphQueue = ArrayDeque<ElkNode>()
        let parentGraphDirection = lgraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED
        
        var index = 0
        var cbGroupModelOrders: Set<Int> = []
        
        elkGraphQueue.append(contentsOf: elkgraph.children)
        while !elkGraphQueue.isEmpty {
            let elknode = elkGraphQueue.removeFirst()
            
            if needsModelOrder(elknode) {
                elknode.setProperty(InternalProperties.MODEL_ORDER, index)
                index += 1
                if elknode.hasProperty(LayeredOptions.CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CYCLE_BREAKING_ID) {
                    cbGroupModelOrders.insert(elknode.getProperty(LayeredOptions.CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CYCLE_BREAKING_ID) as? Int ?? 0)
                }
            }
            
            let isNodeToBeLaidOut = !(elknode.getProperty(LayeredOptions.NO_LAYOUT) as? Bool ?? false)
            if isNodeToBeLaidOut {
                let hasChildren = !elknode.children.isEmpty
                let hasInsideSelfLoops = hasInsideSelfLoops(elknode)
                let hasHierarchyHandlingEnabled = elknode.getProperty(LayeredOptions.HIERARCHY_HANDLING) as? HierarchyHandling == .INCLUDE_CHILDREN
                let usesElkLayered = !elknode.hasProperty(CoreOptions.ALGORITHM) ||
                    LayeredOptions.ALGORITHM_ID.hasSuffix(elknode.getProperty(CoreOptions.ALGORITHM) as? String ?? "")
                
                var nestedGraph: LGraph? = nil
                if usesElkLayered && hasHierarchyHandlingEnabled && (hasChildren || hasInsideSelfLoops) {
                    nestedGraph = createLGraph(elknode)
                    // Only inherit parent direction if the nested graph doesn't have
                    // an explicit direction (e.g. from "direction LR" in a subgraph).
                    let nestedDir = nestedGraph?.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED
                    if nestedDir == .UNDEFINED {
                        nestedGraph?.setProperty(LayeredOptions.DIRECTION, parentGraphDirection)
                    }
                    
                    if let ng = nestedGraph {
                        if ng.hasProperty(LayeredOptions.SPACING_BASE_VALUE) {
                            let baseValue = ng.getProperty(LayeredOptions.SPACING_BASE_VALUE) as? Double ?? 0.0
                            LayeredSpacings.withBaseValue(baseValue).apply(ng)
                        }

                        if shouldCalculateMinimumGraphSize(elknode) {
                            elknode.ports.forEach { elkport in
                                ensureDefinedPortSide(ng, elkport)
                            }
                            calculateMinimumGraphSize(elknode, ng)
                        }
                    }
                }
                
                var parentLGraph = lgraph
                if let elknodeParent = elknode.parent,
                   let parentLNode = self[elknodeParent as AnyObject] as? LNode,
                   let parentNestedGraph = parentLNode.nestedGraph {
                    parentLGraph = parentNestedGraph
                }
                
                let lnode = transformNode(elknode, parentLGraph)
                
                if let nestedGraph = nestedGraph {
                    lnode.nestedGraph = nestedGraph
                    nestedGraph.parentNode = lnode
                    elkGraphQueue.append(contentsOf: elknode.children)
                }
            }
        }
        
        lgraph.setProperty(InternalProperties.MAX_MODEL_ORDER_NODES, index)
        lgraph.setProperty(InternalProperties.CB_NUM_MODEL_ORDER_GROUPS, cbGroupModelOrders.count)
        
        index = 0
        elkGraphQueue.append(elkgraph)
        
        while !elkGraphQueue.isEmpty {
            let elkGraphNode = elkGraphQueue.removeFirst()
            
            for elkedge in elkGraphNode.containedEdges {
                try checkEdgeValidity(elkedge)
                
                if needsModelOrderBasedOnParent(elkgraph) {
                    elkedge.setProperty(InternalProperties.MODEL_ORDER, index)
                    index += 1
                }
                
                let sourceNode = ElkGraphUtil.connectableShapeToNode(elkedge.sources[0])
                let targetNode = ElkGraphUtil.connectableShapeToNode(elkedge.targets[0])
                
                if elkedge.getProperty(LayeredOptions.NO_LAYOUT) as? Bool ?? false ||
                    sourceNode.getProperty(LayeredOptions.NO_LAYOUT) as? Bool ?? false ||
                    targetNode.getProperty(LayeredOptions.NO_LAYOUT) as? Bool ?? false {
                    continue
                }
                
                let isInsideSelfLoop = elkedge.isSelfloop() &&
                    (sourceNode.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_ACTIVATE) as? Bool ?? false) &&
                    (elkedge.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_YO) as? Bool ?? false)
                
                var parentElkGraph = elkGraphNode
                
                if isInsideSelfLoop || ElkGraphUtil.isDescendant(targetNode, sourceNode) {
                    parentElkGraph = sourceNode
                } else if ElkGraphUtil.isDescendant(sourceNode, targetNode) {
                    parentElkGraph = targetNode
                }
                
                var parentLGraph = lgraph
                if let parentLNode = self[parentElkGraph as AnyObject] as? LNode,
                   let parentNestedGraph = parentLNode.nestedGraph {
                    parentLGraph = parentNestedGraph
                }
                
                let ledge = try transformEdge(elkedge, parentElkGraph, parentLGraph)
                
                ledge.setProperty(InternalProperties.COORDINATE_SYSTEM_ORIGIN,
                    findCoordinateSystemOrigin(elkedge, elkgraph, lgraph))
            }
            
            let hasHierarchyHandlingEnabled = elkGraphNode.getProperty(LayeredOptions.HIERARCHY_HANDLING) as? HierarchyHandling == .INCLUDE_CHILDREN
            if hasHierarchyHandlingEnabled {
                for elkChildGraphNode in elkGraphNode.children {
                    let usesElkLayered = !elkChildGraphNode.hasProperty(CoreOptions.ALGORITHM) ||
                        LayeredOptions.ALGORITHM_ID.hasSuffix(elkChildGraphNode.getProperty(CoreOptions.ALGORITHM) as? String ?? "")
                    let partOfSameLayoutRun = elkChildGraphNode.getProperty(LayeredOptions.HIERARCHY_HANDLING) as? HierarchyHandling == .INCLUDE_CHILDREN
                    
                    if usesElkLayered && partOfSameLayoutRun {
                        elkGraphQueue.append(elkChildGraphNode)
                    }
                }
            }
        }
    }
    
    package func needsModelOrder(_ child: ElkNode) -> Bool {
        guard let elkgraph = child.parent else { return false }
        return needsModelOrderBasedOnParent(elkgraph) &&
            !(child.getProperty(LayeredOptions.CONSIDER_MODEL_ORDER_NO_MODEL_ORDER) as? Bool ?? false)
    }
    
    package func needsModelOrderBasedOnParent(_ elkgraph: ElkNode) -> Bool {
        let modelOrderCycleBreaking = elkgraph.getProperty(LayeredOptions.CYCLE_BREAKING_STRATEGY) as? CycleBreakingStrategy ?? .GREEDY == .MODEL_ORDER ||
            elkgraph.getProperty(LayeredOptions.CYCLE_BREAKING_STRATEGY) as? CycleBreakingStrategy ?? .GREEDY == .BFS_NODE_ORDER ||
            elkgraph.getProperty(LayeredOptions.CYCLE_BREAKING_STRATEGY) as? CycleBreakingStrategy ?? .GREEDY == .DFS_NODE_ORDER ||
            elkgraph.getProperty(LayeredOptions.CYCLE_BREAKING_STRATEGY) as? CycleBreakingStrategy ?? .GREEDY == .GREEDY_MODEL_ORDER ||
            elkgraph.getProperty(LayeredOptions.CYCLE_BREAKING_STRATEGY) as? CycleBreakingStrategy ?? .GREEDY == .SCC_CONNECTIVITY ||
            elkgraph.getProperty(LayeredOptions.CYCLE_BREAKING_STRATEGY) as? CycleBreakingStrategy ?? .GREEDY == .SCC_NODE_TYPE
        
        let modelOrderLayering = elkgraph.getProperty(LayeredOptions.LAYERING_STRATEGY) as? LayeringStrategy ?? .NETWORK_SIMPLEX == .BF_MODEL_ORDER ||
            elkgraph.getProperty(LayeredOptions.LAYERING_STRATEGY) as? LayeringStrategy ?? .NETWORK_SIMPLEX == .DF_MODEL_ORDER ||
            elkgraph.getProperty(LayeredOptions.LAYERING_NODE_PROMOTION_STRATEGY) as? NodePromotionStrategy ?? .NONE == .MODEL_ORDER_LEFT_TO_RIGHT ||
            elkgraph.getProperty(LayeredOptions.LAYERING_NODE_PROMOTION_STRATEGY) as? NodePromotionStrategy ?? .NONE == .MODEL_ORDER_RIGHT_TO_LEFT
        
        let modelOrderCrossingMinimization =
            elkgraph.getProperty(LayeredOptions.CONSIDER_MODEL_ORDER_STRATEGY) as? OrderingStrategy ?? .NONE != .NONE ||
            elkgraph.getProperty(LayeredOptions.CROSSING_MINIMIZATION_FORCE_NODE_MODEL_ORDER) as? Bool ?? false ||
            elkgraph.getProperty(LayeredOptions.CONSIDER_MODEL_ORDER_COMPONENTS) as? ComponentOrderingStrategy ?? .NONE != .NONE ||
            elkgraph.getProperty(LayeredOptions.CONSIDER_MODEL_ORDER_CROSSING_COUNTER_NODE_INFLUENCE) as? Int ?? 0 != 0 ||
            elkgraph.getProperty(LayeredOptions.CONSIDER_MODEL_ORDER_CROSSING_COUNTER_PORT_INFLUENCE) as? Int ?? 0 != 0
        
        return modelOrderCycleBreaking || modelOrderLayering || modelOrderCrossingMinimization
    }
    
    package func hasInsideSelfLoops(_ elknode: ElkNode) -> Bool {
        if elknode.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_ACTIVATE) as? Bool ?? false {
            for edge in ElkGraphUtil.allOutgoingEdges(node: elknode) {
                if edge.isSelfloop() {
                    if edge.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_YO) as? Bool ?? false {
                        return true
                    }
                }
            }
        }
        return false
    }
    
    package func findCoordinateSystemOrigin(_ elkedge: ElkEdge, _ topLevelElkGraph: ElkNode, _ topLevelLGraph: LGraph) -> LGraph? {
        let source = ElkGraphUtil.connectableShapeToNode(elkedge.sources[0])
        let target = ElkGraphUtil.connectableShapeToNode(elkedge.targets[0])
        
        if source.parent === target.parent {
            return nil
        }
        
        if ElkGraphUtil.isDescendant(target, source) {
            return nil
        }
        
        guard let origin = elkedge.containingNode else { return nil }

        assert(source === origin || ElkGraphUtil.isDescendant(source, origin))
        assert(target === origin || ElkGraphUtil.isDescendant(target, origin))

        if origin === topLevelElkGraph {
            return topLevelLGraph
        } else {
            if let lnode = self[origin as AnyObject] as? LNode {
                if let lgraph = lnode.nestedGraph {
                    return lgraph
                }
            }
        }
        return nil
    }
    
    package func createLGraph(_ elkgraph: ElkNode) -> LGraph {
        let lgraph = LGraph()
        lgraph.copyProperties(elkgraph)

        if lgraph.getProperty(LayeredOptions.DIRECTION) as? Direction == .UNDEFINED {
            lgraph.setProperty(LayeredOptions.DIRECTION, LGraphUtil.getDirection(lgraph))
        }
        
        if lgraph.getProperty(LabelManagementOptions.LABEL_MANAGER) == nil {
            if let root = EcoreUtil.getRootContainer(elkgraph as AnyObject) as? IPropertyHolder {
                lgraph.setProperty(LabelManagementOptions.LABEL_MANAGER, root.getProperty(LabelManagementOptions.LABEL_MANAGER))
            }
        }
        
        lgraph.setProperty(InternalProperties.ORIGIN, elkgraph)
        lgraph.setProperty(InternalProperties.GRAPH_PROPERTIES, Set<GraphProperties>())
        
        let nodePadding = lgraph.getProperty(LayeredOptions.PADDING) as? ElkPadding ?? ElkPadding()

        let lPadding = lgraph.padding
        lPadding.add(nodePadding)

        if let parentNode = elkgraph.parent,
           let graphAdapter = ElkGraphAdapters.adapt(parentNode),
           let nodeAdapter = ElkGraphAdapters.adaptSingleNode(elkgraph) {
            let nodeLabelpadding = NodeLabelAndSizeCalculator.computeInsideNodeLabelPadding(
                graphAdapter, nodeAdapter, Direction.RIGHT)
            lPadding.add(nodeLabelpadding)
        }
        
        return lgraph
    }
    
    package func checkExternalPorts(_ elkgraph: ElkNode, _ graphProperties: inout Set<GraphProperties>) {
        let enableSelfLoops = elkgraph.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_ACTIVATE) as? Bool ?? false
        let portLabelPlacement = elkgraph.getProperty(LayeredOptions.PORT_LABELS_PLACEMENT) as? PortLabelPlacement ?? PortLabelPlacement()
        
        var hasExternalPorts = false
        var hasHyperedges = false
        
        for elkport in elkgraph.ports {
            var externalPortEdges = 0
            
            for elkedge in ElkGraphUtil.allIncidentEdges(elkport) {
                let isInsideSelfLoop = enableSelfLoops && elkedge.isSelfloop() &&
                    (elkedge.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_YO) as? Bool ?? false)
                let connectsToChild = elkedge.sources.contains(where: { $0 === elkport })
                    ? elkgraph === ElkGraphUtil.connectableShapeToNode(elkedge.targets[0]).parent
                    : elkgraph === ElkGraphUtil.connectableShapeToNode(elkedge.sources[0]).parent
                
                if isInsideSelfLoop || connectsToChild {
                    externalPortEdges += 1
                    if externalPortEdges > 1 {
                        break
                    }
                }
            }
            
            if externalPortEdges > 0 {
                hasExternalPorts = true
            } else if portLabelPlacement.contains(.inside) && !elkport.labels.isEmpty {
                hasExternalPorts = true
            }
            
            if externalPortEdges > 1 {
                hasHyperedges = true
            }
        }
        
        if hasExternalPorts {
            graphProperties.insert(.EXTERNAL_PORTS)
        }
        
        if hasHyperedges {
            graphProperties.insert(.HYPEREDGES)
        }
    }
    
    package func transformExternalPort(_ elkgraph: ElkNode, _ lgraph: LGraph, _ elkport: ElkPort) {
        let elkportPosition = KVector(
            elkport.x + elkport.width / 2.0,
            elkport.y + elkport.height / 2.0)
        let netFlow = calculateNetFlow(elkport)
        let portConstraints = elkgraph.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .UNDEFINED
        
        var portSide = elkport.getProperty(LayeredOptions.PORT_SIDE) as? PortSide ?? .UNDEFINED
        if portSide == .UNDEFINED {
            // Fallback: compute port side from position
            let direction = lgraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .RIGHT
            portSide = ElkUtil.calcPortSide(elkport, direction: direction)
            if portSide == .UNDEFINED {
                portSide = PortSide.fromDirection(direction)
            }
            elkport.setProperty(LayeredOptions.PORT_SIDE, portSide)
        }
        
        if !elkport.hasProperty(LayeredOptions.PORT_BORDER_OFFSET) {
            var portOffset: Double = 0.0
            if elkport.x == 0.0 && elkport.y == 0.0 {
                portOffset = 0.0
            } else {
                portOffset = ElkUtil.calcPortOffset(elkport, side: portSide)
            }
            elkport.setProperty(LayeredOptions.PORT_BORDER_OFFSET, portOffset)
        }
        
        let graphSize = KVector(elkgraph.width, elkgraph.height)
        let dummy = LGraphUtil.createExternalPortDummy(
            elkport, portConstraints, portSide, netFlow, graphSize,
            elkportPosition, KVector(elkport.width, elkport.height),
            lgraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .RIGHT, lgraph)
        dummy.setProperty(InternalProperties.ORIGIN, elkport)
        
        let dummyPort = dummy.ports[0]
        dummyPort.connectedToExternalNodes = isConnectedToExternalNodes(elkport)
        dummy.setProperty(LayeredOptions.PORT_LABELS_PLACEMENT, PortLabelPlacement.outside)
        
        let insidePortLabels = (elkgraph.getProperty(LayeredOptions.PORT_LABELS_PLACEMENT) as? PortLabelPlacement ?? []).contains(.inside)
        
        for elklabel in elkport.labels {
            if !(elklabel.getProperty(LayeredOptions.NO_LAYOUT) as? Bool ?? false) && !elklabel.text.isEmpty {
                let llabel = transformLabel(elklabel)
                dummyPort.labels.append(llabel)
                
                if !insidePortLabels {
                    var insidePart = 0.0
                    if PortLabelPlacement.isFixed(elkgraph.getProperty(LayeredOptions.PORT_LABELS_PLACEMENT) as? PortLabelPlacement ?? PortLabelPlacement()) {
                        insidePart = ElkUtil.computeInsidePart(KVector(elklabel.x, elklabel.y),
                            KVector(elklabel.width, elklabel.height),
                            KVector(elkport.width, elkport.height), 0, portSide)
                    }
                    switch portSide {
                    case .EAST, .WEST:
                        llabel.size.x = insidePart
                    case .NORTH, .SOUTH:
                        llabel.size.y = insidePart
                    default:
                        break
                    }
                }
            }
        }
        
        if let elkgraphParent = elkgraph.parent {
            dummy.setProperty(LayeredOptions.SPACING_LABEL_PORT_HORIZONTAL,
                elkgraphParent.getProperty(LayeredOptions.SPACING_LABEL_PORT_HORIZONTAL))
            dummy.setProperty(LayeredOptions.SPACING_LABEL_PORT_VERTICAL,
                elkgraphParent.getProperty(LayeredOptions.SPACING_LABEL_PORT_VERTICAL))
            dummy.setProperty(LayeredOptions.SPACING_LABEL_LABEL,
                elkgraphParent.getProperty(LayeredOptions.SPACING_LABEL_LABEL))
        }
        
        lgraph.layerlessNodes.append(dummy)
        self[elkport as AnyObject] = dummy
    }
    
    package func calculateNetFlow(_ elkport: ElkPort) -> Int {
        guard let elkgraph = elkport.parent else { return 0 }
        let insideSelfLoopsEnabled = elkgraph.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_ACTIVATE) as? Bool ?? false
        
        var outputPortVote = 0, inputPortVote = 0
        
        for outgoingEdge in elkport.outgoingEdges {
            let isSelfLoop = outgoingEdge.isSelfloop()
            let isInsideSelfLoop = isSelfLoop && insideSelfLoopsEnabled &&
                (outgoingEdge.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_YO) as? Bool ?? false)
            let targetNode = ElkGraphUtil.connectableShapeToNode(outgoingEdge.targets[0])
            
            if isSelfLoop && isInsideSelfLoop {
                inputPortVote += 1
            } else if isSelfLoop && !isInsideSelfLoop {
                outputPortVote += 1
            } else if targetNode.parent === elkgraph || targetNode === elkgraph {
                inputPortVote += 1
            } else {
                outputPortVote += 1
            }
        }
        
        for incomingEdge in elkport.incomingEdges {
            let isSelfLoop = incomingEdge.isSelfloop()
            let isInsideSelfLoop = isSelfLoop && insideSelfLoopsEnabled &&
                (incomingEdge.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_YO) as? Bool ?? false)
            let sourceNode = ElkGraphUtil.connectableShapeToNode(incomingEdge.sources[0])
            
            if isSelfLoop && isInsideSelfLoop {
                outputPortVote += 1
            } else if isSelfLoop && !isInsideSelfLoop {
                inputPortVote += 1
            } else if sourceNode.parent === elkgraph || sourceNode === elkgraph {
                outputPortVote += 1
            } else {
                inputPortVote += 1
            }
        }
        
        return outputPortVote - inputPortVote
    }
    
    package func isConnectedToExternalNodes(_ elkport: ElkPort) -> Bool {
        guard let parent = elkport.parent else { return false }

        for outEdge in elkport.outgoingEdges {
            let targetNode = ElkGraphUtil.connectableShapeToNode(outEdge.targets[0])
            if !ElkGraphUtil.isDescendant(targetNode, parent) {
                return true
            }
        }

        for inEdge in elkport.incomingEdges {
            let sourceNode = ElkGraphUtil.connectableShapeToNode(inEdge.sources[0])
            if !ElkGraphUtil.isDescendant(sourceNode, parent) {
                return true
            }
        }

        return false
    }
    
    @discardableResult
    package func transformNode(_ elknode: ElkNode, _ lgraph: LGraph) -> LNode {
        let lnode = LNode(lgraph)
        lnode.copyProperties(elknode)
        lnode.setProperty(InternalProperties.ORIGIN, elknode)
        
        lnode.size.x = elknode.width
        lnode.size.y = elknode.height
        lnode.position.x = elknode.x
        lnode.position.y = elknode.y
        
        lgraph.layerlessNodes.append(lnode)
        self[elknode as AnyObject] = lnode
        
        if !elknode.children.isEmpty || elknode.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_ACTIVATE) as? Bool ?? false {
            lnode.setProperty(InternalProperties.COMPOUND_NODE, true)
        }
        
        var graphProperties = lgraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []

        let portConstraints = lnode.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .UNDEFINED
        if portConstraints == .UNDEFINED {
            lnode.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FREE)
        } else if portConstraints != PortConstraints.FREE {
            graphProperties.insert(.NON_FREE_PORTS)
        }

        var portModelOrder = 0
        let direction: Direction = {
            let d = lgraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .UNDEFINED
            return d == .UNDEFINED ? .RIGHT : d
        }()

        for elkport in elknode.ports {
            if needsModelOrder(elknode) {
                elkport.setProperty(InternalProperties.MODEL_ORDER, portModelOrder)
                portModelOrder += 1
            }
            if !(elkport.getProperty(LayeredOptions.NO_LAYOUT) as? Bool ?? false) {
                transformPort(elkport, lnode, &graphProperties, direction, portConstraints)
            }
        }

        for elklabel in elknode.labels {
            if !(elklabel.getProperty(LayeredOptions.NO_LAYOUT) as? Bool ?? false) && !elklabel.text.isEmpty {
                lnode.labels.append(transformLabel(elklabel))
            }
        }

        if lnode.getProperty(LayeredOptions.COMMENT_BOX) as? Bool ?? false {
            graphProperties.insert(.COMMENTS)
        }

        if lnode.getProperty(LayeredOptions.HYPERNODE) as? Bool ?? false {
            graphProperties.insert(.HYPERNODES)
            graphProperties.insert(.HYPEREDGES)
            lnode.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FREE)
        }

        lgraph.setProperty(InternalProperties.GRAPH_PROPERTIES, graphProperties)
        return lnode
    }
    
    @discardableResult
    package func transformPort(_ elkport: ElkPort, _ parentLNode: LNode,
                               _ graphProperties: inout Set<GraphProperties>, _ layoutDirection: Direction,
                               _ portConstraints: PortConstraints) -> LPort {
        let lport = LPort()
        lport.copyProperties(elkport)
        lport.side = elkport.getProperty(LayeredOptions.PORT_SIDE) as? PortSide ?? .UNDEFINED
        lport.setProperty(InternalProperties.ORIGIN, elkport)
        lport.setNode(parentLNode)
        
        lport.size.x = elkport.width
        lport.size.y = elkport.height
        
        lport.position.x = elkport.x
        lport.position.y = elkport.y
        
        self[elkport as AnyObject] = lport
        
        var connectionsToDescendants = false
        if let portParent = elkport.parent {
            connectionsToDescendants = elkport.outgoingEdges
                .flatMap { $0.targets }
                .map { ElkGraphUtil.connectableShapeToNode($0) }
                .contains(where: { ElkGraphUtil.isDescendant($0, portParent) })

            if !connectionsToDescendants {
                connectionsToDescendants = elkport.incomingEdges
                    .flatMap { $0.sources }
                    .map { ElkGraphUtil.connectableShapeToNode($0) }
                    .contains(where: { ElkGraphUtil.isDescendant($0, portParent) })
            }
        }

        if !connectionsToDescendants {
            connectionsToDescendants = elkport.outgoingEdges.contains(where: { $0.isSelfloop() && ($0.getProperty(LayeredOptions.INSIDE_SELF_LOOPS_YO) as? Bool ?? false) })
        }
        
        lport.setProperty(InternalProperties.INSIDE_CONNECTIONS, connectionsToDescendants)
        
        LGraphUtil.initializePort(lport, portConstraints, layoutDirection,
            elkport.getProperty(LayeredOptions.PORT_ANCHOR) as? KVector)
        
        for elklabel in elkport.labels {
            if !(elklabel.getProperty(LayeredOptions.NO_LAYOUT) as? Bool ?? false) && !elklabel.text.isEmpty {
                lport.labels.append(transformLabel(elklabel))
            }
        }
        
        switch layoutDirection {
        case .LEFT, .RIGHT:
            if lport.side == .NORTH || lport.side == .SOUTH {
                graphProperties.insert(.NORTH_SOUTH_PORTS)
            }
        case .UP, .DOWN:
            if lport.side == .EAST || lport.side == .WEST {
                graphProperties.insert(.NORTH_SOUTH_PORTS)
            }
        default:
            break
        }
        
        return lport
    }
    
    @discardableResult
    package func transformEdge(_ elkedge: ElkEdge, _ elkparent: ElkNode, _ lgraph: LGraph) throws -> LEdge {
        try checkEdgeValidity(elkedge)
        
        let elkSourceShape = elkedge.sources[0]
        let elkTargetShape = elkedge.targets[0]
        let elkSourceNode = ElkGraphUtil.connectableShapeToNode(elkSourceShape)
        let elkTargetNode = ElkGraphUtil.connectableShapeToNode(elkTargetShape)
        
        let edgeSection = elkedge.sections.isEmpty ? nil : elkedge.sections[0]
        
        var sourceLNode = self[elkSourceNode as AnyObject] as? LNode
        var targetLNode = self[elkTargetNode as AnyObject] as? LNode
        var sourceLPort: LPort? = nil
        var targetLPort: LPort? = nil
        
        if let elkSourceShape = elkSourceShape as? ElkPort {
            let sourceElem = self[elkSourceShape as AnyObject]
            if let sourceLPortValue = sourceElem as? LPort {
                sourceLPort = sourceLPortValue
            } else if let sourceLNodeValue = sourceElem as? LNode {
                sourceLNode = sourceLNodeValue
                sourceLPort = sourceLNodeValue.ports[0]
            }
        }
        
        if let elkTargetShape = elkTargetShape as? ElkPort {
            let targetElem = self[elkTargetShape as AnyObject]
            if let targetLPortValue = targetElem as? LPort {
                targetLPort = targetLPortValue
            } else if let targetLNodeValue = targetElem as? LNode {
                targetLNode = targetLNodeValue
                targetLPort = targetLNodeValue.ports[0]
            }
        }
        
        guard let sourceLNode = sourceLNode, let targetLNode = targetLNode else {
            assertionFailure("The source or the target of edge could not be found.")
            return LEdge()
        }

        let ledge = LEdge()
        ledge.copyProperties(elkedge)
        ledge.setProperty(InternalProperties.ORIGIN, elkedge)
        ledge.setProperty(LayeredOptions.JUNCTION_POINTS, nil)

        var graphProperties = lgraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []
        if sourceLNode === targetLNode {
            graphProperties.insert(.SELF_LOOPS)
        }

        if sourceLPort == nil {
            var portType = PortType.OUTPUT
            var sourcePoint: KVector? = nil

            if let edgeSection = edgeSection, (sourceLNode.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .UNDEFINED).isSideFixed() {
                sourcePoint = KVector(edgeSection.startX, edgeSection.startY)
                if let sourcePoint = sourcePoint {
                    let _ = ElkUtil.toAbsolute(sourcePoint, parent: elkedge.containingNode)
                    let _ = ElkUtil.toRelative(sourcePoint, parent: elkparent)
                }

                if ElkGraphUtil.isDescendant(elkTargetNode, elkSourceNode) {
                    portType = PortType.INPUT
                    sourcePoint?.add(sourceLNode.position)
                }
            }
            sourceLPort = LGraphUtil.createPort(sourceLNode, sourcePoint, portType, lgraph)
        }

        if targetLPort == nil {
            let portType = PortType.INPUT
            var targetPoint: KVector? = nil

            if let edgeSection = edgeSection, (targetLNode.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .UNDEFINED).isSideFixed() {
                targetPoint = KVector(edgeSection.endX, edgeSection.endY)
                if let targetPoint = targetPoint {
                    let _ = ElkUtil.toAbsolute(targetPoint, parent: elkedge.containingNode)
                    let _ = ElkUtil.toRelative(targetPoint, parent: elkparent)
                }
            }

            targetLPort = LGraphUtil.createPort(targetLNode, targetPoint, portType, targetLNode.graph ?? lgraph)
        }

        ledge.setSource(sourceLPort)
        ledge.setTarget(targetLPort)

        if let sourceLPort = sourceLPort, let targetLPort = targetLPort {
            if sourceLPort.incomingEdges.count > 1 || sourceLPort.outgoingEdges.count > 1 ||
                targetLPort.incomingEdges.count > 1 || targetLPort.outgoingEdges.count > 1 {
                graphProperties.insert(.HYPEREDGES)
            }
        }

        for elklabel in elkedge.labels {
            if !(elklabel.getProperty(LayeredOptions.NO_LAYOUT) as? Bool ?? false) && !elklabel.text.isEmpty {
                let llabel = transformLabel(elklabel)
                ledge.labels.append(llabel)

                let labelPlacement = llabel.getProperty(LayeredOptions.EDGE_LABELS_PLACEMENT) as? EdgeLabelPlacement ?? .center
                switch labelPlacement {
                case .head, .tail:
                    graphProperties.insert(.END_LABELS)
                case .center:
                    graphProperties.insert(.CENTER_LABELS)
                    llabel.setProperty(LayeredOptions.EDGE_LABELS_PLACEMENT, EdgeLabelPlacement.center)
                }
            }
        }

        lgraph.setProperty(InternalProperties.GRAPH_PROPERTIES, graphProperties)

        let crossMinStrat = lgraph.getProperty(LayeredOptions.CROSSING_MINIMIZATION_STRATEGY) as? CrossingMinimizationStrategy ?? .LAYER_SWEEP
        let nodePlaceStrat = lgraph.getProperty(LayeredOptions.NODE_PLACEMENT_STRATEGY) as? NodePlacementStrategy ?? .BRANDES_KOEPF
        let bendPointsRequired = crossMinStrat == .INTERACTIVE || nodePlaceStrat == .INTERACTIVE

        if let edgeSection = edgeSection, !edgeSection.bendPoints.isEmpty && bendPointsRequired {
            let originalBendpoints = ElkUtil.createVectorChain(edgeSection)
            let importedBendpoints = KVectorChain()

            for point in originalBendpoints {
                importedBendpoints.add(KVector(point.x, point.y))
            }
            ledge.setProperty(InternalProperties.ORIGINAL_BENDPOINTS, importedBendpoints)
        }

        return ledge
    }
    
    package func checkEdgeValidity(_ edge: ElkEdge) throws {
        if edge.sources.isEmpty {
            throw ELK.Error.runtimeError("Edges must have a source.")
        } else if edge.targets.isEmpty {
            throw ELK.Error.runtimeError("Edges must have a target.")
        } else if edge.isHyperedge() {
            throw ELK.Error.runtimeError("Hyperedges are not supported.")
        }
    }
    
    package func transformLabel(_ elklabel: ElkLabel) -> LLabel {
        let newLabel = LLabel(elklabel.text)
        newLabel.copyProperties(elklabel)
        newLabel.setProperty(InternalProperties.ORIGIN, elklabel)
        
        newLabel.size.x = elklabel.width
        newLabel.size.y = elklabel.height
        newLabel.position.x = elklabel.x
        newLabel.position.y = elklabel.y
        
        return newLabel
    }
}
