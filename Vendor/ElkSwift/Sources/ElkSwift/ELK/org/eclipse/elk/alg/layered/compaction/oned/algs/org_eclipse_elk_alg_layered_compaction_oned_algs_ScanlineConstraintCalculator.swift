/*******************************************************************************
 * Copyright (c) 2016 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

import Foundation

// MARK: - Main Class

package class ScanlineConstraintCalculator: IConstraintCalculationAlgorithm {

    package static let EPSILON: Double = 0.5

    /** The surrounding compactor object. */
    package var compactor: OneDimensionalCompactor?

    package var constraintsScanlineHandler: ConstraintsScanlineHandler?

    package init() {}

    package func calculateConstraints(_ theCompactor: OneDimensionalCompactor) {
        self.compactor = theCompactor
        self.constraintsScanlineHandler = ConstraintsScanlineHandler(compactor: theCompactor)

        // consider all nodes, do not add spacing
        sweep(filterFun: { _ in true }, spacingFun: { _ in 0.0 })
    }

    /**
     * Executes a single sweep of the scanline.
     */
    package func sweep(filterFun: @escaping (CNode) -> Bool, spacingFun: @escaping (CNode) -> Double) {
        guard let compactor = compactor, let constraintsScanlineHandler = constraintsScanlineHandler else { return }

        blowUpHitboxes(filter: filterFun, spacingFun: spacingFun)

        // add all nodes twice (once for the lower, once for the upper border)
        var points: [Timestamp] = []
        for n in compactor.cGraph.cNodes {
            if filterFun(n) {
                points.append(Timestamp(node: n, low: true))
                points.append(Timestamp(node: n, low: false))
            }
        }

        // reset internal state
        constraintsScanlineHandler.reset()

        // execute the scanline - sort and process
        let handler = constraintsScanlineHandler
        let comparator: (Timestamp, Timestamp) -> Bool = { p1, p2 in
            var y1 = p1.node.hitbox.y
            if !p1.low { y1 += p1.node.hitbox.height }
            var y2 = p2.node.hitbox.y
            if !p2.low { y2 += p2.node.hitbox.height }

            if y1 != y2 { return y1 < y2 }
            // if equal, sort high before low (high = !low)
            if !p1.low && p2.low { return true }
            if !p2.low && p1.low { return false }
            return false
        }

        Scanline<Timestamp>.execute(points, comparator: comparator, eventHandler: { p in
            handler.handle(p)
        })

        normalizeHitboxes(filter: filterFun, spacingFun: spacingFun)
    }

    package func blowUpHitboxes(filter: @escaping (CNode) -> Bool, spacingFun: @escaping (CNode) -> Double) {
        guard let compactor = compactor else { return }

        for n in compactor.cGraph.cNodes {

            if !filter(n) {
                continue
            }

            let spacing = spacingFun(n)

            if spacing > 0 {
                if !(compactor.direction.isHorizontal() && n.spacingIgnore.up)
                        && !(compactor.direction.isVertical() && n.spacingIgnore.left) {
                    n.hitbox.y -= max(0, spacing / 2 - Self.EPSILON)
                }
                if !(compactor.direction.isHorizontal() && n.spacingIgnore.down)
                        && !(compactor.direction.isVertical() && n.spacingIgnore.right) {
                    n.hitbox.height += max(0, spacing - 2 * Self.EPSILON)
                }
            }
        }
    }

    package func normalizeHitboxes(filter: @escaping (CNode) -> Bool, spacingFun: @escaping (CNode) -> Double) {
        guard let compactor = compactor else { return }
        for n in compactor.cGraph.cNodes {

            if !filter(n) {
                continue
            }

            let spacing = spacingFun(n)

            if spacing > 0 {
                if !(compactor.direction.isHorizontal() && n.spacingIgnore.up)
                        && !(compactor.direction.isVertical() && n.spacingIgnore.left) {
                    n.hitbox.y += max(0, spacing / 2 - Self.EPSILON)
                }
                if !(compactor.direction.isHorizontal() && n.spacingIgnore.down)
                        && !(compactor.direction.isVertical() && n.spacingIgnore.right) {
                    n.hitbox.height -= spacing - 2 * Self.EPSILON
                }
            }
        }
    }

    /**
     * A timestamp representing upper (y) or lower (y+height) border of a rectangle.
     */
    package class Timestamp {
        var low: Bool
        var node: CNode

        init(node: CNode, low: Bool) {
            self.node = node
            self.low = low
        }
    }

    /**
     * Implements the scanline procedure as discussed by Lengauer.
     */
    package class ConstraintsScanlineHandler {

        /**
         * Sorted set of intervals sorted by the x coordinate of a CNode's hitbox center.
         */
        package var intervals: ScanlineOrderedSet<CNode>
        /** Candidate array with possible constraints. */
        package var cand: [CNode?]

        package weak var compactor: OneDimensionalCompactor?

        init(compactor: OneDimensionalCompactor) {
            self.compactor = compactor
            self.intervals = ScanlineOrderedSet<CNode>(comparator: { c1, c2 in
                let x1 = c1.hitbox.x + (c1.hitbox.width / 2)
                let x2 = c2.hitbox.x + (c2.hitbox.width / 2)
                if x1 < x2 { return .orderedAscending }
                if x1 > x2 { return .orderedDescending }
                return .orderedSame
            })
            self.cand = Array(repeating: nil, count: max(1, compactor.cGraph.cNodes.count))
        }

        /**
         * Resets the internal data structures.
         */
        package func reset() {
            intervals.removeAll()
            let count = compactor?.cGraph.cNodes.count ?? 0
            cand = Array(repeating: nil, count: max(1, count))
            var index = 0
            for n in compactor?.cGraph.cNodes ?? [] {
                n.id = index
                index += 1
            }
        }

        package func handle(_ p: Timestamp) {
            if p.low {
                insert(p)
            } else {
                delete(p)
            }
        }

        package func insert(_ p: Timestamp) {
            intervals.insert(p.node)

            cand[p.node.id] = intervals.lower(p.node)

            if let right = intervals.higher(p.node) {
                cand[right.id] = p.node
            }
        }

        package func delete(_ p: Timestamp) {

            if let left = intervals.lower(p.node), left === cand[p.node.id] {
                // different groups?
                if left.cGroup != nil && left.cGroup !== p.node.cGroup {
                    left.constraints.append(p.node)
                }
            }

            if let right = intervals.higher(p.node), cand[right.id] === p.node {
                // different groups?
                if right.cGroup != nil && right.cGroup !== p.node.cGroup {
                    p.node.constraints.append(right)
                }
            }

            // we are done with you!
            intervals.remove(p.node)
        }
    }
}

