/*******************************************************************************
 * Copyright (c) 2017 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

import Foundation

package final class RectangleStripOverlapRemover {

    // MARK: - Constants

    package static let defaultGap: Double = 5.0

    // MARK: - Fields

    package let overlapRemovalDirection: OverlapRemovalDirection
    package var gapVertical: Double = defaultGap
    package var gapHorizontal: Double = defaultGap
    package var startCoordinate: Double = 0.0
    package var overlapRemovalStrategy: IRectangleStripOverlapRemovalStrategy?
    package var rectangleNodes: [RectangleNode] = []

    // MARK: - Creation

    private init(direction: OverlapRemovalDirection) {
        self.overlapRemovalDirection = direction
    }

    package static func create(for direction: OverlapRemovalDirection) -> RectangleStripOverlapRemover {
        return RectangleStripOverlapRemover(direction: direction)
    }

    // MARK: - Configuration

    package func withGap(_ horizontalGap: Double, _ verticalGap: Double) -> RectangleStripOverlapRemover {
        gapHorizontal = horizontalGap
        gapVertical = verticalGap
        return self
    }

    package func withStartCoordinate(_ coordinate: Double) -> RectangleStripOverlapRemover {
        startCoordinate = coordinate
        return self
    }

    package func withOverlapRemovalStrategy(_ strategy: IRectangleStripOverlapRemovalStrategy) -> RectangleStripOverlapRemover {
        overlapRemovalStrategy = strategy
        return self
    }

    @discardableResult
    package func addRectangle(_ rectangle: ElkRectangle) -> RectangleStripOverlapRemover {
        let transformedRectangle = importRectangle(rectangle)
        let node = RectangleNode(originalRectangle: rectangle, rectangle: transformedRectangle)
        rectangleNodes.append(node)
        return self
    }

    // MARK: - Getters

    package func getHorizontalGap() -> Double {
        return gapHorizontal
    }

    package func getVerticalGap() -> Double {
        return gapVertical
    }

    package func getRectangleNodes() -> [RectangleNode] {
        return rectangleNodes
    }

    // MARK: - Coordinate Transformation

    package func importRectangle(_ rectangle: ElkRectangle) -> ElkRectangle {
        switch overlapRemovalDirection {
        case .up, .down:
            return rectangle
        case .left, .right:
            return ElkRectangle(x: rectangle.y, y: 0, width: rectangle.height, height: rectangle.width)
        }
    }

    package func exportRectangle(_ rectangleNode: RectangleNode, stripSize: Double) {
        let rectangle = rectangleNode.rectangle
        let originalRectangle = rectangleNode.originalRectangle

        switch overlapRemovalDirection {
        case .up:
            originalRectangle.y = startCoordinate - rectangle.height - rectangle.y
        case .down:
            originalRectangle.y += startCoordinate
        case .left:
            originalRectangle.x = startCoordinate - rectangle.height - rectangle.y
        case .right:
            originalRectangle.x = startCoordinate + rectangle.y
        }
    }

    // MARK: - Actual Algorithm

    @discardableResult
    package func removeOverlaps() -> Double {
        if overlapRemovalStrategy == nil {
            overlapRemovalStrategy = GreedyRectangleStripOverlapRemover()
        }

        rectangleNodes.sort { RectangleStripOverlapRemover.compareLeftRectangleBorders($0, $1) }

        computeOverlaps()
        guard let strategy = overlapRemovalStrategy else { return 0 }
        let stripSize = strategy.removeOverlaps(self)

        rectangleNodes.forEach { node in
            exportRectangle(node, stripSize: stripSize)
        }

        return stripSize
    }

    package func computeOverlaps() {
        let intersectingNodes = OverlapSortedSet(compare: RectangleStripOverlapRemover.compareRightRectangleBorders)
        var scanlinePos: Double = Double.greatestFiniteMagnitude * -1

        for currNode in rectangleNodes {
            scanlinePos = currNode.rectangle.x

            while !intersectingNodes.isEmpty {
                guard let intersectingRectangle = intersectingNodes.first() else { break }

                if intersectingRectangle.rectangle.x + intersectingRectangle.rectangle.width < scanlinePos {
                    intersectingNodes.remove(intersectingRectangle)
                } else {
                    break
                }
            }

            for intersectingNode in intersectingNodes {
                intersectingNode.overlappingNodes.append(currNode)
                currNode.overlappingNodes.append(intersectingNode)
            }

            intersectingNodes.add(currNode)
        }
    }

    // MARK: - Utility Methods

    package static func compareLeftRectangleBorders(_ rn1: RectangleNode, _ rn2: RectangleNode) -> Bool {
        return rn1.rectangle.x < rn2.rectangle.x
    }

    package static func compareRightRectangleBorders(_ rn1: RectangleNode, _ rn2: RectangleNode) -> Bool {
        return rn1.rectangle.x + rn1.rectangle.width < rn2.rectangle.x + rn2.rectangle.width
    }

    // MARK: - Support Classes

    package enum OverlapRemovalDirection {
        case up
        case down
        case left
        case right

        // Uppercase aliases
        package static var UP: OverlapRemovalDirection { .up }
        package static var DOWN: OverlapRemovalDirection { .down }
        package static var LEFT: OverlapRemovalDirection { .left }
        package static var RIGHT: OverlapRemovalDirection { .right }
    }

    package final class RectangleNode {

        package var originalRectangle: ElkRectangle
        package var rectangle: ElkRectangle
        package var overlappingNodes: [RectangleNode] = []

        init(originalRectangle: ElkRectangle, rectangle: ElkRectangle) {
            self.originalRectangle = originalRectangle
            self.rectangle = rectangle
        }

        package func getRectangle() -> ElkRectangle {
            return rectangle
        }

        package func getOverlappingNodes() -> [RectangleNode] {
            return overlappingNodes
        }
    }
}

// MARK: - OverlapSortedSet (simple sorted set for RectangleNode)

package class OverlapSortedSet: Sequence {
    package var elements: [RectangleStripOverlapRemover.RectangleNode] = []
    package let compare: (RectangleStripOverlapRemover.RectangleNode, RectangleStripOverlapRemover.RectangleNode) -> Bool

    package init(compare: @escaping (RectangleStripOverlapRemover.RectangleNode, RectangleStripOverlapRemover.RectangleNode) -> Bool) {
        self.compare = compare
    }

    package func add(_ element: RectangleStripOverlapRemover.RectangleNode) {
        var index = 0
        while index < elements.count && compare(elements[index], element) {
            index += 1
        }
        elements.insert(element, at: index)
    }

    package func remove(_ element: RectangleStripOverlapRemover.RectangleNode) {
        if let idx = elements.firstIndex(where: { $0 === element }) {
            elements.remove(at: idx)
        }
    }

    package func first() -> RectangleStripOverlapRemover.RectangleNode? {
        return elements.first
    }

    package var isEmpty: Bool {
        return elements.isEmpty
    }

    package func makeIterator() -> Array<RectangleStripOverlapRemover.RectangleNode>.Iterator {
        return elements.makeIterator()
    }
}
