import Foundation

/**
 * Removes rectangle overlaps by greedily choosing the smallest y position that won't cause overlaps.
 */
package final class GreedyRectangleStripOverlapRemover: IRectangleStripOverlapRemovalStrategy {

    package init() {}

    package func removeOverlaps(_ overlapRemover: RectangleStripOverlapRemover) -> Double {
        let verticalGap = overlapRemover.getVerticalGap()
        var alreadyPlacedNodes: [ObjectIdentifier] = []
        var stripSize: Double = 0

        for currNode in overlapRemover.getRectangleNodes() {
            var yPos: Double = 0

            // Sort the node's list of overlapping nodes by y coordinate
            let sortedOverlapping = currNode.getOverlappingNodes().sorted { (node1, node2) -> Bool in
                return node1.getRectangle().y < node2.getRectangle().y
            }

            for overlapNode in sortedOverlapping {
                if alreadyPlacedNodes.contains(ObjectIdentifier(overlapNode)) {
                    let currRect = currNode.getRectangle()
                    let overlapRect = overlapNode.getRectangle()

                    if yPos < overlapRect.y + overlapRect.height + verticalGap &&
                        yPos + currRect.height + verticalGap > overlapRect.y {

                        yPos = overlapRect.y + overlapRect.height + verticalGap
                    }
                }
            }

            currNode.getRectangle().y = yPos
            alreadyPlacedNodes.append(ObjectIdentifier(currNode))

            stripSize = max(stripSize, currNode.getRectangle().y + currNode.getRectangle().height)
        }

        return stripSize
    }
}
