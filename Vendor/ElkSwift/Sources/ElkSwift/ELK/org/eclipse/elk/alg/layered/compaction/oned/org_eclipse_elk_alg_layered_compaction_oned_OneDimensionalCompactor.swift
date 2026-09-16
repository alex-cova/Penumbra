// Copyright (c) 2016 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

// MARK: - Main Class

/**
 * Implements the compaction of a CGraph.
 */
package final class OneDimensionalCompactor {

    /** Longest path-based compaction strategy. */
    package static let LONGEST_PATH_COMPACTION: ICompactionAlgorithm = LongestPathCompaction()

    /** Currently used compaction algorithm. */
    package var compactionAlgorithm: ICompactionAlgorithm = OneDimensionalCompactor.LONGEST_PATH_COMPACTION

    /** Constraint calculation using a scanline technique. */
    package static let SCANLINE_CONSTRAINTS: IConstraintCalculationAlgorithm = ScanlineConstraintCalculator()
    /** Constraint calculation by pair-wise comparison of CNodes. */
    package static let QUADRATIC_CONSTRAINTS: IConstraintCalculationAlgorithm = QuadraticConstraintCalculation()
    /** Currently used instance of the constraint calculation algorithm. */
    package var constraintAlgorithm: IConstraintCalculationAlgorithm = OneDimensionalCompactor.SCANLINE_CONSTRAINTS

    /** the CGraph. */
    package var cGraph: CGraph
    /** compacting in this direction. */
    package var direction: Direction = Direction.UNDEFINED
    /** a function that sets the CNode#reposition flag according to the direction. */
    package var lockingStrategy: ((Pair<CNode, Direction>) -> Bool)?
    /** flag indicating whether the finish() method has been called. */
    package var finished: Bool = false

    package init(_ cGraph: CGraph) {
        self.cGraph = cGraph
        // the default locking strategy locks CNodes if they are not constrained
        lockingStrategy = { pair in
            pair.first?.cGroup?.outDegree != 0
        }

        // for any pre-specified groups, deduce the offset of the elements
        _ = calculateGroupOffsets()

        // wrap any plain CNodes into a CGroup
        for n in cGraph.cNodes {
            if n.cGroup == nil {
                let group = CGroup(n)
                cGraph.cGroups.append(group)
            }
        }
    }

    @discardableResult
    package func setLockingStrategy(_ strategy: @escaping (Pair<CNode, Direction>) -> Bool) -> OneDimensionalCompactor {
        lockingStrategy = strategy
        return self
    }

    @discardableResult
    package func compact() -> OneDimensionalCompactor {
        if finished {
            assertionFailure("The compactor instance has been finished already.")
            return self
        }

        if direction == Direction.UNDEFINED {
            _ = changeDirection(.LEFT)
        }

        for g in cGraph.cGroups {
            g.outDegree = 0
        }

        for n in cGraph.cNodes {
            n.startPos = Double.greatestFiniteMagnitude
            for incN in n.constraints {
                incN.cGroup?.outDegree += 1
            }
        }

        compactionAlgorithm.compact(self)

        for node in cGraph.cNodes {
            node.reposition = true
        }

        return self
    }

    @discardableResult
    package func finish() -> OneDimensionalCompactor {
        _ = changeDirection(.LEFT)
        finished = true
        return self
    }

    @discardableResult
    package func changeDirection(_ dir: Direction) -> OneDimensionalCompactor {
        if finished {
            assertionFailure("The compactor instance has been finished already.")
            return self
        }

        if !cGraph.supports(dir) {
            assertionFailure("The direction \(dir) is not supported by the CGraph instance.")
            return self
        }

        if dir == direction {
            return self
        }

        let oldDirection = direction
        direction = dir

        switch oldDirection {
        case .UNDEFINED:
            switch dir {
            case .LEFT: calculateConstraints()
            case .RIGHT: mirrorHitboxes(); calculateConstraints()
            case .UP: transposeHitboxes(); calculateConstraints()
            case .DOWN: transposeHitboxes(); mirrorHitboxes(); calculateConstraints()
            default: break
            }
        case .LEFT:
            switch dir {
            case .RIGHT: mirrorHitboxes(); reverseConstraints()
            case .UP: transposeHitboxes(); calculateConstraints()
            case .DOWN: transposeHitboxes(); mirrorHitboxes(); calculateConstraints()
            default: break
            }
        case .RIGHT:
            switch dir {
            case .LEFT: mirrorHitboxes(); reverseConstraints()
            case .UP: mirrorHitboxes(); transposeHitboxes(); calculateConstraints()
            case .DOWN: mirrorHitboxes(); transposeHitboxes(); mirrorHitboxes(); calculateConstraints()
            default: break
            }
        case .UP:
            switch dir {
            case .LEFT: transposeHitboxes(); calculateConstraints()
            case .RIGHT: transposeHitboxes(); mirrorHitboxes(); calculateConstraints()
            case .DOWN: mirrorHitboxes(); reverseConstraints()
            default: break
            }
        case .DOWN:
            switch dir {
            case .LEFT: mirrorHitboxes(); transposeHitboxes(); calculateConstraints()
            case .RIGHT: mirrorHitboxes(); transposeHitboxes(); mirrorHitboxes(); calculateConstraints()
            case .UP: mirrorHitboxes(); reverseConstraints()
            default: break
            }
        default:
            break
        }

        return self
    }

    @discardableResult
    package func applyLockingStrategy() -> OneDimensionalCompactor {
        return applyLockingStrategy(direction)
    }

    @discardableResult
    package func applyLockingStrategy(_ dir: Direction) -> OneDimensionalCompactor {
        for cGroup in cGraph.cGroups {
            cGroup.reposition = true
        }

        for cNode in cGraph.cNodes {
            let lockState = lockingStrategy?(Pair(first: cNode, second: dir)) ?? true
            cNode.reposition = lockState
            if let group = cNode.cGroup {
                group.reposition = group.reposition && lockState
            }
        }

        return self
    }

    @discardableResult
    package func forceConstraintsRecalculation() -> OneDimensionalCompactor {
        calculateConstraints()
        return self
    }

    @discardableResult
    package func calculateGroupOffsets() -> OneDimensionalCompactor {
        for group in cGraph.cGroups {
            group.reference = nil

            for n in group.cNodes {
                n.cGroupOffset.x = 0.0
                n.cGroupOffset.y = 0.0
                if group.reference.map({ n.hitbox.x < $0.hitbox.x }) ?? true {
                    group.reference = n
                }
            }

            if let ref = group.reference {
                for n in group.cNodes {
                    n.cGroupOffset.x = n.hitbox.x - ref.hitbox.x
                    n.cGroupOffset.y = n.hitbox.y - ref.hitbox.y
                }
            }
        }

        return self
    }

    package func isLocked(_ node: CNode, _ dir: Direction) -> Bool {
        return node.lock.get(direction: dir)
    }

    package func isLocked(_ group: CGroup, _ dir: Direction) -> Bool {
        // A group is locked if any of its nodes is locked
        for node in group.cNodes {
            if node.lock.get(direction: dir) {
                return true
            }
        }
        return false
    }

    // MARK: - Private API

    package func mirrorHitboxes() {
        for cNode in cGraph.cNodes {
            cNode.hitbox.x = -cNode.hitbox.x - cNode.hitbox.width
            if let parentNode = cNode.parentNode {
                cNode.cGroupOffset.x = -cNode.cGroupOffset.x + parentNode.hitbox.width
            }
        }
        _ = calculateGroupOffsets()
    }

    package func transposeHitboxes() {
        for cNode in cGraph.cNodes {
            let tmp = cNode.hitbox.x
            cNode.hitbox.x = cNode.hitbox.y
            cNode.hitbox.y = tmp

            let tmpWidth = cNode.hitbox.width
            cNode.hitbox.width = cNode.hitbox.height
            cNode.hitbox.height = tmpWidth

            let tmpOffsetX = cNode.cGroupOffset.x
            cNode.cGroupOffset.x = cNode.cGroupOffset.y
            cNode.cGroupOffset.y = tmpOffsetX
        }
        _ = calculateGroupOffsets()
    }

    package func calculateConstraints() {
        for cNode in cGraph.cNodes {
            cNode.constraints.removeAll()
        }
        constraintAlgorithm.calculateConstraints(self)
        calculateConstraintsForCGroups()
    }

    package func calculateConstraintsForCGroups() {
        for group in cGraph.cGroups {
            group.outDegree = 0
            group.incomingConstraints.removeAll()
        }

        for group in cGraph.cGroups {
            for cNode in group.cNodes {
                for inc in cNode.constraints {
                    if inc.cGroup !== group {
                        group.incomingConstraints.insert(inc)
                        inc.cGroup?.outDegree += 1
                    }
                }
            }
        }
    }

    package func reverseConstraints() {
        var incMap: [CNode: [CNode]] = [:]
        for cNode in cGraph.cNodes {
            incMap[cNode] = []
        }

        for cNode in cGraph.cNodes {
            cNode.startPos = Double.greatestFiniteMagnitude
            for inc in cNode.constraints {
                incMap[inc]?.append(cNode)
            }
        }

        for cNode in cGraph.cNodes {
            cNode.constraints.removeAll()
            if let constraints = incMap[cNode] {
                cNode.constraints = constraints
            }
        }

        calculateConstraintsForCGroups()
    }
}
