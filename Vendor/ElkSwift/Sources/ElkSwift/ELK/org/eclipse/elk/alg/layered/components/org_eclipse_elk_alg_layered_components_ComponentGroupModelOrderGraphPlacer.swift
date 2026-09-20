/*******************************************************************************
 * Copyright (c) 2022 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 ******************************************************************************/

import Foundation

/**
 * A graph placer that tries to place the components of a graph with taking the model order and the
 * connections to external ports into account.
 */
package class ComponentGroupModelOrderGraphPlacer: ComponentGroupGraphPlacer {

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
            addModelOrderComponent(component)
        }

        // Place components in each group
        let spaceBlockedBySouthEdges = KVector()
        let spaceBlockedByComponents = KVector()
        let offset = KVector()
        let maxSize = KVector()
        let componentSpacing: Double = firstComponent.getProperty(LayeredOptions.SPACING_COMPONENT_COMPONENT) ?? 20.0

        let direction: Direction = target.getProperty(LayeredOptions.DIRECTION) ?? .RIGHT

        for group in componentGroups {
            if direction.isHorizontal() {
                offset.x = spaceBlockedBySouthEdges.x
                for side in group.portSides {
                    if side.contains(.NORTH) {
                        offset.x = spaceBlockedByComponents.x
                        break
                    }
                }
            } else if direction.isVertical() {
                offset.y = spaceBlockedBySouthEdges.y
                for side in group.portSides {
                    if side.contains(.WEST) {
                        offset.y = spaceBlockedByComponents.y
                        break
                    }
                }
            }

            let groupSize: KVector
            if let moGroup = group as? ModelOrderComponentGroup {
                groupSize = self.placeComponents(moGroup, spacing: componentSpacing)
            } else {
                groupSize = self.placeComponents(group, spacing: componentSpacing)
            }
            offsetGraphs(group.getComponents(), offset.x, offset.y)

            if direction.isHorizontal() {
                spaceBlockedByComponents.x = offset.x + groupSize.x
                maxSize.x = max(maxSize.x, spaceBlockedByComponents.x)
                for side in group.portSides {
                    if side.contains(.SOUTH) {
                        spaceBlockedBySouthEdges.x = offset.x + groupSize.x
                        break
                    }
                }
                spaceBlockedByComponents.y = offset.y + groupSize.y
                offset.y = spaceBlockedByComponents.y
                maxSize.y = max(maxSize.y, offset.y)
            } else if direction.isVertical() {
                spaceBlockedByComponents.y = offset.y + groupSize.y
                maxSize.y = max(maxSize.y, spaceBlockedByComponents.y)
                for side in group.portSides {
                    if side.contains(.EAST) {
                        spaceBlockedBySouthEdges.y = offset.y + groupSize.y
                        break
                    }
                }
                spaceBlockedByComponents.x = offset.x + groupSize.x
                offset.x = spaceBlockedByComponents.x
                maxSize.x = max(maxSize.x, offset.x)
            }
        }

        target.size.x = maxSize.x - componentSpacing
        target.size.y = maxSize.y - componentSpacing

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

    func addModelOrderComponent(_ component: LGraph) {
        // Check if one of the existing component groups has some place left
        if !componentGroups.isEmpty {
            if let group = componentGroups.last as? ModelOrderComponentGroup {
                if group.add(component) {
                    return
                }
            }
        }

        // Create a new component group for the component
        componentGroups.append(ModelOrderComponentGroup(component))
    }
}
