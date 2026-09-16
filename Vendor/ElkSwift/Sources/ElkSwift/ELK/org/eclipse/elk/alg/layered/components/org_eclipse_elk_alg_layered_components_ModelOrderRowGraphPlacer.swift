import Foundation

/**
 * Places components such that rows are formed while still maintaining the model order.
 * Since components cannot be expanded to create visual cues the placement does not utilize
 * subrows or stacks inside a row since the resulting placement can be ambiguous.
 */
package class ModelOrderRowGraphPlacer: SimpleRowGraphPlacer {

    package override func sortComponents(_ components: [LGraph], target: LGraph) {
        // Does nothing since components are already sorted by model order
    }

    package override func placeComponents(_ components: [LGraph], target: LGraph, maxRowWidth: Double, componentSpacing: Double) {
        // Place nodes iteratively into rows while considering the model order.
        var xpos: Double = 0
        var ypos: Double = 0
        var highestBox: Double = 0
        var broadestRow: Double = componentSpacing
        var lastComponent: LGraph? = nil
        var startXOfRow: Double = 0

        for graph in components {
            let size = graph.size
            let extPortConnections: Set<PortSide> = graph.getProperty(InternalProperties.EXT_PORT_CONNECTIONS) ?? []

            let lastHasEast = lastComponent.map {
                ($0.getProperty(InternalProperties.EXT_PORT_CONNECTIONS) as? Set<PortSide> ?? []).contains(.EAST)
            } ?? false
            if (xpos + size.x > maxRowWidth && !extPortConnections.contains(.NORTH))
                || lastHasEast
                || extPortConnections.contains(.WEST) {
                // Components with NORTH connection are allowed to violate the width constraint.
                // Place the graph into the next row
                // Previous EAST ports require a new row.
                // A WEST port requires a new row.
                xpos = startXOfRow
                ypos += highestBox + componentSpacing
                highestBox = 0
            }

            let offset = graph.offset
            // North ports should be placed such that they don't intersect with prior components.
            if extPortConnections.contains(PortSide.NORTH) {
                xpos = broadestRow + componentSpacing
            }

            offsetGraph(graph, xpos + offset.x, ypos + offset.y)
            broadestRow = max(broadestRow, xpos + size.x)

            // South ports block of everything below them.
            if extPortConnections.contains(PortSide.SOUTH) {
                startXOfRow = max(startXOfRow, xpos + size.x + componentSpacing)
            }

            highestBox = max(highestBox, size.y)
            xpos += size.x + componentSpacing
            lastComponent = graph
        }

        target.size.x = broadestRow
        target.size.y = ypos + highestBox
    }
}
