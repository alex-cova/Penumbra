import Foundation

// MARK: - TopdownSizeApproximator

/**
 * A size approximator is used to dynamically decide a size for a node to be used during topdown layout
 * of hierarchical nodes. This allows the use of a size approximation strategy to minimize white space
 * in the final result.
 */
package enum TopdownSizeApproximator: ITopdownSizeApproximator {

    /**
     * Computes the square root of the number of children and uses that as a multiplier for the base size
     * of the node. Nodes with no children will have a resulting size of 0, which means any other factors
     * determining the size will be dominant. Uses `CoreOptions.TOPDOWN_HIERARCHICAL_NODE_WIDTH` and
     * `CoreOptions.TOPDOWN_HIERARCHICAL_NODE_ASPECT_RATIO` as the base size.
     */
    case countChildren

    /**
     * Computes the layout of a node to get an estimate of how much space it needs. In order to do this, the
     * node and its children are copied including the edges between the children. All edges must be simple edges
     * not hyperedges.
     * The nodes are assigned sizes for the layout algorithm according to the COUNT_CHILDREN approximator.
     */
    case lookaheadLayout

    /**
     * Fixed Integer Ratio Approximator
     * Dependent on the size of the child graphs, rectangles of fixed ratios are produced.
     * The goal is to enable good packings and also give bigger subgraphs more space.
     */
    case fixedIntegerRatioBoxes

    /**
     * This approximator simply lays out the next level and sets its algorithm to fixed so that it is later skipped.
     */
    case layoutNextLevel

    // MARK: - ITopdownSizeApproximator conformance

    package func getSize(_ node: any ElkNode) throws -> KVector {
        switch self {
        case .countChildren:
            return getSizeForCountChildren(node)
        case .lookaheadLayout:
            return try getSizeForLookaheadLayout(node)
        case .fixedIntegerRatioBoxes:
            return getSizeForFixedIntegerRatioBoxes(node)
        case .layoutNextLevel:
            return try getSizeForLayoutNextLevel(node)
        }
    }

    // MARK: - Implementation details

    package func getSizeForCountChildren(_ node: any ElkNode) -> KVector {
        let baseWidth = (node.getProperty(CoreOptions.TOPDOWN_HIERARCHICAL_NODE_WIDTH) as? Double) ?? 200.0
        let aspectRatio = (node.getProperty(CoreOptions.TOPDOWN_HIERARCHICAL_NODE_ASPECT_RATIO) as? Double) ?? 1.4142135623730951
        let childCount = Double(node.children.count)
        let size = baseWidth * sqrt(childCount)
        return KVector(x: size, y: size / aspectRatio)
    }

    package func getSizeForLookaheadLayout(_ originalGraph: any ElkNode) throws -> KVector {
        guard let algorithmData = originalGraph.getProperty(CoreOptions.RESOLVED_ALGORITHM) as? LayoutAlgorithmData else {
            return KVector(x: 0, y: 0)
        }

        // clone the current hierarchy
        let node = ElkGraphFactoryImpl().createElkNode()
        let _ = node.copyProperties(originalGraph)
        // Use ObjectIdentifier-based map since ElkNode is a protocol
        var oldToNewNodeMap: [ObjectIdentifier: any ElkNode] = [:]

        // copy children
        for child in originalGraph.children {
            let newChild = ElkGraphFactoryImpl().createElkNode()
            newChild.parent = node
            let _ = newChild.copyProperties(child)

            // set size according to microlayout or node count approximator
            let size = try TopdownSizeApproximator.countChildren.getSize(child)
            newChild.setDimensions(
                width: max(child.width, size.x),
                height: max(child.height, size.y)
            )
            oldToNewNodeMap[ObjectIdentifier(child as AnyObject)] = newChild
        }

        // copy edges, explicitly assuming no hyperedges here
        for child in originalGraph.children {
            for edge in child.outgoingEdges {
                guard let newSrc = oldToNewNodeMap[ObjectIdentifier(child as AnyObject)],
                      let target = edge.targets.first,
                      let newTar = oldToNewNodeMap[ObjectIdentifier(target as AnyObject)] else { continue }

                let newEdge = ElkGraphFactoryImpl().createElkEdge()
                newEdge.sources.append(newSrc)
                newEdge.targets.append(newTar)
                newEdge.containingNode = newSrc.parent
                let _ = newEdge.copyProperties(edge)
            }
        }

        let layoutProvider = algorithmData.providerPool.fetch()
        // Perform layout on the current hierarchy level
        try layoutProvider.layout(layoutGraph: node, progressMonitor: NullElkProgressMonitor())
        algorithmData.providerPool.release(layoutProvider)

        if !(node.hasProperty(CoreOptions.CHILD_AREA_WIDTH) || node.hasProperty(CoreOptions.CHILD_AREA_HEIGHT)) {
            // compute child area if it hasn't been set by the layout algorithm
            ElkUtil.computeChildAreaDimensions(node)
        }

        let childAreaDesiredWidth = (node.getProperty(CoreOptions.CHILD_AREA_WIDTH) as? Double) ?? 0.0
        let childAreaDesiredHeight = (node.getProperty(CoreOptions.CHILD_AREA_HEIGHT) as? Double) ?? 0.0

        let childAreaDesiredAspectRatio = childAreaDesiredWidth / childAreaDesiredHeight

        // square root approximation for base size
        let topdownWidth = (node.getProperty(CoreOptions.TOPDOWN_HIERARCHICAL_NODE_WIDTH) as? Double) ?? 200.0
        let baseSize = topdownWidth * sqrt(Double(node.children.count))

        let paddingVal = (node.getProperty(CoreOptions.PADDING) as? ElkPadding) ?? ElkPadding()
        let minWidth = paddingVal.left + paddingVal.right + 1
        let minHeight = paddingVal.top + paddingVal.bottom + 1

        // the alternative to this is to return the desired Size directly, in that case region scales are close
        // to the children, in this case on the other hand region scales are close to their parent
        return KVector(
            x: max(minWidth, baseSize),
            y: max(minHeight, baseSize / childAreaDesiredAspectRatio)
        )
    }

    package func getSizeForFixedIntegerRatioBoxes(_ originalGraph: any ElkNode) -> KVector {
        let baseWidth = (originalGraph.getProperty(CoreOptions.TOPDOWN_HIERARCHICAL_NODE_WIDTH) as? Double) ?? 200.0
        let aspectRatio = (originalGraph.getProperty(CoreOptions.TOPDOWN_HIERARCHICAL_NODE_ASPECT_RATIO) as? Double) ?? 1.4142135623730951
        let baseHeight = baseWidth / aspectRatio

        // four categories of box sizes, tiny = half-width, small = base-width, medium = double-width, large = quadruple-width
        // how graph sizes are distributed into these categories has a great effect on the final result
        let multiplier = TopdownSizeApproximatorUtil.getSizeCategoryMultiplier(originalGraph)

        // Combine multiplier, spacings and base size to compute final size
        let paddingVal = (originalGraph.getProperty(CoreOptions.PADDING) as? ElkPadding) ?? ElkPadding()
        var nodeNodeSpacing = (CoreOptions.SPACING_NODE_NODE.defaultValue as? Double) ?? 20.0
        if let parent = originalGraph.parent {
            nodeNodeSpacing = (parent.getProperty(CoreOptions.SPACING_NODE_NODE) as? Double) ?? 20.0
        }

        let resultSize = KVector(x: baseWidth * multiplier, y: baseHeight * multiplier)
        return KVector(
            x: resultSize.x - (paddingVal.left + paddingVal.right) - nodeNodeSpacing,
            y: resultSize.y - (paddingVal.top + paddingVal.bottom) - nodeNodeSpacing
        )
    }

    package func getSizeForLayoutNextLevel(_ originalGraph: any ElkNode) throws -> KVector {
        // do size approximations for children
        for childNode in originalGraph.children {
            if let approximator = originalGraph.getProperty(CoreOptions.TOPDOWN_SIZE_APPROXIMATOR) as? ITopdownSizeApproximator,
               !childNode.children.isEmpty {
                let size = try approximator.getSize(childNode)
                let paddingVal = (childNode.getProperty(CoreOptions.PADDING) as? ElkPadding) ?? ElkPadding()
                // never reuse the old size, always reset, otherwise calling layout multiple times leads to growing regions
                childNode.setDimensions(
                    width: max(childNode.width, size.x + paddingVal.left + paddingVal.right),
                    height: max(childNode.height, size.y + paddingVal.top + paddingVal.bottom)
                )
            } else if !childNode.children.isEmpty {
                let baseWidth = (childNode.getProperty(CoreOptions.TOPDOWN_HIERARCHICAL_NODE_WIDTH) as? Double) ?? 200.0
                let aspectRatio = (childNode.getProperty(CoreOptions.TOPDOWN_HIERARCHICAL_NODE_ASPECT_RATIO) as? Double) ?? 1.4142135623730951
                childNode.setDimensions(
                    width: baseWidth,
                    height: baseWidth / aspectRatio
                )
            }
        }

        // layout children
        // Get an instance of the layout provider
        guard let algorithmData = originalGraph.getProperty(CoreOptions.RESOLVED_ALGORITHM) as? LayoutAlgorithmData else {
            return KVector(x: 0, y: 0)
        }
        let layoutProvider = algorithmData.providerPool.fetch()

        // Perform layout on the current hierarchy level
        try layoutProvider.layout(layoutGraph: originalGraph, progressMonitor: NullElkProgressMonitor())
        algorithmData.providerPool.release(layoutProvider)

        // set layout to fixed layout
        let _ = originalGraph.setProperty(CoreOptions.ALGORITHM, "org.eclipse.elk.fixed")
        try LayoutAlgorithmResolver().visit(originalGraph)

        ElkUtil.computeChildAreaDimensions(originalGraph)
        let childAreaDesiredWidth = (originalGraph.getProperty(CoreOptions.CHILD_AREA_WIDTH) as? Double) ?? 0.0
        let childAreaDesiredHeight = (originalGraph.getProperty(CoreOptions.CHILD_AREA_HEIGHT) as? Double) ?? 0.0

        // apply size to graph
        return KVector(x: childAreaDesiredWidth, y: childAreaDesiredHeight)
    }
}
