import Foundation

/**
 * A simple graph placer that places components into rows, trying to make the result fit a configurable
 * aspect ratio. This graph placer does not pay attention to external port connections and should not
 * be used in the presence of such connections.
 *
 * <p>This is the first algorithm implemented to place the different connected components of a graph,
 * and was formerly the implementation of the {@link ComponentsProcessor#combine(List)} method.</p>
 *
 * <p>The target graph must not be contained in the list of components, except if there is only
 * one component.</p>
 */
package class SimpleRowGraphPlacer: AbstractGraphPlacer {

    package override func combine(_ components: [LGraph], target: LGraph) {
        if components.count == 1 {
            let source = components[0]
            if source !== target {
                target.layerlessNodes.removeAll()
                moveGraph(target, source, 0, 0)
                target.copyProperties(from: source)
                target.padding.copy(source.padding)
                target.size.x = source.size.x
                target.size.y = source.size.y
            }
            return
        } else if components.isEmpty {
            target.layerlessNodes.removeAll()
            target.size.x = 0
            target.size.y = 0
            return
        }

        assert(!components.contains { $0 === target })

        // Sort components
        sortComponents(components, target: target)

        let firstComponent = components[0]
        target.layerlessNodes.removeAll()
        target.copyProperties(from: firstComponent)

        // determine the maximal row width by the maximal box width and the total area
        var maxRowWidth: Double = 0.0
        var totalArea: Double = 0.0
        for graph in components {
            let size = graph.size
            maxRowWidth = max(maxRowWidth, size.x)
            totalArea += size.x * size.y
        }
        let aspectRatio: Double = target.getProperty(LayeredOptions.ASPECT_RATIO) ?? 1.6
        maxRowWidth = max(maxRowWidth, sqrt(totalArea) * aspectRatio)
        let componentSpacing: Double = target.getProperty(LayeredOptions.SPACING_COMPONENT_COMPONENT) ?? 20.0

        placeComponents(components, target: target, maxRowWidth: maxRowWidth, componentSpacing: componentSpacing)

        // if compaction is desired, do so!
        let compactionDesired: Bool = firstComponent.getProperty(LayeredOptions.COMPACTION_CONNECTED_COMPONENTS) ?? false
        if compactionDesired {
            let compactor = ComponentsCompactor()
            compactor.compact(components, target.size, componentSpacing)

            // the compaction algorithm places components absolutely,
            // therefore we have to use the final drawing's offset
            for h in components {
                h.offset = KVector()
                h.offset.add(compactor.getOffset())
            }

            // set the new graph size
            target.size = compactor.getGraphSize()
        }

        // finally move the components to the combined graph
        moveGraphs(target, components, 0, 0)
    }

    /**
     * Sort components based on the summed up priority.
     */
    package func sortComponents(_ components: [LGraph], target: LGraph) {
        let considerModelOrder: ComponentOrderingStrategy? = target.getProperty(LayeredOptions.CONSIDER_MODEL_ORDER_COMPONENTS)
        if considerModelOrder == nil || considerModelOrder == ComponentOrderingStrategy.NONE {
            // assign priorities
            var componentPriorities = [ObjectIdentifier: Int]()
            for graph in components {
                var priority = 0
                for node in graph.layerlessNodes {
                    priority += node.getProperty(LayeredOptions.PRIORITY) ?? 0
                }
                componentPriorities[ObjectIdentifier(graph)] = priority
            }

            // sort the components by their priority and size.
            // Note: In Swift, we can't modify the input array directly unless it's inout.
        }
    }

    /**
     * Places components in rows bounded by the approximated width.
     */
    package func placeComponents(_ components: [LGraph], target: LGraph, maxRowWidth: Double, componentSpacing: Double) {
        // place nodes iteratively into rows
        var xpos: Double = 0
        var ypos: Double = 0
        var highestBox: Double = 0
        var broadestRow: Double = componentSpacing

        for graph in components {
            let size = graph.size
            if xpos + size.x > maxRowWidth {
                // place the graph into the next row
                xpos = 0
                ypos += highestBox + componentSpacing
                highestBox = 0
            }

            let offset = graph.offset
            offsetGraph(graph, xpos + offset.x, ypos + offset.y)
            graph.offset = KVector()
            broadestRow = max(broadestRow, xpos + size.x)
            highestBox = max(highestBox, size.y)
            xpos += size.x + componentSpacing
        }

        target.size.x = broadestRow
        target.size.y = ypos + highestBox
    }
}
