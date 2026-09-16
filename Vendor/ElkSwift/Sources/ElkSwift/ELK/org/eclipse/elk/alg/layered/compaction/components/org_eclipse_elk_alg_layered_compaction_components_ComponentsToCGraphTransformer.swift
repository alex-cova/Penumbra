// Copyright (c) 2016 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

// MARK: - Main transformer class
package class ComponentsToCGraphTransformer {

    private var _cGraph: CGraph?
    package var spacing: Double

    // internal mappings
    package var oldPosition: [ObjectIdentifier: KVector] = [:]
    package var offsets: [ObjectIdentifier: CRectNode] = [:]

    // a global offset and the new graph size after layout
    private var _globalOffset: KVector?
    private var _graphSize: KVector?

    // maps the external extension to the CNodes by which they are represented
    package var externalExtensions: [String: (first: Direction, second: CNode)] = [:]
    package var externalPlaceholder: [Direction: [Pair<CGroup, CNode>]] = [:]

    package init(spacing: Double) {
        self.spacing = spacing
    }

    package func getOffset(_ c: InternalComponent) -> KVector {
        let key = ObjectIdentifier(c)
        guard let oldPos = oldPosition[key], let offsetNode = offsets[key] else {
            return KVector()
        }
        let cOffset = oldPos.clone().sub(KVector(x: offsetNode.rect.x, y: offsetNode.rect.y))
        return cOffset
    }

    package func getGlobalOffset() -> KVector {
        return _globalOffset ?? KVector()
    }

    package func getGraphSize() -> KVector {
        return _graphSize ?? KVector()
    }

    // MARK: - Graph Transformation

    package func transform(_ ccs: InternalConnectedComponents) -> CGraph {
        let cGraph = CGraph([.LEFT, .RIGHT, .UP, .DOWN])
        _cGraph = cGraph

        for comp in ccs.getComponents() {
            let group = CGroup()
            cGraph.cGroups.append(group)

            // convert the hull of the graph's elements without external edges
            for rect in comp.getHull() {
                let rectNode = CRectNode(rect, spacing)
                setLock(rectNode, portSides: comp.externalExtensionSides)

                let key = ObjectIdentifier(comp)
                if oldPosition[key] == nil {
                    oldPosition[key] = KVector(x: rect.x, y: rect.y)
                    offsets[key] = rectNode
                }

                cGraph.cNodes.append(rectNode)
                group.addCNode(rectNode)
            }

            // prepare rectangles for external extensions
            for ee in comp.getExternalExtensions() {
                if let uee = ee as? InternalUnionExternalExtension {
                    let rectNode = CRectNode(uee.getRepresentor(), spacing)
                    let eeKey = "\(ObjectIdentifier(comp))_\(uee.side)"
                    externalExtensions[eeKey] = (first: uee.getDirection(), second: rectNode)
                    setLock(rectNode, portSides: comp.externalExtensionSides)

                    if let placeholder = uee.getPlaceholder() {
                        let rectPlaceholder = CRectNode(placeholder, 1.0)
                        setLock(rectPlaceholder, portSides: comp.externalExtensionSides)
                        let dummyGroup = CGroup()
                        dummyGroup.addCNode(rectPlaceholder)
                        let dir = uee.getDirection()
                        if externalPlaceholder[dir] == nil {
                            externalPlaceholder[dir] = []
                        }
                        externalPlaceholder[dir]?.append(Pair(group, rectPlaceholder))
                    }
                }
            }
        }

        return cGraph
    }

    package func setLock(_ cNode: CNode, portSides: Set<PortSide>) {
        if portSides.isEmpty {
            cNode.lock.set(true, true, true, true)
            return
        }

        if portSides == [.NORTH] {
            cNode.lock.set(true, true, true, false)
        } else if portSides == [.EAST] {
            cNode.lock.set(false, true, true, true)
        } else if portSides == [.SOUTH] {
            cNode.lock.set(true, true, false, true)
        } else if portSides == [.WEST] {
            cNode.lock.set(true, false, true, true)
        }

        if portSides == [.NORTH, .EAST] {
            cNode.lock.set(false, true, true, false)
        } else if portSides == [.EAST, .SOUTH] {
            cNode.lock.set(false, true, false, true)
        } else if portSides == [.SOUTH, .WEST] {
            cNode.lock.set(true, false, false, true)
        } else if portSides == [.NORTH, .WEST] {
            cNode.lock.set(true, false, true, false)
        }

        if portSides == [.NORTH, .SOUTH] || portSides == [.EAST, .WEST] {
            cNode.lock.set(true, true, true, true)
        }

        if portSides == [.NORTH, .SOUTH, .WEST] ||
            portSides == [.NORTH, .EAST, .WEST] ||
            portSides == [.EAST, .SOUTH, .WEST] {
            cNode.lock.set(true, true, true, true)
        }

        if portSides == [.NORTH, .EAST, .SOUTH, .WEST] {
            cNode.lock.set(true, true, true, true)
        }
    }

    // MARK: - Layout Application

    package func applyLayout() {
        guard let cGraph = _cGraph else { return }

        for n in cGraph.cNodes {
            n.applyElementPosition()
        }

        // calculating new graph size and offset
        var topLeft = KVector(x: Double.greatestFiniteMagnitude, y: Double.greatestFiniteMagnitude)
        var bottomRight = KVector(x: -Double.greatestFiniteMagnitude, y: -Double.greatestFiniteMagnitude)

        for cNode in cGraph.cNodes {
            topLeft.x = min(topLeft.x, cNode.hitbox.x)
            topLeft.y = min(topLeft.y, cNode.hitbox.y)
            bottomRight.x = max(bottomRight.x, cNode.hitbox.x + cNode.hitbox.width)
            bottomRight.y = max(bottomRight.y, cNode.hitbox.y + cNode.hitbox.height)
        }

        for placeholderArray in externalPlaceholder.values {
            for placeholder in placeholderArray {
                guard let cNode = placeholder.second else { continue }
                topLeft.x = min(topLeft.x, cNode.hitbox.x)
                topLeft.y = min(topLeft.y, cNode.hitbox.y)
                bottomRight.x = max(bottomRight.x, cNode.hitbox.x + cNode.hitbox.width)
                bottomRight.y = max(bottomRight.y, cNode.hitbox.y + cNode.hitbox.height)
            }
        }

        _globalOffset = topLeft.clone().negate()
        _graphSize = bottomRight.clone().sub(topLeft)

        cGraph.cGroups.removeAll()
        cGraph.cNodes.removeAll()
    }

    // MARK: - CRectNode implementation

    package class CRectNode: CNode {
        package var rect: ElkRectangle
        package var individualSpacing: Double?

        init(_ rect: ElkRectangle, _ spacing: Double?) {
            self.rect = rect
            self.individualSpacing = spacing
            super.init(hitbox: ElkRectangle(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
        }

        package func getPositionVector() -> KVector {
            return KVector(x: rect.x, y: rect.y)
        }

        package override func getHorizontalSpacing() -> Double {
            return individualSpacing ?? 0
        }

        package override func getVerticalSpacing() -> Double {
            return individualSpacing ?? 0
        }

        package override func applyElementPosition() {
            rect.x = hitbox.x
            rect.y = hitbox.y
        }

        package override func getElementPosition() -> Double {
            return rect.x
        }
    }
}
