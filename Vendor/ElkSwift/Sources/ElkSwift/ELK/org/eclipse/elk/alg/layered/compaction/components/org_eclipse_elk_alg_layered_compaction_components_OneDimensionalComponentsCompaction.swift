// Copyright (c) 2016 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

// MARK: - Main Class

package final class OneDimensionalComponentsCompaction<N, E> {

    var compactionGraph: CGraph?

    var transformer: ComponentsToCGraphTransformer?

    var verticalExternalExtensions: [Pair<CGroup, CNode>] = []
    var horizontalExternalExtensions: [Pair<CGroup, CNode>] = []

    var compactor: OneDimensionalCompactor?

    var topLeft: KVector?
    var bottomRight: KVector?

    static var MAX_ITERATION: Int { 10 }
    static var EPSILON: Double { 0.0001 }

    package enum Dir {
        case HORZ, VERT
    }

    static var LEFT_RIGHT: Set<Direction> { [.LEFT, .RIGHT] }
    static var UP_DOWN: Set<Direction> { [.UP, .DOWN] }

    package init() {}

    package static func initCompaction(_ ccs: InternalConnectedComponents, spacing: Double) -> OneDimensionalComponentsCompaction<N, E> {
        let compaction = OneDimensionalComponentsCompaction<N, E>()
        let xformer = ComponentsToCGraphTransformer(spacing: spacing)
        compaction.transformer = xformer
        compaction.compactionGraph = xformer.transform(ccs)
        return compaction
    }

    package func compact(monitor: Any) {
        guard let compactionGraph = compactionGraph, let transformer = transformer else { return }
        var allNodes: [CNode] = []
        verticalExternalExtensions = []
        horizontalExternalExtensions = []

        for entry in transformer.externalExtensions.values {
            allNodes.append(entry.second)
            let dir = entry.first
            if dir.isHorizontal() {
                if let cGroup = entry.second.cGroup {
                    horizontalExternalExtensions.append(Pair(cGroup, entry.second))
                }
            } else {
                if let cGroup = entry.second.cGroup {
                    verticalExternalExtensions.append(Pair(cGroup, entry.second))
                }
            }
        }

        addExternalEdgeRepresentations(horizontalExternalExtensions)
        addExternalEdgeRepresentations(verticalExternalExtensions)

        compactor = OneDimensionalCompactor(compactionGraph)

        removeExternalEdgeRepresentations(horizontalExternalExtensions)
        removeExternalEdgeRepresentations(verticalExternalExtensions)

        guard let compactor = compactor else { return }
        allNodes += compactor.cGraph.cNodes

        let tl = KVector(x: Double.greatestFiniteMagnitude, y: Double.greatestFiniteMagnitude)
        let br = KVector(x: -Double.greatestFiniteMagnitude, y: -Double.greatestFiniteMagnitude)
        topLeft = tl
        bottomRight = br

        for cNode in allNodes {
            tl.x = min(tl.x, cNode.hitbox.x)
            tl.y = min(tl.y, cNode.hitbox.y)
            br.x = max(br.x, cNode.hitbox.x + cNode.hitbox.width)
            br.y = max(br.y, cNode.hitbox.y + cNode.hitbox.height)
        }

        var run = 0
        var delta: Double = 0.0
        repeat {
            delta = compactRun(run: run)
            run += 1
        } while (run < 2 || delta > OneDimensionalComponentsCompaction.EPSILON) && run < OneDimensionalComponentsCompaction.MAX_ITERATION

        compactor.finish()
        transformer.applyLayout()
    }

    func compactRun(run: Int) -> Double {
        guard let compactionGraph = compactionGraph, let compactor = compactor else { return 0.0 }
        var delta: Double = 0.0

        for g in compactionGraph.cGroups {
            g.delta = 0.0
            g.deltaNormalized = 0.0
        }

        addPlaceholders(dir: .HORZ)
        addExternalEdgeRepresentations(verticalExternalExtensions)
        compactor.calculateGroupOffsets()

        let direction: Direction = .LEFT

        _ = compactor
            .changeDirection(direction)
            .compact()
            .changeDirection(direction.opposite())
            .compact()
            .changeDirection(direction)
            .compact()

        _ = compactor.changeDirection(.LEFT)

        removeExternalEdgeRepresentations(verticalExternalExtensions)
        removePlaceholders(dir: .HORZ)

        updateExternalExtensionDimensions(dir: .HORZ)
        updatePlaceholders(dir: .VERT)

        addPlaceholders(dir: .VERT)
        addExternalEdgeRepresentations(horizontalExternalExtensions)
        compactor.calculateGroupOffsets()

        for g in compactionGraph.cGroups {
            delta += abs(g.deltaNormalized)
        }

        for g in compactionGraph.cGroups {
            g.delta = 0.0
            g.deltaNormalized = 0.0
        }

        let direction2: Direction = .UP

        _ = compactor
            .changeDirection(direction2)
            .compact()
            .changeDirection(direction2.opposite())
            .compact()
            .changeDirection(direction2)
            .compact()

        _ = compactor.changeDirection(.LEFT)

        removeExternalEdgeRepresentations(horizontalExternalExtensions)
        removePlaceholders(dir: .VERT)

        updateExternalExtensionDimensions(dir: .VERT)
        updatePlaceholders(dir: .HORZ)

        for g in compactionGraph.cGroups {
            delta += abs(g.deltaNormalized)
        }

        return delta
    }

    package func getGraphSize() -> KVector {
        return transformer?.getGraphSize() ?? KVector()
    }

    package func getOffset(_ c: InternalComponent) -> KVector {
        guard let transformer = transformer else { return KVector() }
        let individual = transformer.getOffset(c)
        return individual.clone().negate().add(transformer.getGlobalOffset())
    }

    func addExternalEdgeRepresentations(_ ees: [Pair<CGroup, CNode>]) {
        guard let compactionGraph = compactionGraph else { return }
        for p in ees {
            guard let node = p.second, let group = p.first else { continue }
            compactionGraph.cNodes.append(node)
            group.addCNode(node)
        }
    }

    func removeExternalEdgeRepresentations(_ ees: [Pair<CGroup, CNode>]) {
        guard let compactionGraph = compactionGraph else { return }
        for p in ees {
            guard let node = p.second, let group = p.first else { continue }
            compactionGraph.cNodes.removeAll { $0 === node }
            _ = group.removeCNode(node)
        }
    }

    func addPlaceholders(dir: Dir) {
        guard let compactionGraph = compactionGraph, let transformer = transformer else { return }
        let dirs: Set<Direction> = (dir == .VERT) ? OneDimensionalComponentsCompaction.UP_DOWN : OneDimensionalComponentsCompaction.LEFT_RIGHT
        for d in dirs {
            for pair in transformer.externalPlaceholder[d] ?? [] {
                guard let node = pair.second else { continue }
                compactionGraph.cNodes.append(node)
                if let cGroup = node.cGroup {
                    compactionGraph.cGroups.append(cGroup)
                }
            }
        }
    }

    func removePlaceholders(dir: Dir) {
        guard let compactionGraph = compactionGraph, let transformer = transformer else { return }
        let dirs: Set<Direction> = (dir == .VERT) ? OneDimensionalComponentsCompaction.UP_DOWN : OneDimensionalComponentsCompaction.LEFT_RIGHT
        for d in dirs {
            for pair in transformer.externalPlaceholder[d] ?? [] {
                guard let node = pair.second else { continue }
                compactionGraph.cNodes.removeAll { $0 === node }
                compactionGraph.cGroups.removeAll { $0 === node.cGroup }
            }
        }
    }

    func updatePlaceholders(dir: Dir) {
        guard let transformer = transformer else { return }
        let dirs: Set<Direction> = (dir == .VERT) ? OneDimensionalComponentsCompaction.UP_DOWN : OneDimensionalComponentsCompaction.LEFT_RIGHT
        for d in dirs {
            for pair in transformer.externalPlaceholder[d] ?? [] {
                guard let cNode = pair.second, let parentComponentGroup = pair.first else { continue }

                let adelta = parentComponentGroup.deltaNormalized

                switch d {
                case .LEFT, .RIGHT:
                    cNode.hitbox.y += adelta
                case .UP, .DOWN:
                    cNode.hitbox.x += adelta
                default: break
                }
            }
        }
    }

    func updateExternalExtensionDimensions(dir: Dir) {
        guard let transformer = transformer, let topLeft = topLeft else { return }
        for entry in transformer.externalExtensions.values {
            let eeDir = entry.first

            if dir == .VERT {
                if eeDir != .UP && eeDir != .DOWN {
                    continue
                }
            } else {
                if eeDir != .LEFT && eeDir != .RIGHT {
                    continue
                }
            }

            let cNode = entry.second
            let adelta = 0.0 // simplified

            switch eeDir {
            case .LEFT:
                cNode.hitbox.x = topLeft.x
                cNode.hitbox.width = max(1, cNode.hitbox.width + adelta)
            case .RIGHT:
                cNode.hitbox.x += adelta
                cNode.hitbox.width = max(1, cNode.hitbox.width - adelta)
            case .UP:
                cNode.hitbox.y = topLeft.y
                cNode.hitbox.height = max(1, cNode.hitbox.height + adelta)
            case .DOWN:
                cNode.hitbox.y += adelta
                cNode.hitbox.height = max(1, cNode.hitbox.height - adelta)
            default: break
            }
        }
    }
}
