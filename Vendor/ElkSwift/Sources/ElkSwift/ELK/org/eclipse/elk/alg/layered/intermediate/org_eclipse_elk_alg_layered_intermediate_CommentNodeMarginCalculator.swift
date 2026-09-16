import Foundation

/**
 * Computes and sets the node margins required to place comment boxes.
 *
 * <dl>
 *   <dt>Preconditions:</dt>
 *     <dd>A layered graph.</dd>
 *     <dd>Node margins include space for ports, port labels, and self loops.</dd>
 *   <dt>Postcondition:</dt>
 *     <dd>Node margins are extended to include space for comment boxes.</dd>
 *   <dt>Slots:</dt>
 *     <dd>Before phase 4.</dd>
 *   <dt>Same-slot dependencies:</dt>
 *     <dd>{@link SelfLoopRouter}</dd>
 * </dl>
 *
 * @see InnermostNodeMarginCalculator
 */
package final class CommentNodeMarginCalculator: ILayoutProcessor {

    package typealias G = LGraph

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Node margin calculation", 1)

        // Iterate through the layers to additionally handle comments
        let nodes = layeredGraph.layers.flatMap { $0.nodes }
        nodes.forEach { processComments($0) }

        monitor.done()
    }

    /**
     * Make some extra space for comment boxes that are placed near the given node.
     */
    package func processComments(_ node: LNode) {
        var margin = node.margin

        let topBoxes: [LNode]? = node.getProperty(InternalProperties.TOP_COMMENTS) as? [LNode]
        let bottomBoxes: [LNode]? = node.getProperty(InternalProperties.BOTTOM_COMMENTS) as? [LNode]

        if topBoxes == nil && bottomBoxes == nil {
            // Shortcut if there are no attached comments
            return
        }

        // Retrieve the spacings that apply to this node
        let commentCommentSpacing: Double = node.getProperty(LayeredOptions.SPACING_COMMENT_COMMENT) as? Double ?? 0.0
        let commentNodeSpacing: Double = node.getProperty(LayeredOptions.SPACING_COMMENT_NODE) as? Double ?? 0.0

        // Consider comment boxes that are put on top of the node
        var topWidth = 0.0
        if let topBoxes = topBoxes {
            var maxHeight = 0.0
            for commentBox in topBoxes {
                maxHeight = max(maxHeight, commentBox.size.y)
                topWidth += commentBox.size.x
            }
            topWidth += commentCommentSpacing * Double(max(0, topBoxes.count - 1))
            margin.top += maxHeight + commentNodeSpacing
        }

        // Consider comment boxes that are put in the bottom of the node
        var bottomWidth = 0.0
        if let bottomBoxes = bottomBoxes {
            var maxHeight = 0.0
            for commentBox in bottomBoxes {
                maxHeight = max(maxHeight, commentBox.size.y)
                bottomWidth += commentBox.size.x
            }
            bottomWidth += commentCommentSpacing * Double(max(0, bottomBoxes.count - 1))
            margin.bottom += maxHeight + commentNodeSpacing
        }

        // Check if the maximum width of the comments is wider than the node itself, which the comments
        // are centered on
        let maxCommentWidth = max(topWidth, bottomWidth)
        if maxCommentWidth > node.size.x {
            let protrusion = (maxCommentWidth - node.size.x) / 2
            margin.left = max(margin.left, protrusion)
            margin.right = max(margin.right, protrusion)
        }

        node.margin = margin
    }

}
