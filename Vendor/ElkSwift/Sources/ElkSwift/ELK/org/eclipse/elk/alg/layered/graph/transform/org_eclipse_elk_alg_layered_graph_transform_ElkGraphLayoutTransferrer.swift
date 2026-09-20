// This file was transpiled from Java to Swift using an automated tool.
// Manual review and adjustments may be required for production use.

import Foundation

// MARK: - Supporting Types and Constants

package let ZERO_OFFSET = KVector(x: 0.0, y: 0.0)

// MARK: - Main Class

package class ElkGraphLayoutTransferrer {
    
    package func apply(_ lgraph: LGraph) {
        guard let graphOrigin = lgraph.getProperty(InternalProperties.ORIGIN) as? ElkNode else {
            return
        }

        
        let parentElkNode = graphOrigin
        let parentLNode = lgraph.getParentNode()
        
        let offset = KVector(lgraph.getOffset())
        
        let lPadding = lgraph.getPadding()
        offset.x += lPadding.left
        offset.y += lPadding.top
        
        let sizeOptions = parentElkNode.getProperty(LayeredOptions.NODE_SIZE_OPTIONS) as? SizeOptions ?? []
        if sizeOptions.contains(.computePadding) {
            if let padding = parentElkNode.getProperty(LayeredOptions.PADDING) as? ElkPadding {
                padding.bottom = lPadding.bottom
                padding.top = lPadding.top
                padding.left = lPadding.left
                padding.right = lPadding.right
            }
        }
        
        var edgeList: [LEdge] = []
        
        for lnode in lgraph.getLayerlessNodes() {
            if Self.representsNode(lnode) {
                applyNodeLayout(lnode, offset: offset)
            } else if Self.representsExternalPort(lnode) && parentLNode == nil {
                if let elkport = lnode.getProperty(InternalProperties.ORIGIN) as? ElkPort {
                    let portPosition = LGraphUtil.getExternalPortPosition(lgraph, lnode, elkport.width, elkport.height)
                    elkport.setLocation(x: portPosition.x, y: portPosition.y)
                }
            }
            
            for port in lnode.getPorts() {
                let outgoingEdges = port.getOutgoingEdges().filter { edge in
                    !LGraphUtil.isDescendant(edge.target?.node, lnode)
                }
                edgeList.append(contentsOf: outgoingEdges)
            }
        }
        
        if let parentLNode = parentLNode {
            for port in parentLNode.getPorts() {
                let outgoingEdges = port.getOutgoingEdges().filter { edge in
                    LGraphUtil.isDescendant(edge.target?.node, parentLNode)
                }
                edgeList.append(contentsOf: outgoingEdges)
            }
        }
        
        let routing: EdgeRouting = parentElkNode.getProperty(LayeredOptions.EDGE_ROUTING) as? EdgeRouting ?? .UNDEFINED
        for ledge in edgeList {
            applyEdgeLayout(ledge, routing: routing, offset: offset, additionalPadding: lPadding)
        }
        
        applyParentNodeLayout(lgraph)

        for lnode in lgraph.getLayerlessNodes() {
            if let nestedGraph = lnode.getNestedGraph() {
                apply(nestedGraph)
            }
        }
    }
    
    package func applyNodeLayout(_ lnode: LNode, offset: KVector) {
        guard let elknode = lnode.getProperty(InternalProperties.ORIGIN) as? ElkNode else {
            return
        }
        
        let nodeID = lnode.getProperty(LayeredOptions.CROSSING_MINIMIZATION_POSITION_ID)
        let layerID = lnode.getProperty(LayeredOptions.LAYERING_LAYER_ID)
        elknode.setProperty(LayeredOptions.CROSSING_MINIMIZATION_POSITION_ID, nodeID)
        elknode.setProperty(LayeredOptions.LAYERING_LAYER_ID, layerID)

        let position = lnode.getPosition()
        elknode.x = position.x + offset.x
        elknode.y = position.y + offset.y

        let sizeConstraints = elknode.getProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS) as? SizeConstraint ?? []
        let hasNestedGraph = lnode.getNestedGraph() != nil
        let nodePlacementStrategy = lnode.getGraph()?.getProperty(LayeredOptions.NODE_PLACEMENT_STRATEGY) as? NodePlacementStrategy
        let nodeFlexibility = NodeFlexibility.getNodeFlexibility(lnode)
        let isFlexibleSizeWhereSpacePermits = nodeFlexibility.isFlexibleSizeWhereSpacePermits()

        if !sizeConstraints.isEmpty || hasNestedGraph ||
            (nodePlacementStrategy == .NETWORK_SIMPLEX && isFlexibleSizeWhereSpacePermits) {
            let size = lnode.getSize()
            elknode.width = size.x
            elknode.height = size.y
        }

        for lport in lnode.getPorts() {
            if let origin = lport.getProperty(InternalProperties.ORIGIN) as? ElkPort {
                let position = lport.getPosition()
                origin.setLocation(x: position.x, y: position.y)
                origin.setProperty(LayeredOptions.PORT_SIDE, lport.getSide())
            }
        }

        let nodeHasLabelPlacement = !(lnode.getProperty(LayeredOptions.NODE_LABELS_PLACEMENT) as? NodeLabelPlacement ?? []).isEmpty

        for llabel in lnode.getLabels() {
            if nodeHasLabelPlacement || !(llabel.getProperty(LayeredOptions.NODE_LABELS_PLACEMENT) as? NodeLabelPlacement ?? []).isEmpty {
                if let elklabel = llabel.getProperty(InternalProperties.ORIGIN) as? ElkLabel {
                    let size = llabel.getSize()
                    elklabel.setDimensions(width: size.x, height: size.y)
                    let position = llabel.getPosition()
                    elklabel.setLocation(x: position.x, y: position.y)
                }
            }
        }

        let portLabelPlacement = lnode.getProperty(LayeredOptions.PORT_LABELS_PLACEMENT) as? PortLabelPlacement ?? []
        if !PortLabelPlacement.isFixed(portLabelPlacement) {
            for lport in lnode.getPorts() {
                for llabel in lport.getLabels() {
                    if let elklabel = llabel.getProperty(InternalProperties.ORIGIN) as? ElkLabel {
                        let size = llabel.getSize()
                        elklabel.setDimensions(width: size.x, height: size.y)
                        let position = llabel.getPosition()
                        elklabel.setLocation(x: position.x, y: position.y)
                    }
                }
            }
        }
    }
    
    package func applyEdgeLayout(_ ledge: LEdge, routing: EdgeRouting, offset: KVector, additionalPadding: LPadding) {
        guard let elkedge = ledge.getProperty(InternalProperties.ORIGIN) as? ElkEdge else {
            return
        }


        let bendPoints = ledge.getBendPoints()
        let edgeOffset = KVector(offset)
        edgeOffset.add(calculateHierarchicalOffset(ledge))

        var sourcePoint: KVector
        if LGraphUtil.isDescendant(ledge.target?.node, ledge.source?.node) {
            let sourcePort = ledge.source
            sourcePoint = KVector(sourcePort?.position ?? KVector())
            sourcePoint.add(sourcePort?.anchor ?? KVector())
            sourcePoint.sub(offset)
        } else {
            sourcePoint = ledge.source?.getAbsoluteAnchor() ?? KVector()
        }
        bendPoints.addFirst(sourcePoint)

        let targetPoint = ledge.target?.getAbsoluteAnchor() ?? KVector()
        if let targetOffset = ledge.getProperty(InternalProperties.TARGET_OFFSET) as? KVector {
            targetPoint.add(targetOffset)
        }
        bendPoints.addLast(targetPoint)

        bendPoints.offset(edgeOffset)

        let elkedgeSection = ElkGraphUtil.firstEdgeSection(elkedge, create: true, createSource: true, createTarget: true)
        elkedgeSection.incomingShape = elkedge.sources[0]
        elkedgeSection.outgoingShape = elkedge.targets[0]
        ElkUtil.applyVectorChain(bendPoints, section: elkedgeSection)

        for llabel in ledge.getLabels() {
            if let elklabel = llabel.getProperty(InternalProperties.ORIGIN) as? ElkLabel {
                let size = llabel.getSize()
                elklabel.setDimensions(width: size.x, height: size.y)
                let position = llabel.getPosition()
                elklabel.setLocation(x: position.x + edgeOffset.x, y: position.y + edgeOffset.y)
            }
        }

        if let junctionPoints = ledge.getProperty(LayeredOptions.JUNCTION_POINTS) as? KVectorChain {
            let junctionPointsCopy = junctionPoints
            junctionPointsCopy.offset(edgeOffset)
            elkedge.setProperty(LayeredOptions.JUNCTION_POINTS, junctionPointsCopy)
        } else {
            elkedge.setProperty(LayeredOptions.JUNCTION_POINTS, nil)
        }

        if routing == .SPLINES {
            elkedge.setProperty(LayeredOptions.EDGE_ROUTING, EdgeRouting.SPLINES)
        } else {
            elkedge.setProperty(LayeredOptions.EDGE_ROUTING, nil)
        }
    }
    
    package func calculateHierarchicalOffset(_ ledge: LEdge) -> KVector {
        guard let targetCoordinateSystem = ledge.getProperty(InternalProperties.COORDINATE_SYSTEM_ORIGIN) as? LGraph else {
            return ZERO_OFFSET
        }

        let result = KVector(x: 0.0, y: 0.0)
        var currentGraph: LGraph? = ledge.source?.node?.graph

        while let cg = currentGraph, cg !== targetCoordinateSystem {
            guard let representingNode = cg.getParentNode() else {
                break
            }
            currentGraph = representingNode.graph

            result.add(representingNode.position)
            if let g = currentGraph {
                result.add(g.getOffset())
                result.add(g.getPadding().left, g.getPadding().top)
            }
        }

        return result
    }
    
    package func applyParentNodeLayout(_ lgraph: LGraph) {
        guard let elknode = lgraph.getProperty(InternalProperties.ORIGIN) as? ElkNode else {
            return
        }
        
        let sizeConstraints = elknode.getProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS) as? SizeConstraint ?? []
        let sizeConstraintsIncludedPortLabels = sizeConstraints.contains(.portLabels)

        if lgraph.getParentNode() == nil {
            let graphProps = lgraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []
            let actualGraphSize = lgraph.getActualSize()

            if graphProps.contains(.EXTERNAL_PORTS) {
                elknode.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FIXED_POS)
                let _ = ElkUtil.resizeNode(elknode, newWidth: actualGraphSize.x, newHeight: actualGraphSize.y, movePorts: false, moveLabels: true)
            } else {
                if !(elknode.getProperty(LayeredOptions.NODE_SIZE_FIXED_GRAPH_SIZE) as? Bool ?? false) {
                    let _ = ElkUtil.resizeNode(elknode, newWidth: actualGraphSize.x, newHeight: actualGraphSize.y, movePorts: true, moveLabels: true)
                }
            }
        }

        if sizeConstraintsIncludedPortLabels {
            elknode.setProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS, SizeConstraint.portLabels)
        } else {
            elknode.setProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS, SizeConstraint.fixed)
        }
    }

    package static func representsNode(_ lnode: LNode) -> Bool {
        return lnode.getProperty(InternalProperties.ORIGIN) is ElkNode
    }
    
    package static func representsExternalPort(_ lnode: LNode) -> Bool {
        return lnode.getProperty(InternalProperties.ORIGIN) is ElkPort
    }
    
    // MARK: - Non-Mutating Layout Application
    
    package func applyLayoutNonMutating(_ lgraph: LGraph) -> ElkNode {
        let parentElkNode = ElkGraphUtil.createGraph()
        return ElkGraphLayoutTransferrer.applyLayoutNonMutating(lgraph, parentElkNode)
    }
    
    @discardableResult
    package static func applyLayoutNonMutating(_ lgraph: LGraph, _ parentElkNode: ElkNode) -> ElkNode {
        let parentElkNode = parentElkNode
        let parentLNode = lgraph.getParentNode()
        
        let offset = lgraph.getOffset().clone()
        let lPadding = lgraph.getPadding()
        offset.x += lPadding.left
        offset.y += lPadding.top
        
        let sizeOptions = parentElkNode.getProperty(LayeredOptions.NODE_SIZE_OPTIONS) as? SizeOptions ?? []
        if sizeOptions.contains(.computePadding) {
            if let padding = parentElkNode.getProperty(LayeredOptions.PADDING) as? ElkPadding {
                padding.bottom = lPadding.bottom
                padding.top = lPadding.top
                padding.left = lPadding.left
                padding.right = lPadding.right
            }
        }
        
        var edgeList: [LEdge] = []
        let nodes = collectNodes(lgraph)
        
        for lnode in nodes {
            var elkNode: ElkNode?
            if representsNode(lnode) {
                let createdNode = ElkGraphUtil.createNode(parentElkNode)
                elkNode = createdNode
                applyNodeLayout(lnode, elknode: createdNode, offset: offset)
            } else if representsExternalPort(lnode) && parentLNode == nil {
                if let elkport = lnode.getProperty(InternalProperties.ORIGIN) as? ElkPort {
                    let portPosition = LGraphUtil.getExternalPortPosition(lgraph, lnode, elkport.width, elkport.height)
                    elkport.setLocation(x: portPosition.x, y: portPosition.y)
                }
            }
            
            for port in lnode.getPorts() {
                let outgoingEdges = port.getOutgoingEdges().filter { edge in
                    !LGraphUtil.isDescendant(edge.target?.node, lnode)
                }
                edgeList.append(contentsOf: outgoingEdges)
            }
            
            if let nestedGraph = lnode.getNestedGraph(), let elkNode = elkNode {
                applyLayoutNonMutating(nestedGraph, elkNode)
                parentElkNode.children.append(elkNode)
            }
        }
        
        if let parentLNode = parentLNode {
            for port in parentLNode.getPorts() {
                let outgoingEdges = port.getOutgoingEdges().filter { edge in
                    LGraphUtil.isDescendant(edge.target?.node, parentLNode)
                }
                edgeList.append(contentsOf: outgoingEdges)
            }
        }
        
        let routing = parentElkNode.getProperty(LayeredOptions.EDGE_ROUTING) as? EdgeRouting ?? .UNDEFINED
        for ledge in edgeList {
            let elkedge = ElkGraphUtil.createEdge(parentElkNode)
            applyEdgeLayout(ledge, elkedge: elkedge, routing: routing, offset: offset, additionalPadding: lPadding)
        }
        
        applyParentNodeLayout(lgraph, parentElkNode)
        return parentElkNode
    }
    
    package static func collectNodes(_ lgraph: LGraph) -> [LNode] {
        var nodes: [LNode] = []
        
        for layer in lgraph.getLayers() {
            for lNode in layer.getNodes() {
                if representsNode(lNode) {
                    nodes.append(lNode)
                } else if representsExternalPort(lNode) {
                    continue
                } else {
                    continue
                }
            }
        }
        
        for lNode in lgraph.getLayerlessNodes() {
            if representsNode(lNode) {
                nodes.append(lNode)
            } else if representsExternalPort(lNode) {
                continue
            } else {
                continue
            }
        }
        
        return nodes
    }
    
    package static func applyNodeLayout(_ lnode: LNode, elknode: ElkNode, offset: KVector) {
        let nodeID = lnode.getProperty(LayeredOptions.CROSSING_MINIMIZATION_POSITION_ID)
        let layerID = lnode.getProperty(LayeredOptions.LAYERING_LAYER_ID)
        elknode.setProperty(LayeredOptions.CROSSING_MINIMIZATION_POSITION_ID, nodeID)
        elknode.setProperty(LayeredOptions.LAYERING_LAYER_ID, layerID)

        let position = lnode.getPosition()
        elknode.x = position.x + offset.x
        elknode.y = position.y + offset.y

        let sizeConstraints = elknode.getProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS) as? SizeConstraint ?? []
        let hasNestedGraph = lnode.getNestedGraph() != nil
        let nodePlacementStrategy = lnode.getGraph()?.getProperty(LayeredOptions.NODE_PLACEMENT_STRATEGY) as? NodePlacementStrategy
        let nodeFlexibility = NodeFlexibility.getNodeFlexibility(lnode)
        let isFlexibleSizeWhereSpacePermits = nodeFlexibility.isFlexibleSizeWhereSpacePermits()

        if !sizeConstraints.isEmpty || hasNestedGraph ||
            (nodePlacementStrategy == .NETWORK_SIMPLEX && isFlexibleSizeWhereSpacePermits) {
            let size = lnode.getSize()
            elknode.width = size.x
            elknode.height = size.y
        }

        for lport in lnode.getPorts() {
            let elkport = ElkGraphUtil.createPort(elknode)
            let position = lport.getPosition()
            elkport.setLocation(x: position.x, y: position.y)
            elkport.setProperty(LayeredOptions.PORT_SIDE, lport.getSide())

            let portLabelPlacement = lnode.getProperty(LayeredOptions.PORT_LABELS_PLACEMENT) as? PortLabelPlacement ?? []
            if !PortLabelPlacement.isFixed(portLabelPlacement) {
                for llabel in lport.getLabels() {
                    let elklabel = ElkGraphUtil.createLabel(elkport)
                    let size = llabel.getSize()
                    elklabel.setDimensions(width: size.x, height: size.y)
                    let position = llabel.getPosition()
                    elklabel.setLocation(x: position.x, y: position.y)
                }
            }
        }

        let nodeHasLabelPlacement = !(lnode.getProperty(LayeredOptions.NODE_LABELS_PLACEMENT) as? NodeLabelPlacement ?? []).isEmpty

        for llabel in lnode.getLabels() {
            if nodeHasLabelPlacement || !(llabel.getProperty(LayeredOptions.NODE_LABELS_PLACEMENT) as? NodeLabelPlacement ?? []).isEmpty {
                let elklabel = ElkGraphUtil.createLabel(elknode)
                let size = llabel.getSize()
                elklabel.setDimensions(width: size.x, height: size.y)
                let position = llabel.getPosition()
                elklabel.setLocation(x: position.x, y: position.y)
            }
        }
    }
    
    package static func applyEdgeLayout(_ ledge: LEdge, elkedge: ElkEdge, routing: EdgeRouting, offset: KVector, additionalPadding: LPadding) {
        var bendPoints = ledge.getBendPoints().clone()

        let edgeOffset = KVector(offset)
        edgeOffset.add(calculateHierarchicalOffsetNonMutating(ledge))

        var sourcePoint: KVector
        if LGraphUtil.isDescendant(ledge.target?.node, ledge.source?.node) {
            let sourcePort = ledge.source
            sourcePoint = KVector(sourcePort?.position ?? KVector())
            sourcePoint.add(sourcePort?.anchor ?? KVector())
            sourcePoint.sub(offset)
        } else {
            sourcePoint = ledge.source?.getAbsoluteAnchor() ?? KVector()
        }
        bendPoints.addFirst(sourcePoint)

        let targetPoint = ledge.target?.getAbsoluteAnchor() ?? KVector()
        if let targetOffset = ledge.getProperty(InternalProperties.TARGET_OFFSET) as? KVector {
            targetPoint.add(targetOffset)
        }
        bendPoints.addLast(targetPoint)

        bendPoints = bendPoints.offsetNonMutating(edgeOffset)

        let elkedgeSection = ElkGraphUtil.firstEdgeSection(elkedge, create: true, createSource: true, createTarget: true)
        ElkUtil.applyVectorChain(bendPoints, section: elkedgeSection)

        for llabel in ledge.getLabels() {
            let elklabel = ElkGraphUtil.createLabel(elkedge)
            let size = llabel.getSize()
            elklabel.setDimensions(width: size.x, height: size.y)
            let position = llabel.getPosition()
            elklabel.setLocation(x: position.x + edgeOffset.x, y: position.y + edgeOffset.y)
        }

        if let junctionPoints = ledge.getProperty(LayeredOptions.JUNCTION_POINTS) as? KVectorChain {
            let junctionPointsCopy = junctionPoints.clone().offsetNonMutating(edgeOffset)
            elkedge.setProperty(LayeredOptions.JUNCTION_POINTS, junctionPointsCopy)
        } else {
            elkedge.setProperty(LayeredOptions.JUNCTION_POINTS, nil)
        }

        if routing == .SPLINES {
            elkedge.setProperty(LayeredOptions.EDGE_ROUTING, EdgeRouting.SPLINES)
        } else {
            elkedge.setProperty(LayeredOptions.EDGE_ROUTING, nil)
        }
    }
    
    package static func calculateHierarchicalOffsetNonMutating(_ ledge: LEdge) -> KVector {
        guard let targetCoordinateSystem = ledge.getProperty(InternalProperties.COORDINATE_SYSTEM_ORIGIN) as? LGraph else {
            return ZERO_OFFSET
        }

        let result = KVector(x: 0.0, y: 0.0)
        var currentGraph: LGraph? = ledge.source?.node?.graph

        while let cg = currentGraph, cg !== targetCoordinateSystem {
            guard let representingNode = cg.getParentNode() else {
                break
            }
            currentGraph = representingNode.graph

            result.add(representingNode.position)
            if let g = currentGraph {
                result.add(g.getOffset())
                result.add(g.getPadding().left, g.getPadding().top)
            }
        }

        return result
    }
    
    package static func applyParentNodeLayout(_ lgraph: LGraph, _ elknode: ElkNode) {
        let sizeConstraints = elknode.getProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS) as? SizeConstraint ?? []
        let sizeConstraintsIncludedPortLabels = sizeConstraints.contains(.portLabels)

        if lgraph.getParentNode() == nil {
            let graphProps = lgraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []
            let actualGraphSize = lgraph.getActualSize()

            if graphProps.contains(.EXTERNAL_PORTS) {
                elknode.setProperty(LayeredOptions.PORT_CONSTRAINTS, PortConstraints.FIXED_POS)
                let _ = ElkUtil.resizeNode(elknode, newWidth: actualGraphSize.x, newHeight: actualGraphSize.y, movePorts: false, moveLabels: true)
            } else {
                if !(elknode.getProperty(LayeredOptions.NODE_SIZE_FIXED_GRAPH_SIZE) as? Bool ?? false) {
                    let _ = ElkUtil.resizeNode(elknode, newWidth: actualGraphSize.x, newHeight: actualGraphSize.y, movePorts: true, moveLabels: true)
                }
            }
        }

        if sizeConstraintsIncludedPortLabels {
            elknode.setProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS, SizeConstraint.portLabels)
        } else {
            elknode.setProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS, SizeConstraint.fixed)
        }
    }
}
