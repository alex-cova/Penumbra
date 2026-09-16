import Foundation

package class org_eclipse_elk_alg_layered_p4nodes_bk_ThresholdStrategy {
    package static let THRESHOLD = Double.greatestFiniteMagnitude
    package static let EPSILON = 0.0001

    package let bal: org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout
    package let ni: org_eclipse_elk_alg_layered_p4nodes_bk_NeighborhoodInformation
    package var blockFinished: Set<ObjectIdentifier> = []
    package var postProcessablesQueue = ArrayDeque<Postprocessable>()
    package var postProcessablesStack: [Postprocessable] = []

    package init(
        _ bal: org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout,
        _ ni: org_eclipse_elk_alg_layered_p4nodes_bk_NeighborhoodInformation
    ) {
        self.bal = bal
        self.ni = ni
    }

    package func finishBlock(_ n: org_eclipse_elk_alg_layered_graph_LNode) {
        blockFinished.insert(ObjectIdentifier(n))
    }

    package func calculateThreshold(
        _ oldThresh: Double,
        _ blockRoot: org_eclipse_elk_alg_layered_graph_LNode,
        _ currentNode: org_eclipse_elk_alg_layered_graph_LNode
    ) -> Double {
        assertionFailure("Subclasses must override calculateThreshold(_:_:_)")
        return 0
    }

    package func postProcess() {
        assertionFailure("Subclasses must override postProcess()")
    }

    package func getOther(
        _ edge: org_eclipse_elk_alg_layered_graph_LEdge,
        _ n: org_eclipse_elk_alg_layered_graph_LNode
    ) -> org_eclipse_elk_alg_layered_graph_LNode {
        if edge.getSource()?.getNode() === n {
            if let other = edge.getTarget()?.getNode() {
                return other
            }
        } else if edge.getTarget()?.getNode() === n {
            if let other = edge.getSource()?.getNode() {
                return other
            }
        }
        assertionFailure("Node \(n) is neither source nor target of edge \(edge)")
        return n
    }

    package class NullThresholdStrategy: org_eclipse_elk_alg_layered_p4nodes_bk_ThresholdStrategy {
        package override func calculateThreshold(
            _ oldThresh: Double,
            _ blockRoot: org_eclipse_elk_alg_layered_graph_LNode,
            _ currentNode: org_eclipse_elk_alg_layered_graph_LNode
        ) -> Double {
            if bal.vdir == .UP {
                return Double.infinity
            } else {
                return -Double.infinity
            }
        }

        package override func postProcess() {}
    }

    package class SimpleThresholdStrategy: org_eclipse_elk_alg_layered_p4nodes_bk_ThresholdStrategy {
        package override func calculateThreshold(
            _ oldThresh: Double,
            _ blockRoot: org_eclipse_elk_alg_layered_graph_LNode,
            _ currentNode: org_eclipse_elk_alg_layered_graph_LNode
        ) -> Double {
            let isRoot = blockRoot === currentNode
            let isLast = bal.align[currentNode.id] === blockRoot

            if !(isRoot || isLast) {
                return oldThresh
            }

            var threshold = oldThresh
            if isRoot {
                threshold = getBound(blockRoot, true)
            }
            if threshold.isInfinite && isLast {
                threshold = getBound(currentNode, false)
            }
            return threshold
        }

        package func pickEdge(_ pp: Postprocessable) -> Postprocessable {
            let edges: [org_eclipse_elk_alg_layered_graph_LEdge]
            if pp.isRoot {
                edges = bal.hdir == .RIGHT ? pp.free.getIncomingEdges() : pp.free.getOutgoingEdges()
            } else {
                edges = bal.hdir == .LEFT ? pp.free.getIncomingEdges() : pp.free.getOutgoingEdges()
            }

            var hasEdges = false
            for edge in edges {
                let freeRoot = bal.root[pp.free.id] ?? pp.free
                let onlyDummies = bal.od[freeRoot.id]
                if !onlyDummies && edge.isInLayerEdge() {
                    continue
                }

                if bal.su[freeRoot.id] || bal.su[freeRoot.id] {
                    continue
                }

                hasEdges = true
                let otherRoot = bal.root[getOther(edge, pp.free).id] ?? getOther(edge, pp.free)
                if blockFinished.contains(ObjectIdentifier(otherRoot)) {
                    pp.hasEdges = true
                    pp.edge = edge
                    return pp
                }
            }

            pp.hasEdges = hasEdges
            pp.edge = nil
            return pp
        }

        package func getBound(
            _ blockNode: org_eclipse_elk_alg_layered_graph_LNode,
            _ isRoot: Bool
        ) -> Double {
            let invalid = bal.vdir == .UP ? Double.infinity : -Double.infinity
            let pick = pickEdge(Postprocessable(blockNode, isRoot))

            if pick.edge == nil && pick.hasEdges {
                postProcessablesQueue.append(pick)
                return invalid
            } else if let edge = pick.edge {
                guard let left = edge.getSource(), let right = edge.getTarget() else {
                    return invalid
                }

                let threshold: Double
                if isRoot {
                    let rootPort = bal.hdir == .RIGHT ? right : left
                    let otherPort = bal.hdir == .RIGHT ? left : right
                    guard
                        let rootNode = rootPort.getNode(),
                        let otherNode = otherPort.getNode()
                    else {
                        return invalid
                    }
                    let otherRoot = bal.root[otherNode.id] ?? otherNode
                    threshold = bal.y[otherRoot.id]
                        + bal.innerShift[otherNode.id]
                        + otherPort.getPosition().y
                        + otherPort.getAnchor().y
                        - bal.innerShift[rootNode.id]
                        - rootPort.getPosition().y
                        - rootPort.getAnchor().y
                } else {
                    let rootPort = bal.hdir == .LEFT ? right : left
                    let otherPort = bal.hdir == .LEFT ? left : right
                    guard
                        let rootNode = rootPort.getNode(),
                        let otherNode = otherPort.getNode()
                    else {
                        return invalid
                    }
                    let otherRoot = bal.root[otherNode.id] ?? otherNode
                    threshold = bal.y[otherRoot.id]
                        + bal.innerShift[otherNode.id]
                        + otherPort.getPosition().y
                        + otherPort.getAnchor().y
                        - bal.innerShift[rootNode.id]
                        - rootPort.getPosition().y
                        - rootPort.getAnchor().y
                }

                if let leftNode = left.getNode() {
                    let leftRoot = bal.root[leftNode.id] ?? leftNode
                    bal.su[leftRoot.id] = true
                }
                if let rightNode = right.getNode() {
                    let rightRoot = bal.root[rightNode.id] ?? rightNode
                    bal.su[rightRoot.id] = true
                }
                return threshold
            }
            return invalid
        }

        package override func postProcess() {
            while !postProcessablesQueue.isEmpty {
                let pp = postProcessablesQueue.removeFirst()
                let pick = pickEdge(pp)
                guard let edge = pick.edge else {
                    continue
                }

                let freeRoot = bal.root[pick.free.id] ?? pick.free
                let onlyDummies = bal.od[freeRoot.id]
                if !onlyDummies && edge.isInLayerEdge() {
                    continue
                }

                let moved = process(pick)
                if !moved {
                    postProcessablesStack.append(pick)
                }
            }

            while let pp = postProcessablesStack.popLast() {
                _ = process(pp)
            }
        }

        package func process(_ pp: Postprocessable) -> Bool {
            guard let edge = pp.edge else {
                return false
            }

            let fix: org_eclipse_elk_alg_layered_graph_LPort
            let block: org_eclipse_elk_alg_layered_graph_LPort
            if edge.getSource()?.getNode() === pp.free {
                guard let target = edge.getTarget(), let source = edge.getSource() else {
                    return false
                }
                fix = target
                block = source
            } else {
                guard let target = edge.getTarget(), let source = edge.getSource() else {
                    return false
                }
                fix = source
                block = target
            }

            let delta = bal.calculateDelta(fix, block)
            guard let blockNode = block.getNode() else {
                return false
            }

            if delta > 0 && delta < Self.THRESHOLD {
                let availableSpace = bal.checkSpaceAbove(blockNode, delta, ni)
                assert(abs(availableSpace) <= Self.EPSILON || availableSpace >= 0)
                bal.shiftBlock(blockNode, -availableSpace)
                return availableSpace > 0
            } else if delta < 0 && -delta < Self.THRESHOLD {
                let availableSpace = bal.checkSpaceBelow(blockNode, -delta, ni)
                assert(abs(availableSpace) <= Self.EPSILON || availableSpace >= 0)
                bal.shiftBlock(blockNode, availableSpace)
                return availableSpace > 0
            }

            return false
        }
    }

    package class Postprocessable {
        var free: org_eclipse_elk_alg_layered_graph_LNode
        var isRoot: Bool
        var hasEdges: Bool = false
        var edge: org_eclipse_elk_alg_layered_graph_LEdge?

        init(_ free: org_eclipse_elk_alg_layered_graph_LNode, _ isRoot: Bool) {
            self.free = free
            self.isRoot = isRoot
        }
    }
}
