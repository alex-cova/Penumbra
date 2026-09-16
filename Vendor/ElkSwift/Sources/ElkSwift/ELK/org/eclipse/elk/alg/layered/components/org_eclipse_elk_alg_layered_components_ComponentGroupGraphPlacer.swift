import Foundation

/**
 * A graph placer that tries to place the components of a graph with taking connections to external
 * ports into account.
 */
package class ComponentGroupGraphPlacer: AbstractGraphPlacer {

    // MARK: - Variables

    package var componentGroups = [ComponentGroup]()

    // MARK: - AbstractGraphPlacer

    package override func combine(_ components: [LGraph], target: LGraph) {
        componentGroups.removeAll()
        assert(!components.contains { $0 === target })
        target.layerlessNodes.removeAll()

        if components.isEmpty {
            target.size.x = 0
            target.size.y = 0
            return
        }

        let firstComponent = components[0]
        target.copyProperties(from: firstComponent)

        // Construct component groups
        for component in components {
            addComponent(component)
        }

        // Place components in each group
        var offset = KVector()
        let componentSpacing: Double = firstComponent.getProperty(LayeredOptions.SPACING_COMPONENT_COMPONENT) ?? 20.0

        for group in componentGroups {
            let groupSize = placeComponents(group, spacing: componentSpacing)
            offsetGraphs(group.getComponents(), offset.x, offset.y)

            offset.x += groupSize.x
            offset.y += groupSize.y
        }

        target.size.x = offset.x - componentSpacing
        target.size.y = offset.y - componentSpacing

        // if compaction is desired, do so!
        let compactionDesired: Bool = firstComponent.getProperty(LayeredOptions.COMPACTION_CONNECTED_COMPONENTS) ?? false
        let edgeRouting: EdgeRouting? = firstComponent.getProperty(LayeredOptions.EDGE_ROUTING)
        if compactionDesired && edgeRouting == EdgeRouting.ORTHOGONAL {

            for h in components {
                offsetGraph(h, h.offset.x, h.offset.y)
            }

            let compactor = ComponentsCompactor()
            compactor.compact(components, target.size, componentSpacing)

            for h in components {
                h.offset.reset()
                h.offset.add(compactor.getOffset())
            }

            target.size.reset()
            target.size.add(compactor.getGraphSize())
        }

        // finally move the components to the combined graph
        for group in componentGroups {
            moveGraphs(target, group.getComponents(), 0, 0)
        }
    }

    // MARK: - Component Group Building

    package func addComponent(_ component: LGraph) {
        for group in componentGroups {
            if group.add(component) {
                return
            }
        }
        componentGroups.append(ComponentGroup(component))
    }

    // MARK: - Component Placement

    package func placeComponents(_ group: ComponentGroup, spacing: Double) -> KVector {

        let sizeC = placeComponentsInRows(group.getComponents(.none), spacing: spacing)
        let sizeN = placeComponentsHorizontally(group.getComponents(.north), spacing: spacing)
        let sizeS = placeComponentsHorizontally(group.getComponents(.south), spacing: spacing)
        let sizeW = placeComponentsVertically(group.getComponents(.west), spacing: spacing)
        let sizeE = placeComponentsVertically(group.getComponents(.east), spacing: spacing)
        let sizeNW = placeComponentsHorizontally(group.getComponents(.northWest), spacing: spacing)
        let sizeNE = placeComponentsHorizontally(group.getComponents(.northEast), spacing: spacing)
        let sizeSW = placeComponentsHorizontally(group.getComponents(.southWest), spacing: spacing)
        let sizeSE = placeComponentsHorizontally(group.getComponents(.eastSouth), spacing: spacing)
        let sizeWE = placeComponentsVertically(group.getComponents(.eastWest), spacing: spacing)
        let sizeNS = placeComponentsHorizontally(group.getComponents(.northSouth), spacing: spacing)
        let sizeNWE = placeComponentsHorizontally(group.getComponents(.northEastWest), spacing: spacing)
        let sizeSWE = placeComponentsHorizontally(group.getComponents(.eastSouthWest), spacing: spacing)
        let sizeWNS = placeComponentsVertically(group.getComponents(.northSouthWest), spacing: spacing)
        let sizeENS = placeComponentsVertically(group.getComponents(.northEastSouth), spacing: spacing)
        let sizeNESW = placeComponentsHorizontally(group.getComponents(.northEastSouthWest), spacing: spacing)

        let colLeftWidth = max(max(max(sizeNW.x, sizeW.x), sizeSW.x), sizeWNS.x)
        let colMidWidth = max(max(max(sizeN.x, sizeC.x), sizeS.x), sizeNESW.x)
        let colNsWidth = sizeNS.x
        let colRightWidth = max(max(max(sizeNE.x, sizeE.x), sizeSE.x), sizeENS.x)
        let rowTopHeight = max(max(max(sizeNW.y, sizeN.y), sizeNE.y), sizeNWE.y)
        let rowMidHeight = max(max(max(sizeW.y, sizeC.y), sizeE.y), sizeNESW.y)
        let rowWeHeight = sizeWE.y
        let rowBottomHeight = max(max(max(sizeSW.y, sizeS.y), sizeSE.y), sizeSWE.y)

        offsetGraphs(group.getComponents(.none),
                     colLeftWidth + colNsWidth,
                     rowTopHeight + rowWeHeight)
        offsetGraphs(group.getComponents(.northEastSouthWest),
                     colLeftWidth + colNsWidth,
                     rowTopHeight + rowWeHeight)
        offsetGraphs(group.getComponents(.north),
                     colLeftWidth + colNsWidth,
                     0.0)
        offsetGraphs(group.getComponents(.south),
                     colLeftWidth + colNsWidth,
                     rowTopHeight + rowWeHeight + rowMidHeight)
        offsetGraphs(group.getComponents(.west),
                     0.0,
                     rowTopHeight + rowWeHeight)
        offsetGraphs(group.getComponents(.east),
                     colLeftWidth + colNsWidth + colMidWidth,
                     rowTopHeight + rowWeHeight)
        offsetGraphs(group.getComponents(.northEast),
                     colLeftWidth + colNsWidth + colMidWidth,
                     0.0)
        offsetGraphs(group.getComponents(.southWest),
                     0.0,
                     rowTopHeight + rowWeHeight + rowMidHeight)
        offsetGraphs(group.getComponents(.eastSouth),
                     colLeftWidth + colNsWidth + colMidWidth,
                     rowTopHeight + rowWeHeight + rowMidHeight)
        offsetGraphs(group.getComponents(.eastWest),
                     0.0,
                     rowTopHeight)
        offsetGraphs(group.getComponents(.northSouth),
                     colLeftWidth,
                     0.0)
        offsetGraphs(group.getComponents(.eastSouthWest),
                     0.0,
                     rowTopHeight + rowWeHeight + rowMidHeight)
        offsetGraphs(group.getComponents(.northEastSouth),
                     colLeftWidth + colNsWidth + colMidWidth,
                     0.0)

        let componentSize = KVector()
        componentSize.x = max(max(max(colLeftWidth + colMidWidth + colNsWidth + colRightWidth, sizeWE.x), sizeNWE.x), sizeSWE.x)
        componentSize.y = max(max(max(rowTopHeight + rowMidHeight + rowWeHeight + rowBottomHeight, sizeNS.y), sizeWNS.y), sizeENS.y)

        return componentSize
    }

    package func placeComponentsHorizontally(_ components: [LGraph], spacing: Double) -> KVector {
        var size = KVector()

        for component in components {
            offsetGraph(component, size.x, 0.0)
            size.x += component.size.x + spacing
            size.y = max(size.y, component.size.y)
        }

        if size.y > 0.0 {
            size.y += spacing
        }

        return size
    }

    package func placeComponentsVertically(_ components: [LGraph], spacing: Double) -> KVector {
        var size = KVector()

        for component in components {
            offsetGraph(component, 0.0, size.y)
            size.y += component.size.y + spacing
            size.x = max(size.x, component.size.x)
        }

        if size.x > 0.0 {
            size.x += spacing
        }

        return size
    }

    package func placeComponentsInRows(_ components: [LGraph], spacing: Double) -> KVector {

        if components.isEmpty {
            return KVector()
        }

        var maxRowWidth: Double = 0.0
        var totalArea: Double = 0.0
        for component in components {
            let componentSize = component.size
            maxRowWidth = max(maxRowWidth, componentSize.x)
            totalArea += componentSize.x * componentSize.y
        }

        guard let firstComponent = components.first else { return KVector() }
        let aspectRatio: Double = firstComponent.getProperty(LayeredOptions.ASPECT_RATIO) ?? 1.0
        maxRowWidth = max(maxRowWidth, sqrt(totalArea) * aspectRatio)

        var xpos: Double = 0, ypos: Double = 0, highestBox: Double = 0, broadestRow: Double = spacing
        for graph in components {
            let size = graph.size

            if xpos + size.x > maxRowWidth {
                xpos = 0
                ypos += highestBox + spacing
                highestBox = 0
            }

            offsetGraph(graph, xpos, ypos)

            broadestRow = max(broadestRow, xpos + size.x)
            highestBox = max(highestBox, size.y)

            xpos += size.x + spacing
        }

        return KVector(x: broadestRow + spacing, y: ypos + highestBox + spacing)
    }
}