// MARK: - Helper Types

/// A simple ordered set implementation using binary search, for scanline constraint calculation.
package class ScanlineOrderedSet<T: AnyObject> {
    package var elements: [T] = []
    package var comparator: (T, T) -> ComparisonResult

    package init(comparator: @escaping (T, T) -> ComparisonResult) {
        self.comparator = comparator
    }

    package func insert(_ element: T) {
        // Check if already present
        for e in elements where e === element { return }

        var lo = 0
        var hi = elements.count - 1

        while lo <= hi {
            let mid = (lo + hi) / 2
            let cmp = comparator(elements[mid], element)

            if cmp == .orderedAscending {
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }

        elements.insert(element, at: lo)
    }

    package func remove(_ element: T) {
        if let index = elements.firstIndex(where: { $0 === element }) {
            elements.remove(at: index)
        }
    }

    package func lower(_ element: T) -> T? {
        var lo = 0
        var hi = elements.count - 1
        var result: T? = nil

        while lo <= hi {
            let mid = (lo + hi) / 2
            let cmp = comparator(elements[mid], element)

            if cmp == .orderedAscending {
                result = elements[mid]
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }

        return result
    }

    package func higher(_ element: T) -> T? {
        var lo = 0
        var hi = elements.count - 1
        var result: T? = nil

        while lo <= hi {
            let mid = (lo + hi) / 2
            let cmp = comparator(elements[mid], element)

            if cmp == .orderedDescending {
                result = elements[mid]
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }

        return result
    }

    package func removeAll() {
        elements.removeAll()
    }
}
