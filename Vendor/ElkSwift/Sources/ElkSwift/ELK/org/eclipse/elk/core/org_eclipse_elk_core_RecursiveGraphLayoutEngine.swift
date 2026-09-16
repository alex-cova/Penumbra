/*******************************************************************************
 * Copyright (c) 2008, 2018 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 ******************************************************************************/
// Translated to Swift

import Foundation

// MARK: - Main Class

package class RecursiveGraphLayoutEngine: IGraphLayoutEngine {

    package init() {}

    package func layout(layoutGraph: ElkNode, progressMonitor: IElkProgressMonitor) throws {
        try layout(layoutGraph, nil, progressMonitor)
    }

    package func layout(_ layoutGraph: ElkNode, _ testController: TestController?, _ progressMonitor: IElkProgressMonitor) throws {

        let nodeCount = countNodesRecursively(layoutGraph, true)
        let _ = progressMonitor.begin("Recursive Graph Layout", Float(nodeCount))

        // Apply deprecated layout option replacer
        try ElkUtil.applyVisitors(layoutGraph, visitors: [DeprecatedLayoutOptionReplacer()])

        if !layoutGraph.hasProperty(CoreOptions.RESOLVED_ALGORITHM) {
            // Apply the default algorithm resolver to the graph
            try ElkUtil.applyVisitors(layoutGraph, visitors: [LayoutAlgorithmResolver()])
        }

        // Perform recursive layout of the whole substructure of the given node
        let _ = try layoutRecursively(layoutGraph, testController, progressMonitor)

        progressMonitor.done()
    }

    @discardableResult
    package func layoutRecursively(_ layoutNode: ElkNode, _ testController: TestController?, _ progressMonitor: IElkProgressMonitor) throws -> [ElkEdge] {

        if progressMonitor.isCanceled() {
            return []
        }

        // Check if the node should be laid out at all
        let noLayout: Bool = layoutNode.getProperty(CoreOptions.NO_LAYOUT) ?? false
        if noLayout {
            return []
        }

        let hasChildren = !layoutNode.children.isEmpty
        let insideSelfLoops = gatherInsideSelfLoops(layoutNode)
        let hasInsideSelfLoops = !insideSelfLoops.isEmpty

        if hasChildren || hasInsideSelfLoops {
            guard let algorithmData: LayoutAlgorithmData = layoutNode.getProperty(CoreOptions.RESOLVED_ALGORITHM) else {
                assertionFailure("Resolved algorithm is not set; apply a LayoutAlgorithmResolver before computing layout.")
                return []
            }

            let supportsInsideSelfLoops = algorithmData.supportsFeature(GraphFeature.insideSelfLoops)

            evaluateHierarchyHandlingInheritance(layoutNode)

            if !hasChildren && hasInsideSelfLoops && !supportsInsideSelfLoops {
                return []
            }

            var childrenInsideSelfLoops: [ElkEdge] = []

            let hierarchyHandling: HierarchyHandling = layoutNode.getProperty(CoreOptions.HIERARCHY_HANDLING) ?? .separateChildren
            if hierarchyHandling == .includeChildren &&
                (algorithmData.supportsFeature(GraphFeature.compound) || algorithmData.supportsFeature(GraphFeature.clusters)) {

                let topdownLayout: Bool = layoutNode.getProperty(CoreOptions.TOPDOWN_LAYOUT) ?? false
                if topdownLayout {
                    throw ELK.Error.runtimeError("Topdown layout cannot be used together with hierarchy handling.")
                }

                _ = countNodesWithHierarchy(layoutNode)

                var nodeQueue = ArrayDeque<ElkNode>(Array(layoutNode.children))

                while !nodeQueue.isEmpty {
                    let node = nodeQueue.removeFirst()
                    evaluateHierarchyHandlingInheritance(node)
                    let nodeHH: HierarchyHandling = node.getProperty(CoreOptions.HIERARCHY_HANDLING) ?? .separateChildren
                    let stopHierarchy = nodeHH == .separateChildren
                    let hasAlg = node.hasProperty(CoreOptions.ALGORITHM)
                    let algMatch = nodeResolvedAlgorithmEquals(node, algorithmData)

                    if stopHierarchy ||
                        (hasAlg && !algMatch) {

                        let childLayoutSelfLoops = try layoutRecursively(node, testController, progressMonitor)
                        childrenInsideSelfLoops.append(contentsOf: childLayoutSelfLoops)
                        node.setProperty(CoreOptions.HIERARCHY_HANDLING, HierarchyHandling.separateChildren)
                        ElkUtil.applyConfiguredNodeScaling(node)
                    } else {
                        nodeQueue.append(contentsOf: node.children)
                    }
                }
            } else {
                let nodeCount = layoutNode.children.count

                let topdownLayout: Bool = layoutNode.getProperty(CoreOptions.TOPDOWN_LAYOUT) ?? false
                if topdownLayout {
                    let topdownLayoutMonitor = progressMonitor.subTask(1)
                    let _ = topdownLayoutMonitor?.begin("Topdown Layout", 1)

                    let topdownNodeType: TopdownNodeTypes? = layoutNode.getProperty(CoreOptions.TOPDOWN_NODE_TYPE)
                    if topdownNodeType == nil {
                        throw ELK.Error.runtimeError("\(layoutNode.identifier ?? "<unknown>") has not been assigned a top-down node type.")
                    }

                    if topdownNodeType == .HIERARCHICAL_NODE ||
                        topdownNodeType == .ROOT_NODE {

                        for childNode in layoutNode.children {
                            let localAlgorithmData: LayoutAlgorithmData? = childNode.getProperty(CoreOptions.RESOLVED_ALGORITHM)
                            let padding: ElkPadding = childNode.getProperty(CoreOptions.PADDING) ?? ElkPadding()

                            if childNode.children.count > 0,
                                let localAlgData = localAlgorithmData,
                                let _ = localAlgData.getInstancePool().fetch() as? ITopdownLayoutProvider {

                                let childNodeType: TopdownNodeTypes? = childNode.getProperty(CoreOptions.TOPDOWN_NODE_TYPE)
                                if childNodeType == .HIERARCHICAL_NODE {
                                    throw ELK.Error.runtimeError("Topdown Layout Providers should only be used on parallel nodes.")
                                }

                                guard let topdownLayoutProvider = localAlgData.getInstancePool().fetch() as? ITopdownLayoutProvider else { continue }
                                let requiredSize = topdownLayoutProvider.getPredictedGraphSize(childNode)
                                childNode.setDimensions(
                                    width: max(childNode.width, requiredSize.x),
                                    height: max(childNode.height, requiredSize.y)
                                )
                            } else if childNode.children.count > 0 {
                                let approximatorAny: Any? = childNode.getProperty(CoreOptions.TOPDOWN_SIZE_APPROXIMATOR)
                                if let approximator = approximatorAny as? ITopdownLayoutProvider {
                                    let size = approximator.getPredictedGraphSize(childNode)
                                    childNode.setDimensions(
                                        width: max(childNode.width, size.x + padding.left + padding.right),
                                        height: max(childNode.height, size.y + padding.top + padding.bottom)
                                    )
                                } else if !childNode.children.isEmpty {
                                    let widthVal: Double = childNode.getProperty(CoreOptions.TOPDOWN_HIERARCHICAL_NODE_WIDTH) ?? 150.0
                                    let aspectRatio: Double = childNode.getProperty(CoreOptions.TOPDOWN_HIERARCHICAL_NODE_ASPECT_RATIO) ?? 1.4142135623730951
                                    let size = KVector(widthVal, widthVal / aspectRatio)
                                    childNode.setDimensions(
                                        width: max(childNode.width, size.x + padding.left + padding.right),
                                        height: max(childNode.height, size.y + padding.top + padding.bottom)
                                    )
                                }
                            }
                        }
                    }

                    let padding: ElkPadding = layoutNode.getProperty(CoreOptions.PADDING) ?? ElkPadding()
                    let childAreaAvailableWidth = layoutNode.width - (padding.left + padding.right)
                    let childAreaAvailableHeight = layoutNode.height - (padding.top + padding.bottom)

                    topdownLayoutMonitor?.log("Available Child Area: (\(childAreaAvailableWidth)|\(childAreaAvailableHeight))")

                    layoutNode.setProperty(CoreOptions.ASPECT_RATIO, childAreaAvailableWidth / childAreaAvailableHeight)

                    if let subMon = progressMonitor.subTask(Float(nodeCount)) {
                        executeAlgorithm(layoutNode, algorithmData, testController, subMon)
                    }

                    if topdownNodeType == .ROOT_NODE {
                        ElkUtil.computeChildAreaDimensions(layoutNode)
                        let childAreaW: Double = layoutNode.getProperty(CoreOptions.CHILD_AREA_WIDTH) ?? 0
                        let childAreaH: Double = layoutNode.getProperty(CoreOptions.CHILD_AREA_HEIGHT) ?? 0
                        layoutNode.setDimensions(
                            width: padding.left + childAreaW + padding.right,
                            height: padding.top + childAreaH + padding.bottom
                        )
                    }

                    let algName: String = layoutNode.getProperty(CoreOptions.ALGORITHM) ?? "<unknown>"
                    topdownLayoutMonitor?.log("Executed layout algorithm: \(algName) on node \(layoutNode.identifier ?? "<unknown>")")

                    if topdownNodeType == .HIERARCHICAL_NODE {
                        if childAreaAvailableWidth < 0 || childAreaAvailableHeight < 0 {
                            throw ELK.Error.runtimeError("The size defined by the parent parallel node is too small for the space provided by the paddings of the child hierarchical node. \(layoutNode.identifier ?? "<unknown>")")
                        }

                        if !(layoutNode.hasProperty(CoreOptions.CHILD_AREA_WIDTH) || layoutNode.hasProperty(CoreOptions.CHILD_AREA_HEIGHT)) {
                            ElkUtil.computeChildAreaDimensions(layoutNode)
                        }

                        let childAreaDesiredWidth: Double = layoutNode.getProperty(CoreOptions.CHILD_AREA_WIDTH) ?? 0
                        let childAreaDesiredHeight: Double = layoutNode.getProperty(CoreOptions.CHILD_AREA_HEIGHT) ?? 0

                        topdownLayoutMonitor?.log("Desired Child Area: (\(childAreaDesiredWidth)|\(childAreaDesiredHeight))")

                        let scaleFactorX = childAreaAvailableWidth / childAreaDesiredWidth
                        let scaleFactorY = childAreaAvailableHeight / childAreaDesiredHeight

                        let topdownScaleCap: Double = layoutNode.getProperty(CoreOptions.TOPDOWN_SCALE_CAP) ?? Double.greatestFiniteMagnitude
                        let scaleFactor = min(scaleFactorX, min(scaleFactorY, topdownScaleCap))
                        layoutNode.setProperty(CoreOptions.TOPDOWN_SCALE_FACTOR, scaleFactor)
                        topdownLayoutMonitor?.log("\(layoutNode.identifier ?? "<unknown>") -- Local Scale Factor (X|Y): (\(scaleFactorX)|\(scaleFactorY))")

                        let contentAlignment: ContentAlignment = layoutNode.getProperty(CoreOptions.CONTENT_ALIGNMENT) ?? ContentAlignment()

                        var alignmentShiftX: Double = 0
                        var alignmentShiftY: Double = 0

                        if scaleFactor < scaleFactorX {
                            if contentAlignment.contains(.hCenter) {
                                alignmentShiftX = (childAreaAvailableWidth / 2 - (childAreaDesiredWidth * scaleFactor) / 2) / scaleFactor
                            } else if contentAlignment.contains(.hRight) {
                                alignmentShiftX = (childAreaAvailableWidth - childAreaDesiredWidth * scaleFactor) / scaleFactor
                            }
                        }

                        if scaleFactor < scaleFactorY {
                            if contentAlignment.contains(.vCenter) {
                                alignmentShiftY = (childAreaAvailableHeight / 2 - (childAreaDesiredHeight * scaleFactor) / 2) / scaleFactor
                            } else if contentAlignment.contains(.vBottom) {
                                alignmentShiftY = (childAreaAvailableHeight - childAreaDesiredHeight * scaleFactor) / scaleFactor
                            }
                        }

                        let xShift = alignmentShiftX + (padding.left / scaleFactor - padding.left)
                        let yShift = alignmentShiftY + (padding.top / scaleFactor - padding.top)
                        topdownLayoutMonitor?.log("Shift: (\(xShift)|\(yShift))")

                        for node in layoutNode.children {
                            node.x += xShift
                            node.y += yShift
                        }

                        for edge in layoutNode.containedEdges {
                            for section in edge.sections {
                                section.setStartLocation(x: section.startX + xShift, y: section.startY + yShift)
                                section.setEndLocation(x: section.endX + xShift, y: section.endY + yShift)
                                for bendPoint in section.bendPoints {
                                    bendPoint.set(x: bendPoint.x + xShift, y: bendPoint.y + yShift)
                                }
                            }
                            for label in edge.labels {
                                label.setLocation(x: label.x + xShift, y: label.y + yShift)
                            }
                            if let junctionPoints: KVectorChain = edge.getProperty(CoreOptions.JUNCTION_POINTS) {
                                let _ = junctionPoints.offset(xShift, yShift)
                                edge.setProperty(CoreOptions.JUNCTION_POINTS, junctionPoints)
                            }
                        }
                    }
                    topdownLayoutMonitor?.done()
                }

                for child in layoutNode.children {
                    let childLayoutSelfLoops = try layoutRecursively(child, testController, progressMonitor)
                    childrenInsideSelfLoops.append(contentsOf: childLayoutSelfLoops)
                    ElkUtil.applyConfiguredNodeScaling(child)
                }
            }

            if progressMonitor.isCanceled() {
                return []
            }

            for selfLoop in childrenInsideSelfLoops {
                selfLoop.setProperty(CoreOptions.NO_LAYOUT, true)
            }

            let topdownLayout2: Bool = layoutNode.getProperty(CoreOptions.TOPDOWN_LAYOUT) ?? false
            if !topdownLayout2 {
                let nodeCount = layoutNode.children.count
                if let subMon = progressMonitor.subTask(Float(nodeCount)) {
                    executeAlgorithm(layoutNode, algorithmData, testController, subMon)
                }
            }

            postProcessInsideSelfLoops(childrenInsideSelfLoops)

            if hasInsideSelfLoops && supportsInsideSelfLoops {
                return insideSelfLoops
            } else {
                return []
            }
        } else {
            return []
        }
    }

    package func executeAlgorithm(_ layoutNode: ElkNode, _ algorithmData: LayoutAlgorithmData, _ testController: TestController?, _ progressMonitor: IElkProgressMonitor) {
        let layoutProvider = algorithmData.getInstancePool().fetch()

        do {
            try layoutProvider.layout(layoutGraph: layoutNode, progressMonitor: progressMonitor)
            algorithmData.getInstancePool().release(layoutProvider)
        } catch {
            layoutProvider.dispose()
        }
    }

    package func countNodesRecursively(_ layoutNode: ElkNode, _ countAncestors: Bool) -> Int {
        var count = layoutNode.children.count
        for childNode in layoutNode.children {
            if !childNode.children.isEmpty {
                count += countNodesRecursively(childNode, false)
            }
        }
        if countAncestors {
            var parent = layoutNode.parent
            while let p = parent {
                count += p.children.count
                parent = p.parent
            }
        }
        return count
    }

    package func evaluateHierarchyHandlingInheritance(_ layoutNode: ElkNode) {
        let hh: HierarchyHandling = layoutNode.getProperty(CoreOptions.HIERARCHY_HANDLING) ?? .inherit
        if hh == .inherit {
            guard let parent = layoutNode.parent else {
                layoutNode.setProperty(CoreOptions.HIERARCHY_HANDLING, HierarchyHandling.separateChildren)
                return
            }
            let parentHandling: HierarchyHandling = parent.getProperty(CoreOptions.HIERARCHY_HANDLING) ?? .separateChildren
            layoutNode.setProperty(CoreOptions.HIERARCHY_HANDLING, parentHandling)
        }
    }

    package func countNodesWithHierarchy(_ parentNode: ElkNode) -> Int {
        var count = parentNode.children.count
        for childNode in parentNode.children {
            let childHH: HierarchyHandling = childNode.getProperty(CoreOptions.HIERARCHY_HANDLING) ?? .inherit
            if childHH != .separateChildren {
                let parentData: LayoutAlgorithmData? = parentNode.getProperty(CoreOptions.RESOLVED_ALGORITHM)
                let childData: LayoutAlgorithmData? = childNode.getProperty(CoreOptions.RESOLVED_ALGORITHM)

                if let pd = parentData, let cd = childData, pd.id == cd.id, !childNode.children.isEmpty {
                    count += countNodesWithHierarchy(childNode)
                }
            }
        }
        return count
    }

    private func nodeResolvedAlgorithmEquals(_ node: ElkNode, _ algorithmData: LayoutAlgorithmData) -> Bool {
        guard let nodeData: LayoutAlgorithmData = node.getProperty(CoreOptions.RESOLVED_ALGORITHM) else {
            return false
        }
        return nodeData.id == algorithmData.id
    }

    package func gatherInsideSelfLoops(_ node: ElkNode) -> [ElkEdge] {
        let activate: Bool = node.getProperty(CoreOptions.INSIDE_SELF_LOOPS_ACTIVATE) ?? false
        if activate {
            var insideSelfLoops: [ElkEdge] = []

            for edge in ElkGraphUtil.allOutgoingEdges(node) {
                let yo: Bool = edge.getProperty(CoreOptions.INSIDE_SELF_LOOPS_YO) ?? false
                if edge.isSelfloop() && yo {
                    insideSelfLoops.append(edge)
                }
            }

            return insideSelfLoops
        } else {
            return []
        }
    }

    package func postProcessInsideSelfLoops(_ insideSelfLoops: [ElkEdge]) {
        for selfLoop in insideSelfLoops {
            let node = ElkGraphUtil.connectableShapeToNode(selfLoop.sources[0])

            let xOffset = node.x
            let yOffset = node.y

            let section = selfLoop.sections[0]
            section.setStartLocation(x: section.startX + xOffset, y: section.startY + yOffset)
            section.setEndLocation(x: section.endX + xOffset, y: section.endY + yOffset)

            for bend in section.bendPoints {
                bend.set(x: bend.x + xOffset, y: bend.y + yOffset)
            }

            if let junctionPoints: KVectorChain = selfLoop.getProperty(CoreOptions.JUNCTION_POINTS) {
                let _ = junctionPoints.offset(xOffset, yOffset)
            }
        }
    }
}
