import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_LabelDummySwitcher {

    package static let INCLUDE_LABEL = Property<Bool>("edgelabelcenterednessanalysis.includelabel")

    private var layerWidths: [Double] = []

    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        _ = monitor.begin("Label dummy switching", 1)

        let defaultPlacementStrategy = layeredGraph.getProperty(LayeredOptions.EDGE_LABELS_CENTER_LABEL_PLACEMENT_STRATEGY)
            as? CenterEdgeLabelPlacementStrategy ?? .MEDIAN_LAYER

        assignIdsToLayers(layeredGraph)

        let labelDummyInfos = gatherLabelDummyInfos(layeredGraph, defaultPlacementStrategy)

        layerWidths = [Double](repeating: 0, count: layeredGraph.layers.count)

        for strategy in CenterEdgeLabelPlacementStrategy.allCases {
            if strategy.usesLabelSizeInformation() && !(labelDummyInfos[strategy]?.isEmpty ?? true) {
                calculateLayerWidths(layeredGraph)
                break
            }
        }

        for strategy in CenterEdgeLabelPlacementStrategy.allCases {
            if !strategy.usesLabelSizeInformation() {
                processStrategy(labelDummyInfos[strategy] ?? [])
            }
        }

        for strategy in CenterEdgeLabelPlacementStrategy.allCases {
            if strategy.usesLabelSizeInformation() {
                processStrategy(labelDummyInfos[strategy] ?? [])
            }
        }

        layerWidths = []
        monitor.done()
    }

    private func assignIdsToLayers(_ layeredGraph: LGraph) {
        for (index, layer) in layeredGraph.layers.enumerated() {
            layer.id = index
        }
    }

    private func gatherLabelDummyInfos(_ layeredGraph: LGraph, _ defaultPlacementStrategy: CenterEdgeLabelPlacementStrategy)
        -> [CenterEdgeLabelPlacementStrategy: [LabelDummyInfo]] {

        var infos = [CenterEdgeLabelPlacementStrategy: [LabelDummyInfo]]()
        for strategy in CenterEdgeLabelPlacementStrategy.allCases {
            infos[strategy] = []
        }

        for layer in layeredGraph.layers {
            for node in layer.nodes {
                if node.type == .label {
                    let info = LabelDummyInfo(node, defaultPlacementStrategy)
                    infos[info.placementStrategy, default: []].append(info)
                }
            }
        }

        return infos
    }

    private func calculateLayerWidths(_ layeredGraph: LGraph) {
        for layer in layeredGraph.layers {
            layerWidths[layer.id] = LGraphUtil.findMaxNonDummyNodeWidth(layer, respectNodeMargins: false)
        }
    }

    private func processStrategy(_ labelDummyInfos: [LabelDummyInfo]) {
        if labelDummyInfos.isEmpty { return }

        if labelDummyInfos[0].placementStrategy == .SPACE_EFFICIENT_LAYER {
            computeSpaceEfficientAssignment(labelDummyInfos)
        } else {
            for info in labelDummyInfos {
                switch info.placementStrategy {
                case .CENTER_LAYER:
                    assignLayer(info, findCenterLayerTargetId(info))
                case .MEDIAN_LAYER:
                    assignLayer(info, findMedianLayerTargetId(info))
                case .WIDEST_LAYER:
                    assignLayer(info, findWidestLayerTargetId(info))
                case .HEAD_LAYER:
                    setEndLayerNodeAlignment(info)
                    assignLayer(info, findEndLayerTargetId(info, true))
                case .TAIL_LAYER:
                    setEndLayerNodeAlignment(info)
                    assignLayer(info, findEndLayerTargetId(info, false))
                case .SPACE_EFFICIENT_LAYER:
                    break
                }
                updateLongEdgeSourceLabelDummyInfo(info)
            }
        }
    }

    // MARK: - Widest Layer

    private func findWidestLayerTargetId(_ info: LabelDummyInfo) -> Int {
        var widestLayerIndex = info.leftmostLayerId
        for index in (widestLayerIndex + 1)...info.rightmostLayerId {
            if layerWidths[index] > layerWidths[widestLayerIndex] {
                widestLayerIndex = index
            }
        }
        return widestLayerIndex
    }

    // MARK: - Center Layer

    private func findCenterLayerTargetId(_ info: LabelDummyInfo) -> Int {
        let sums = computeLayerWidthSums(info)
        let threshold = sums[sums.count - 1] / 2
        for i in 0..<sums.count {
            if sums[i] >= threshold {
                return info.leftmostLayerId + i
            }
        }
        return info.leftmostLayerId + info.leftLongEdgeDummies.count
    }

    private func computeLayerWidthSums(_ info: LabelDummyInfo) -> [Double] {
        guard let lgraph = info.labelDummy.getGraph() else { return [] }
        let edgeNodeSpacing = (lgraph.getProperty(LayeredOptions.SPACING_EDGE_NODE_BETWEEN_LAYERS) as? Double ?? 0.0) * 2
        let nodeNodeSpacing = lgraph.getProperty(LayeredOptions.SPACING_NODE_NODE_BETWEEN_LAYERS) as? Double ?? 0.0
        let minSpaceBetweenLayers = max(edgeNodeSpacing, nodeNodeSpacing)

        var sums = [Double](repeating: 0, count: info.totalDummyCount())
        var currentWidthSum = -minSpaceBetweenLayers
        var idx = 0

        for leftDummy in info.leftLongEdgeDummies {
            guard let leftDummyLayer = leftDummy.layer else { continue }
            currentWidthSum += layerWidths[leftDummyLayer.id] + minSpaceBetweenLayers
            sums[idx] = currentWidthSum
            idx += 1
        }

        if let labelDummyLayer = info.labelDummy.layer {
            currentWidthSum += layerWidths[labelDummyLayer.id] + minSpaceBetweenLayers
            sums[idx] = currentWidthSum
            idx += 1
        }

        for rightDummy in info.rightLongEdgeDummies {
            guard let rightDummyLayer = rightDummy.layer else { continue }
            currentWidthSum += layerWidths[rightDummyLayer.id] + minSpaceBetweenLayers
            sums[idx] = currentWidthSum
            idx += 1
        }

        return sums
    }

    // MARK: - Median Layer

    private func findMedianLayerTargetId(_ info: LabelDummyInfo) -> Int {
        let layers = info.totalDummyCount()
        let lowerMedian = (layers - 1) / 2
        return info.leftmostLayerId + lowerMedian
    }

    // MARK: - End Layer

    private func findEndLayerTargetId(_ info: LabelDummyInfo, _ headLayer: Bool) -> Int {
        let reversed = isPartOfReversedEdge(info)
        if (headLayer && !reversed) || (!headLayer && reversed) {
            return info.rightmostLayerId
        } else {
            return info.leftmostLayerId
        }
    }

    private func setEndLayerNodeAlignment(_ info: LabelDummyInfo) {
        let isHeadLabel = info.placementStrategy == .HEAD_LAYER
        let isReversed = isPartOfReversedEdge(info)

        if (isHeadLabel && !isReversed) || (!isHeadLabel && isReversed) {
            info.labelDummy.setProperty(LayeredOptions.ALIGNMENT, value: Alignment.right)
        } else {
            info.labelDummy.setProperty(LayeredOptions.ALIGNMENT, value: Alignment.left)
        }
    }

    private func isPartOfReversedEdge(_ info: LabelDummyInfo) -> Bool {
        let incoming = info.labelDummy.getIncomingEdges().first
        let outgoing = info.labelDummy.getOutgoingEdges().first

        let inReversed = incoming.flatMap { $0.getProperty(InternalProperties.REVERSED) as? Bool } ?? false
        let outReversed = outgoing.flatMap { $0.getProperty(InternalProperties.REVERSED) as? Bool } ?? false
        return inReversed || outReversed
    }

    // MARK: - Space Efficient

    private func computeSpaceEfficientAssignment(_ labelDummyInfos: [LabelDummyInfo]) {
        let nonTrivialLabels = performTrivialAssignments(labelDummyInfos)
        if nonTrivialLabels.isEmpty { return }

        let sorted = nonTrivialLabels.sorted { $0.labelDummy.size.x > $1.labelDummy.size.x }
        for labelIndex in 0..<sorted.count {
            assignLayer(sorted[labelIndex], findPotentiallyWidestLayer(sorted, labelIndex))
        }
    }

    private func performTrivialAssignments(_ labelDummyInfos: [LabelDummyInfo]) -> [LabelDummyInfo] {
        var remaining = [LabelDummyInfo]()
        for info in labelDummyInfos {
            if info.leftmostLayerId == info.rightmostLayerId {
                assignLayer(info, info.leftmostLayerId)
            } else if !assignToWiderLayer(info) {
                remaining.append(info)
            }
        }
        return remaining
    }

    private func assignToWiderLayer(_ info: LabelDummyInfo) -> Bool {
        let dummyWidth = info.labelDummy.size.x
        guard let graph = info.labelDummy.getGraph() else { return false }
        let validLayers = Array(graph.layers[info.leftmostLayerId...(info.rightmostLayerId)])
        for layer in validLayers {
            if layer.size.x >= dummyWidth {
                assignLayer(info, layer.id)
                return true
            }
        }
        return false
    }

    private func findPotentiallyWidestLayer(_ labelDummyInfos: [LabelDummyInfo], _ labelIndex: Int) -> Int {
        let info = labelDummyInfos[labelIndex]
        let labelDummyWidth = info.labelDummy.size.x

        var widestLayerIndex = info.leftmostLayerId
        var widestLayerWidth: Double = 0

        for layer in info.leftmostLayerId...info.rightmostLayerId {
            if labelDummyWidth <= layerWidths[layer] {
                return layer
            }

            var potentialWidth = layerWidths[layer]

            for label in (labelIndex + 1)..<labelDummyInfos.count {
                let currInfo = labelDummyInfos[label]
                if currInfo.leftmostLayerId <= layer && currInfo.rightmostLayerId >= layer {
                    potentialWidth = max(potentialWidth, currInfo.labelDummy.size.x)
                    break
                }
            }

            if potentialWidth > widestLayerWidth {
                widestLayerIndex = layer
                widestLayerWidth = potentialWidth
            }
        }

        return widestLayerIndex
    }

    // MARK: - Swapping Utilities

    private func assignLayer(_ info: LabelDummyInfo, _ targetLayerIndex: Int) {
        if targetLayerIndex != info.leftmostLayerId + info.leftLongEdgeDummies.count {
            swapNodes(info.labelDummy, info.ithDummyNode(targetLayerIndex - info.leftmostLayerId))
        }

        guard let newLayer = info.labelDummy.layer else { return }
        let newLayerId = newLayer.id
        layerWidths[newLayerId] = max(layerWidths[newLayerId], info.labelDummy.size.x)

        if let representedLabels = info.labelDummy.getProperty(InternalProperties.REPRESENTED_LABELS) as? [LLabel] {
            for label in representedLabels {
                label.setProperty(
                    org_eclipse_elk_alg_layered_intermediate_LabelDummySwitcher.INCLUDE_LABEL, value: true)
            }
        }
    }

    private func swapNodes(_ labelDummy: LNode, _ longEdgeDummy: LNode) {
        guard let layer1 = labelDummy.layer,
              let layer2 = longEdgeDummy.layer else { return }

        let dummy1LayerPosition = layer1.nodes.firstIndex(where: { $0 === labelDummy }) ?? 0
        let dummy2LayerPosition = layer2.nodes.firstIndex(where: { $0 === longEdgeDummy }) ?? 0

        guard let inputPort1 = labelDummy.getPorts(.INPUT).first,
              let outputPort1 = labelDummy.getPorts(.OUTPUT).first,
              let inputPort2 = longEdgeDummy.getPorts(.INPUT).first,
              let outputPort2 = longEdgeDummy.getPorts(.OUTPUT).first else { return }

        let incomingEdges1 = LGraphUtil.toEdgeArray(inputPort1.incomingEdges)
        let outgoingEdges1 = LGraphUtil.toEdgeArray(outputPort1.outgoingEdges)
        let incomingEdges2 = LGraphUtil.toEdgeArray(inputPort2.incomingEdges)
        let outgoingEdges2 = LGraphUtil.toEdgeArray(outputPort2.outgoingEdges)

        labelDummy.setLayer(dummy2LayerPosition, layer2)
        for edge in incomingEdges2 { edge.setTarget(inputPort1) }
        for edge in outgoingEdges2 { edge.setSource(outputPort1) }

        longEdgeDummy.setLayer(dummy1LayerPosition, layer1)
        for edge in incomingEdges1 { edge.setTarget(inputPort2) }
        for edge in outgoingEdges1 { edge.setSource(outputPort2) }
    }

    private func updateLongEdgeSourceLabelDummyInfo(_ info: LabelDummyInfo) {
        doUpdateLongEdgeLabelDummyInfo(info.labelDummy,
            nextElement: { node in
                guard let edge = node.getIncomingEdges().first,
                      let source = edge.source,
                      let sourceNode = source.node else { return nil }
                return sourceNode
            },
            value: true)
    }

    private func doUpdateLongEdgeLabelDummyInfo(_ labelDummy: LNode,
                                                  nextElement: (LNode) -> LNode?,
                                                  value: Bool) {
        guard var longEdgeDummy = nextElement(labelDummy) else { return }
        while longEdgeDummy.type == .longEdge {
            longEdgeDummy.setProperty(InternalProperties.LONG_EDGE_BEFORE_LABEL_DUMMY, value: value)
            guard let next = nextElement(longEdgeDummy) else { return }
            longEdgeDummy = next
        }
    }

    // MARK: - LabelDummyInfo

    private class LabelDummyInfo {
        let labelDummy: LNode
        var placementStrategy: CenterEdgeLabelPlacementStrategy
        var leftLongEdgeDummies = [LNode]()
        var rightLongEdgeDummies = [LNode]()
        var leftmostLayerId: Int = 0
        var rightmostLayerId: Int = 0

        init(_ labelDummy: LNode, _ defaultPlacementStrategy: CenterEdgeLabelPlacementStrategy) {
            self.labelDummy = labelDummy
            self.placementStrategy = defaultPlacementStrategy

            gatherLeftLongEdgeDummies()
            gatherRightLongEdgeDummies()

            let labelDummyLayerId = labelDummy.layer?.id ?? 0
            leftmostLayerId = leftLongEdgeDummies.isEmpty ? labelDummyLayerId : (leftLongEdgeDummies[0].layer?.id ?? labelDummyLayerId)
            rightmostLayerId = rightLongEdgeDummies.isEmpty ? labelDummyLayerId : (rightLongEdgeDummies.last?.layer?.id ?? labelDummyLayerId)

            if let representedLabels = labelDummy.getProperty(InternalProperties.REPRESENTED_LABELS) as? [LLabel] {
                for label in representedLabels {
                    if label.hasProperty(LayeredOptions.EDGE_LABELS_CENTER_LABEL_PLACEMENT_STRATEGY) {
                        if let strategy = label.getProperty(LayeredOptions.EDGE_LABELS_CENTER_LABEL_PLACEMENT_STRATEGY)
                            as? CenterEdgeLabelPlacementStrategy {
                            placementStrategy = strategy
                            break
                        }
                    }
                }
            }
        }

        private func gatherLeftLongEdgeDummies() {
            var source = labelDummy
            repeat {
                guard let edge = source.getIncomingEdges().first,
                      let sourcePort = edge.source,
                      let sourceNode = sourcePort.node else { break }
                source = sourceNode
                if source.type == .longEdge {
                    leftLongEdgeDummies.append(source)
                }
            } while source.type == .longEdge
            leftLongEdgeDummies.reverse()
        }

        private func gatherRightLongEdgeDummies() {
            var target = labelDummy
            repeat {
                guard let edge = target.getOutgoingEdges().first,
                      let targetPort = edge.target,
                      let targetNode = targetPort.node else { break }
                target = targetNode
                if target.type == .longEdge {
                    rightLongEdgeDummies.append(target)
                }
            } while target.type == .longEdge
        }

        func totalDummyCount() -> Int {
            return rightmostLayerId - leftmostLayerId + 1
        }

        func ithDummyNode(_ i: Int) -> LNode {
            if i < leftLongEdgeDummies.count {
                return leftLongEdgeDummies[i]
            } else if i == leftLongEdgeDummies.count {
                return labelDummy
            } else {
                return rightLongEdgeDummies[i - leftLongEdgeDummies.count - 1]
            }
        }
    }
}
