import Foundation

/**
 * Postprocess a compound graph by restoring cross-hierarchy edges that have previously been split
 * by the CompoundGraphPreprocessor.
 */
package class CompoundGraphPostprocessor: ILayoutProcessor {
    package typealias G = LGraph

    /**
     * A predicate that checks if a given cross hierarchy edge has junction points.
     */
    package static let hasJunctionPointsPredicate: (CrossHierarchyEdge) -> Bool = { chEdge in
        let jps: KVectorChain? = chEdge.getEdge().getProperty(LayeredOptions.JUNCTION_POINTS) as? KVectorChain
        return !(jps?.isEmpty ?? true)
    }

    package init() {}

    package func process(_ graph: LGraph, _ monitor: IElkProgressMonitor) {
        monitor.begin("Compound graph postprocessor", 1)

        // whether bend points should be added whenever crossing a hierarchy boundary
        let addUnnecessaryBendpoints = graph.getProperty(LayeredOptions.UNNECESSARY_BENDPOINTS) as? Bool ?? false

        // restore the cross-hierarchy map that was built by the preprocessor
        guard let crossHierarchyMap = graph.getProperty(InternalProperties.CROSS_HIERARCHY_MAP) as? [LEdge: [CrossHierarchyEdge]] else {
            monitor.done()
            return
        }

        // remember all dummy edges we encounter; these need to be removed at the end
        var dummyEdges = Set<LEdge>()

        // iterate over all original edges
        for (origEdge, crossHierarchyEdgesList) in crossHierarchyMap {
            // find all cross-hierarchy edges the original edge was split into, and sort them from source to target
            var crossHierarchyEdges = crossHierarchyEdgesList
            let comparator = CrossHierarchyEdgeComparator(graph)
            crossHierarchyEdges.sort { comparator.compare($0, $1) == .orderedAscending }

            // find the original source and target ports for the original edge
            let sourcePort = crossHierarchyEdges[0].getActualSource()
            let targetPort = crossHierarchyEdges[crossHierarchyEdges.count - 1].getActualTarget()

            guard let referenceNode = sourcePort.node else { continue }
            var referenceGraph: LGraph
            if let targetNode = targetPort.node,
               LGraphUtil.isDescendant(targetNode, referenceNode),
               let nestedGraph = referenceNode.getNestedGraph() {
                referenceGraph = nestedGraph
            } else if let nodeGraph = referenceNode.graph {
                referenceGraph = nodeGraph
            } else {
                continue
            }

            // check whether there are any junction points
            let junctionPoints = clearJunctionPoints(origEdge, crossHierarchyEdges: crossHierarchyEdges)

            // reset bend points (we have computed new ones anyway)
            origEdge.getBendPoints().clear()

            // apply the computed layouts to the cross-hierarchy edge
            var lastPoint: KVector? = nil
            for chEdge in crossHierarchyEdges {
                // transform all coordinates from the graph of the dummy edge to the reference graph
                let offset = KVector()
                LGraphUtil.changeCoordSystem(offset, oldGraph: chEdge.getGraph(), newGraph: referenceGraph)

                let ledge = chEdge.getEdge()
                let bendPoints = KVectorChain()
                bendPoints.addAllAsCopies(at: 0, ledge.getBendPoints().toArray())
                bendPoints.offset(offset)

                // Note: if an NPE occurs here, that means ELK Layered has replaced the original edge
                guard let ledgeSource = ledge.source, let ledgeTarget = ledge.target else { continue }
                let sourcePoint = KVector(ledgeSource.absoluteAnchor)
                let targetPoint = KVector(ledgeTarget.absoluteAnchor)
                sourcePoint.add(offset)
                targetPoint.add(offset)

                if let last = lastPoint {
                    let nextPoint: KVector
                    if bendPoints.isEmpty {
                        nextPoint = targetPoint
                    } else if let first = bendPoints.getFirst() {
                        nextPoint = first
                    } else {
                        nextPoint = targetPoint
                    }

                    let xDiffEnough = abs(last.x - nextPoint.x) > OrthogonalRoutingGenerator.TOLERANCE
                    let yDiffEnough = abs(last.y - nextPoint.y) > OrthogonalRoutingGenerator.TOLERANCE

                    if ((!addUnnecessaryBendpoints && xDiffEnough && yDiffEnough)
                            || (addUnnecessaryBendpoints && (xDiffEnough || yDiffEnough))) {
                        origEdge.getBendPoints().append(sourcePoint)
                    }
                }

                origEdge.getBendPoints().append(contentsOf: bendPoints)

                if bendPoints.isEmpty {
                    lastPoint = sourcePoint
                } else {
                    lastPoint = bendPoints.last
                }

                // copy junction points
                if let jp = junctionPoints {
                    copyJunctionPoints(ledge, target: jp, offset: offset)
                }

                // add offset to target port with a special property
                if chEdge.getActualTarget() === targetPort {
                    if let tpGraph = targetPort.node?.graph, tpGraph !== chEdge.getGraph() {
                        let newOffset = KVector()
                        LGraphUtil.changeCoordSystem(newOffset, oldGraph: tpGraph, newGraph: referenceGraph)
                        origEdge.setProperty(InternalProperties.TARGET_OFFSET, newOffset)
                    } else {
                        origEdge.setProperty(InternalProperties.TARGET_OFFSET, offset)
                    }
                }

                // copy labels back to the original edge
                copyLabelsBack(hierarchySegment: ledge, origEdge: origEdge, referenceGraph: referenceGraph)

                // remember the dummy edge for later removal
                dummyEdges.insert(ledge)
            }

            // restore the original source port and target port
            origEdge.setSource(sourcePort)
            origEdge.setTarget(targetPort)
        }

        // remove the dummy edges from the graph
        for dummyEdge in dummyEdges {
            dummyEdge.setSource(nil)
            dummyEdge.setTarget(nil)
        }

        monitor.done()
    }

    /**
     * Clears an original edge's list of junction points and returns them.
     */
    package func clearJunctionPoints(_ origEdge: LEdge, crossHierarchyEdges: [CrossHierarchyEdge]) -> KVectorChain? {
        var junctionPoints = origEdge.getProperty(LayeredOptions.JUNCTION_POINTS) as? KVectorChain

        let hasJunctionPoints = crossHierarchyEdges.contains { CompoundGraphPostprocessor.hasJunctionPointsPredicate($0) }
        if hasJunctionPoints {
            if junctionPoints == nil {
                let newJPs = KVectorChain()
                junctionPoints = newJPs
                origEdge.setProperty(LayeredOptions.JUNCTION_POINTS, newJPs)
            } else {
                junctionPoints?.clear()
            }
        } else if junctionPoints != nil {
            origEdge.setProperty(LayeredOptions.JUNCTION_POINTS, nil as Any?)
        }

        return junctionPoints
    }

    /**
     * Copies the junction points of the source to the target, adding the given offset.
     */
    package func copyJunctionPoints(_ source: LEdge, target: KVectorChain, offset: KVector) {
        guard let ledgeJPs = source.getProperty(LayeredOptions.JUNCTION_POINTS) as? KVectorChain else { return }

        let jpCopies = KVectorChain()
        jpCopies.addAllAsCopies(at: 0, ledgeJPs.toArray())
        jpCopies.offset(offset)

        target.append(contentsOf: jpCopies)
    }

    /**
     * Copies the labels from the given hierarchy segment back to the original hierarchical edge.
     */
    package func copyLabelsBack(hierarchySegment: LEdge, origEdge: LEdge, referenceGraph: LGraph) {
        // Collect matching labels first to avoid mutation during iteration
        let toMove = hierarchySegment.labels.filter {
            $0.getProperty(InternalProperties.ORIGINAL_LABEL_EDGE) as? LEdge === origEdge
        }
        for currLabel in toMove {
            if let segGraph = hierarchySegment.source?.node?.graph {
                LGraphUtil.changeCoordSystem(
                    currLabel.position,
                    oldGraph: segGraph,
                    newGraph: referenceGraph
                )
            }

            hierarchySegment.labels.removeAll(where: { $0 === currLabel })
            origEdge.labels.append(currLabel)
        }
    }
}
