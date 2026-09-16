import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_LabelSideSelector {
    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        let mode = layeredGraph.getProperty(LayeredOptions.EDGE_LABELS_SIDE_SELECTION) as? EdgeLabelSideSelection ?? .ALWAYS_DOWN
        _ = monitor.begin("Label side selection", 1)

        switch mode {
        case .ALWAYS_UP:
            sameSide(layeredGraph, .ABOVE)
        case .ALWAYS_DOWN:
            sameSide(layeredGraph, .BELOW)
        case .DIRECTION_UP:
            basedOnDirection(layeredGraph, .ABOVE)
        case .DIRECTION_DOWN:
            basedOnDirection(layeredGraph, .BELOW)
        case .SMART_UP:
            smart(layeredGraph, .ABOVE)
        case .SMART_DOWN:
            smart(layeredGraph, .BELOW)
        }

        monitor.done()
    }

    // MARK: - Simple Placement Strategies

    private func sameSide(_ graph: LGraph, _ labelSide: LabelSide) {
        for layer in graph.layers {
            for node in layer.nodes {
                if node.type == .label {
                    applyLabelSideToNode(node, labelSide)
                }
                for edge in node.getOutgoingEdges() {
                    applyLabelSideToEdge(edge, labelSide)
                }
            }
        }
    }

    private func basedOnDirection(_ graph: LGraph, _ sideForRightwardEdges: LabelSide) {
        for layer in graph.layers {
            for node in layer.nodes {
                if node.type == .label {
                    let side = doesEdgePointRightNode(node) ? sideForRightwardEdges : sideForRightwardEdges.opposite()
                    applyLabelSideToNode(node, side)
                }
                for edge in node.getOutgoingEdges() {
                    let side = doesEdgePointRightEdge(edge) ? sideForRightwardEdges : sideForRightwardEdges.opposite()
                    applyLabelSideToEdge(edge, side)
                }
            }
        }
    }

    // MARK: - Smart Placement Strategy

    private func smart(_ graph: LGraph, _ defaultSide: LabelSide) {
        var dummyNodeQueue = [LNode]()

        for layer in graph.layers {
            var topGroup = true
            var labelDummiesInQueue = 0

            for node in layer.nodes {
                switch node.type {
                case .label:
                    labelDummiesInQueue += 1
                    dummyNodeQueue.append(node)
                case .longEdge:
                    dummyNodeQueue.append(node)
                case .normal:
                    smartForRegularNode(node, defaultSide)
                    if !dummyNodeQueue.isEmpty {
                        smartForConsecutiveDummyNodeRun(&dummyNodeQueue, labelDummiesInQueue, topGroup, false, defaultSide)
                    }
                    topGroup = false
                    labelDummiesInQueue = 0
                default:
                    if !dummyNodeQueue.isEmpty {
                        smartForConsecutiveDummyNodeRun(&dummyNodeQueue, labelDummiesInQueue, topGroup, false, defaultSide)
                    }
                    topGroup = false
                    labelDummiesInQueue = 0
                }
            }

            if !dummyNodeQueue.isEmpty {
                smartForConsecutiveDummyNodeRun(&dummyNodeQueue, labelDummiesInQueue, topGroup, true, defaultSide)
            }
        }
    }

    private func smartForConsecutiveDummyNodeRun(_ dummyNodes: inout [LNode], _ labelDummyCount: Int,
                                                  _ topGroup: Bool, _ bottomGroup: Bool, _ defaultSide: LabelSide) {
        if topGroup
            && (!bottomGroup || dummyNodes.count > 1)
            && labelDummyCount == 1,
            let first = dummyNodes.first,
            first.type == .label {
            applyLabelSideToNode(first, .ABOVE)
        } else if bottomGroup
            && (!topGroup || dummyNodes.count > 1)
            && labelDummyCount == 1,
            let last = dummyNodes.last,
            last.type == .label {
            applyLabelSideToNode(last, .BELOW)
        } else if dummyNodes.count == 2 {
            applyLabelSideToNode(dummyNodes.removeFirst(), .ABOVE)
            applyLabelSideToNode(dummyNodes.removeFirst(), .BELOW)
        } else {
            applyForDummyNodeRunWithSimpleLoops(dummyNodes, labelDummyCount, defaultSide)
        }

        dummyNodes.removeAll()
    }

    private func applyForDummyNodeRunWithSimpleLoops(_ dummyNodes: [LNode], _ labelDummyCount: Int,
                                                      _ defaultSide: LabelSide) {
        var labelDummyRun = [LNode]()
        var prevLongEdgeSource: LNode? = nil
        var prevLongEdgeTarget: LNode? = nil

        for currentDummy in dummyNodes {
            let currLongEdgeSource = getLongEdgeEndNode(currentDummy, true)
            let currLongEdgeTarget = getLongEdgeEndNode(currentDummy, false)

            if prevLongEdgeSource !== currLongEdgeSource || prevLongEdgeTarget !== currLongEdgeTarget {
                applyLabelSidesToLabelDummyRun(&labelDummyRun, defaultSide)
                prevLongEdgeSource = currLongEdgeSource
                prevLongEdgeTarget = currLongEdgeTarget
            }

            labelDummyRun.append(currentDummy)
        }

        applyLabelSidesToLabelDummyRun(&labelDummyRun, defaultSide)
    }

    private func getLongEdgeEndNode(_ labelDummy: LNode, _ source: Bool) -> LNode? {
        let endPort = labelDummy.getProperty(source
            ? InternalProperties.LONG_EDGE_SOURCE
            : InternalProperties.LONG_EDGE_TARGET) as? LPort
        return endPort?.node
    }

    private func applyLabelSidesToLabelDummyRun(_ labelDummyRun: inout [LNode], _ defaultSide: LabelSide) {
        if !labelDummyRun.isEmpty {
            if labelDummyRun.count == 2 {
                applyLabelSideToNode(labelDummyRun[0], .ABOVE)
                applyLabelSideToNode(labelDummyRun[1], .BELOW)
            } else {
                for dummyNode in labelDummyRun {
                    applyLabelSideToNode(dummyNode, defaultSide)
                }
            }
            labelDummyRun.removeAll()
        }
    }

    private func smartForRegularNode(_ node: LNode, _ defaultSide: LabelSide) {
        var endLabelQueue = [[LLabel]]()
        var currentPortSide: PortSide? = nil

        for port in node.ports {
            if port.side != currentPortSide {
                if !endLabelQueue.isEmpty, let side = currentPortSide {
                    smartForRegularNodePortEndLabels(&endLabelQueue, side, defaultSide)
                }
                endLabelQueue.removeAll()
                currentPortSide = port.side
            }

            if let portEndLabels = EndLabelPreprocessor.gatherLabels(port: port) {
                endLabelQueue.append(portEndLabels)
            }
        }

        if !endLabelQueue.isEmpty, let currentPortSide = currentPortSide {
            smartForRegularNodePortEndLabels(&endLabelQueue, currentPortSide, defaultSide)
        }
    }

    private func smartForRegularNodePortEndLabels(_ endLabelQueue: inout [[LLabel]], _ portSide: PortSide,
                                                    _ defaultSide: LabelSide) {
        if endLabelQueue.count == 2 {
            if portSide == .NORTH || portSide == .EAST {
                applyLabelSideToLabels(endLabelQueue.removeFirst(), .ABOVE)
                applyLabelSideToLabels(endLabelQueue.removeFirst(), .BELOW)
            } else {
                applyLabelSideToLabels(endLabelQueue.removeFirst(), .BELOW)
                applyLabelSideToLabels(endLabelQueue.removeFirst(), .ABOVE)
            }
        } else {
            for labelList in endLabelQueue {
                applyLabelSideToLabels(labelList, defaultSide)
            }
        }
    }

    // MARK: - Helper Methods

    private func applyLabelSideToNode(_ labelDummy: LNode, _ side: LabelSide) {
        if labelDummy.type == .label {
            let effectiveSide: LabelSide = labelDummy.isInlineEdgeLabel() ? .INLINE : side

            labelDummy.setProperty(InternalProperties.LABEL_SIDE, value: effectiveSide)

            if effectiveSide != .BELOW {
                guard let originEdge = labelDummy.getProperty(InternalProperties.ORIGIN) as? LEdge else { return }
                let thickness = originEdge.getProperty(LayeredOptions.EDGE_THICKNESS) as? Double ?? 0.0

                var portPos: Double = 0
                if effectiveSide == .ABOVE {
                    portPos = labelDummy.size.y - ceil(thickness / 2)
                } else if effectiveSide == .INLINE {
                    guard let graph = labelDummy.getGraph() else { return }
                    let edgeLabelSpacing = graph.getProperty(LayeredOptions.SPACING_EDGE_LABEL) as? Double ?? 0.0
                    portPos = ceil((labelDummy.size.y - edgeLabelSpacing - thickness)) / 2.0
                    labelDummy.size.y -= edgeLabelSpacing
                    labelDummy.size.y -= thickness
                }

                for port in labelDummy.ports {
                    port.position.y = portPos
                }
            }
        }
    }

    private func applyLabelSideToEdge(_ edge: LEdge, _ side: LabelSide) {
        for label in edge.labels {
            label.setProperty(InternalProperties.LABEL_SIDE, value: side)
        }
    }

    private func applyLabelSideToLabels(_ labels: [LLabel], _ side: LabelSide) {
        for label in labels {
            label.setProperty(InternalProperties.LABEL_SIDE, value: side)
        }
    }

    private func doesEdgePointRightEdge(_ edge: LEdge) -> Bool {
        return !(edge.getProperty(InternalProperties.REVERSED) as? Bool ?? false)
    }

    private func doesEdgePointRightNode(_ labelDummy: LNode) -> Bool {
        let incoming = labelDummy.getIncomingEdges().first
        let outgoing = labelDummy.getOutgoingEdges().first

        let inRight = incoming.map { doesEdgePointRightEdge($0) } ?? false
        let outRight = outgoing.map { doesEdgePointRightEdge($0) } ?? false
        return inRight || outRight
    }
}
