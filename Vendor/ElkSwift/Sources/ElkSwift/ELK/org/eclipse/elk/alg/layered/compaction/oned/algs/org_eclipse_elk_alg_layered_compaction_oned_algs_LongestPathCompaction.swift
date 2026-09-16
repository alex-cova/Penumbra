import Foundation

/**
 * Compacts a previously calculated constraint graph (
 * {@link org.eclipse.elk.alg.layered.compaction.oned.CGraph CGraph}) by using a technique similar
 * to a longest path layering.
 *
 * The algorithm evaluates the {@link CGroup#reposition} flag.
 */
package class LongestPathCompaction: ICompactionAlgorithm {

    package init() {}

    package func compact(_ compactor: OneDimensionalCompactor) {

        // calculating the left-most position of any element
        // this will be our starting point for the compaction
        var minStartPos = Double.greatestFiniteMagnitude
        for cNode in compactor.cGraph.cNodes {
            let refX = cNode.cGroup?.reference?.hitbox.x ?? 0
            minStartPos = min(minStartPos, refX + cNode.cGroupOffset.x)
        }

        // finding the sinks of the constraint graph
        var sinks: [CGroup] = []
        for group in compactor.cGraph.cGroups {
            group.startPos = minStartPos
            if group.outDegree == 0 {
                sinks.append(group)
            }
        }

        // process sinks until every node in the constraint graph was handled
        while !sinks.isEmpty {

            guard let group = sinks.popLast() else { break }

            // record the movement of this group during the current compaction
            // this has to be recorded _before_ the nodes' positions are updated
            // and care has to be taken about the compaction direction. In certain
            // scenarios nodes may move "back-and-forth". To detect this, we associate
            // a negative delta with two of the compaction directions.
            var diff = group.reference?.hitbox.x ?? 0

            // ------------------------------------------
            // #1 final positions for this group's nodes
            // ------------------------------------------
            for node in group.cNodes {
                // CNodes can be locked in place to avoid pulling clusters apart
                let suggestedX = group.startPos + node.cGroupOffset.x
                if group.reposition
                    // does the "fixed" position violate the constraints?
                    || (node.getPosition() < suggestedX) {
                    node.startPos = suggestedX
                } else {
                    // leave the node where it was!
                    node.startPos = node.hitbox.x
                }
            }

            diff -= group.reference?.startPos ?? 0

            group.delta += diff
            if compactor.direction == Direction.RIGHT || compactor.direction == Direction.DOWN {
                group.deltaNormalized += diff
            } else {
                group.deltaNormalized -= diff
            }


            // ---------------------------------------------------
            // #2 propagate start positions to constrained groups
            // ---------------------------------------------------
            for node in group.cNodes {
                for incNode in node.constraints {
                    // determine the required spacing
                    let spacing: Double
                    if compactor.direction.isHorizontal() {
                        spacing = max(node.getHorizontalSpacing(), incNode.getHorizontalSpacing())
                    } else {
                        spacing = max(node.getVerticalSpacing(), incNode.getVerticalSpacing())
                    }

                    guard let incGroup = incNode.cGroup else { continue }
                    incGroup.startPos = max(incGroup.startPos,
                                            node.startPos + node.hitbox.width + spacing
                                              // respect the other group's node's offset
                                              - incNode.cGroupOffset.x)

                    // whether the node's current position should be preserved
                    if !incNode.reposition {
                        incGroup.startPos =
                            max(incGroup.startPos, incNode.getPosition()
                                - incNode.cGroupOffset.x)
                    }

                    incGroup.outDegree -= 1
                    if incGroup.outDegree == 0 {
                        sinks.append(incGroup)
                    }
                }
            }
        }

        // ------------------------------------------------------
        // #3 setting hitbox positions to new starting positions
        // ------------------------------------------------------
        for cNode in compactor.cGraph.cNodes {
            cNode.applyPosition()
        }
    }
}
