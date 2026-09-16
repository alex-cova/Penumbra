// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p4nodes/bk/BKCompactor.java

import Foundation

package class org_eclipse_elk_alg_layered_p4nodes_bk_BKCompactor: org_eclipse_elk_alg_layered_p4nodes_bk_ICompactor {
    package enum OptionKeys {
        static let nodePlacementBkEdgeStraightening = "org.eclipse.elk.layered.nodePlacement.bk.edgeStraightening"
        static let spacingNodeNode = "org.eclipse.elk.spacing.nodeNode"
    }

    package let layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph
    package var threshStrategy: org_eclipse_elk_alg_layered_p4nodes_bk_ThresholdStrategy?
    package let ni: org_eclipse_elk_alg_layered_p4nodes_bk_NeighborhoodInformation
    package let useSimpleThreshold: Bool
    package var spacings: org_eclipse_elk_alg_layered_options_Spacings

    package final class ClassNode {
        var classShift: Double?
        var node: org_eclipse_elk_alg_layered_graph_LNode?
        var outgoing: [ClassEdge] = []
        var indegree: Int = 0

        package func addEdge(_ target: ClassNode, _ separation: Double) {
            let edge = ClassEdge()
            edge.target = target
            edge.separation = separation
            target.indegree += 1
            outgoing.append(edge)
        }
    }

    package final class ClassEdge {
        var separation: Double = 0
        weak var target: ClassNode?
    }

    package var sinkNodes: [ObjectIdentifier: ClassNode] = [:]
    package var placedBlockRoots: Set<ObjectIdentifier> = []

    package init(
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ ni: org_eclipse_elk_alg_layered_p4nodes_bk_NeighborhoodInformation
    ) {
        self.layeredGraph = layeredGraph
        self.ni = ni
        self.spacings = layeredGraph.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.SPACINGS)
            ?? org_eclipse_elk_alg_layered_options_Spacings()

        let straightening = layeredGraph.getProperty(OptionKeys.nodePlacementBkEdgeStraightening)
            as? org_eclipse_elk_alg_layered_options_EdgeStraighteningStrategy ?? .NONE
        self.useSimpleThreshold = (straightening == .IMPROVE_STRAIGHTNESS)
    }

    /// Java source: BKCompactor.horizontalCompaction(BKAlignedLayout)
    package func horizontalCompaction(_ bal: org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout) {
        for layer in layeredGraph.getLayers() {
            for node in layer.getNodes() {
                bal.sink[node.id] = node
                bal.shift[node.id] = bal.vdir == .UP ? -Double.infinity : Double.infinity
            }
        }

        sinkNodes.removeAll(keepingCapacity: true)
        placedBlockRoots.removeAll(keepingCapacity: true)

        var layers = layeredGraph.getLayers()
        if bal.hdir == .LEFT {
            layers.reverse()
        }

        if useSimpleThreshold {
            threshStrategy = org_eclipse_elk_alg_layered_p4nodes_bk_ThresholdStrategy.SimpleThresholdStrategy(bal, ni)
        } else {
            threshStrategy = org_eclipse_elk_alg_layered_p4nodes_bk_ThresholdStrategy.NullThresholdStrategy(bal, ni)
        }

        for layer in layers {
            var nodes = layer.getNodes()
            if bal.vdir == .UP {
                nodes.reverse()
            }

            for v in nodes {
                if bal.root[v.id] === v {
                    placeBlock(v, bal)
                }
            }
        }

        placeClasses(bal)

        for layer in layers {
            for v in layer.getNodes() {
                guard let root = bal.root[v.id] else {
                    continue
                }
                bal.y[v.id] = bal.y[root.id]

                if v === root,
                   let sink = bal.sink[v.id]
                {
                    let sinkShift = bal.shift[sink.id]
                    if (bal.vdir == .UP && sinkShift > -Double.infinity)
                        || (bal.vdir == .DOWN && sinkShift < Double.infinity)
                    {
                        bal.y[v.id] += sinkShift
                    }
                }
            }
        }

        threshStrategy?.postProcess()
    }

    /// Java source: BKCompactor.placeBlock(LNode, BKAlignedLayout)
    package func placeBlock(
        _ root: org_eclipse_elk_alg_layered_graph_LNode,
        _ bal: org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout
    ) {
        let rootKey = ObjectIdentifier(root)
        if placedBlockRoots.contains(rootKey) {
            return
        }

        var isInitialAssignment = true
        bal.y[root.id] = 0.0

        var currentNode = root
        var thresh = bal.vdir == .DOWN ? -Double.infinity : Double.infinity

        repeat {
            guard let layer = currentNode.getLayer() else {
                break
            }
            let currentIndexInLayer = ni.nodeIndex[currentNode.id]
            let currentLayerSize = layer.getNodes().count

            if (bal.vdir == .DOWN && currentIndexInLayer > 0)
                || (bal.vdir == .UP && currentIndexInLayer < currentLayerSize - 1)
            {
                let neighbor: org_eclipse_elk_alg_layered_graph_LNode
                if bal.vdir == .UP {
                    neighbor = layer.getNodes()[currentIndexInLayer + 1]
                } else {
                    neighbor = layer.getNodes()[currentIndexInLayer - 1]
                }
                guard let neighborRoot = bal.root[neighbor.id] else {
                    break
                }

                placeBlock(neighborRoot, bal)

                thresh = threshStrategy?.calculateThreshold(thresh, root, currentNode) ?? thresh

                if bal.sink[root.id] === root {
                    bal.sink[root.id] = bal.sink[neighborRoot.id]
                }

                if bal.sink[root.id] === bal.sink[neighborRoot.id] {
                    let spacing = spacings.getVerticalSpacing(currentNode, neighbor)

                    if bal.vdir == .UP {
                        let currentBlockPosition = bal.y[root.id]
                        let newPosition = bal.y[neighborRoot.id]
                            + bal.innerShift[neighbor.id]
                            - neighbor.getMargin().top
                            - spacing
                            - currentNode.getMargin().bottom
                            - currentNode.getSize().y
                            - bal.innerShift[currentNode.id]

                        if isInitialAssignment {
                            isInitialAssignment = false
                            bal.y[root.id] = Swift.min(newPosition, thresh)
                        } else {
                            bal.y[root.id] = Swift.min(currentBlockPosition, Swift.min(newPosition, thresh))
                        }
                    } else {
                        let currentBlockPosition = bal.y[root.id]
                        let newPosition = bal.y[neighborRoot.id]
                            + bal.innerShift[neighbor.id]
                            + neighbor.getSize().y
                            + neighbor.getMargin().bottom
                            + spacing
                            + currentNode.getMargin().top
                            - bal.innerShift[currentNode.id]

                        if isInitialAssignment {
                            isInitialAssignment = false
                            bal.y[root.id] = Swift.max(newPosition, thresh)
                        } else {
                            bal.y[root.id] = Swift.max(currentBlockPosition, Swift.max(newPosition, thresh))
                        }
                    }
                } else {
                    let spacing = layeredGraph.getProperty(OptionKeys.spacingNodeNode) as? Double ?? 0.0

                    guard let rootSink = bal.sink[root.id],
                          let neighborSink = bal.sink[neighborRoot.id]
                    else {
                        break
                    }

                    let sinkNode = getOrCreateClassNode(rootSink, bal)
                    let neighborSinkNode = getOrCreateClassNode(neighborSink, bal)

                    if bal.vdir == .UP {
                        let requiredSpace = bal.y[root.id]
                            + bal.innerShift[currentNode.id]
                            + currentNode.getSize().y
                            + currentNode.getMargin().bottom
                            + spacing
                            - (bal.y[neighborRoot.id]
                                + bal.innerShift[neighbor.id]
                                - neighbor.getMargin().top)

                        sinkNode.addEdge(neighborSinkNode, requiredSpace)
                    } else {
                        let requiredSpace = bal.y[root.id]
                            + bal.innerShift[currentNode.id]
                            - currentNode.getMargin().top
                            - bal.y[neighborRoot.id]
                            - bal.innerShift[neighbor.id]
                            - neighbor.getSize().y
                            - neighbor.getMargin().bottom
                            - spacing

                        sinkNode.addEdge(neighborSinkNode, requiredSpace)
                    }
                }
            } else {
                thresh = threshStrategy?.calculateThreshold(thresh, root, currentNode) ?? thresh
            }

            guard let next = bal.align[currentNode.id] else {
                break
            }
            currentNode = next
        } while currentNode !== root

        threshStrategy?.finishBlock(root)
        placedBlockRoots.insert(rootKey)
    }

    /// Java source: BKCompactor.placeClasses(BKAlignedLayout)
    package func placeClasses(_ bal: org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout) {
        var sinks: [ClassNode] = sinkNodes.values.filter { $0.indegree == 0 }
        var cursor = 0

        while cursor < sinks.count {
            let n = sinks[cursor]
            cursor += 1

            if n.classShift == nil {
                n.classShift = 0.0
            }

            for e in n.outgoing {
                guard let target = e.target else {
                    continue
                }

                if target.classShift == nil {
                    target.classShift = (n.classShift ?? 0.0) + e.separation
                } else if bal.vdir == .DOWN {
                    target.classShift = Swift.min(target.classShift ?? 0.0, (n.classShift ?? 0.0) + e.separation)
                } else {
                    target.classShift = Swift.max(target.classShift ?? 0.0, (n.classShift ?? 0.0) + e.separation)
                }

                target.indegree -= 1
                if target.indegree == 0 {
                    sinks.append(target)
                }
            }
        }

        for n in sinkNodes.values {
            if let sinkNode = n.node {
                bal.shift[sinkNode.id] = n.classShift ?? 0.0
            }
        }
    }

    /// Java source: BKCompactor.getOrCreateClassNode(LNode, BKAlignedLayout)
    package func getOrCreateClassNode(
        _ sinkNode: org_eclipse_elk_alg_layered_graph_LNode,
        _ bal: org_eclipse_elk_alg_layered_p4nodes_bk_BKAlignedLayout
    ) -> ClassNode {
        _ = bal
        let key = ObjectIdentifier(sinkNode)
        if let existing = sinkNodes[key] {
            return existing
        }

        let created = ClassNode()
        created.node = sinkNode
        sinkNodes[key] = created
        return created
    }
}
