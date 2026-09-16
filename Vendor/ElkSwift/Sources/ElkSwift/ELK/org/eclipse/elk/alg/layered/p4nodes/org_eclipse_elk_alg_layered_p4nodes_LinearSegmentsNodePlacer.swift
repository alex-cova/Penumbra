// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p4nodes/LinearSegmentsNodePlacer.java
import Foundation

package final class org_eclipse_elk_alg_layered_p4nodes_LinearSegmentsNodePlacer {
    /// A linear segment contains a single regular node or all dummy nodes of a long edge.
    package final class LinearSegment: Comparable, Hashable, CustomStringConvertible {
        /// Nodes of the linear segment.
        package var nodes: [org_eclipse_elk_alg_layered_graph_LNode] = []

        /// Identifier value, used as index in the segments array.
        package var id: Int = -1

        /// Index in the previous layer. Used for cycle avoidance.
        package var indexInLastLayer: Int = -1

        /// The last layer where a node belonging to this segment was discovered. Used for cycle avoidance.
        package var lastLayer: Int = -1

        /// The accumulated force of the contained nodes.
        package var deflection: Double = 0.0

        /// The current weight of the contained nodes.
        package var weight: Int = 0

        /// The reference segment, if this has been unified with another.
        package weak var refSegment: LinearSegment?

        /// The nodetype contained in this linear segment.
        package var nodeType: org_eclipse_elk_alg_layered_graph_NodeType = .NORMAL

        package init() {}

        /// Determine the reference segment for the region to which this segment is associated.
        package func region() -> LinearSegment {
            var seg: LinearSegment = self
            while let parent = seg.refSegment {
                seg = parent
            }
            return seg
        }

        /// Splits this linear segment before the given node.
        @discardableResult
        package func split(
            _ node: org_eclipse_elk_alg_layered_graph_LNode,
            _ newId: Int
        ) -> LinearSegment {
            guard let nodeIndex = nodes.firstIndex(where: { $0 === node }) else {
                let newSegment = LinearSegment()
                newSegment.id = newId
                return newSegment
            }

            let newSegment = LinearSegment()
            newSegment.id = newId
            if nodeIndex < nodes.count {
                let moved = Array(nodes[nodeIndex...])
                for movedNode in moved {
                    movedNode.id = newId
                    newSegment.nodes.append(movedNode)
                }
                nodes.removeSubrange(nodeIndex...)
            }
            return newSegment
        }

        package var description: String {
            "ls\(nodes)"
        }

        package static func < (lhs: LinearSegment, rhs: LinearSegment) -> Bool {
            lhs.id < rhs.id
        }

        package static func == (lhs: LinearSegment, rhs: LinearSegment) -> Bool {
            lhs.id == rhs.id
        }

        package func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    package enum Mode {
        case FORW_PENDULUM
        case BACKW_PENDULUM
        case RUBBER
    }

    package enum _Keys {
        static let spacings = "spacings"
        static let spacingEdgeEdge = "org.eclipse.elk.spacing.edgeEdge"
        static let spacingNodeNode = "org.eclipse.elk.spacing.nodeNode"
        static let thoroughness = "org.eclipse.elk.layered.thoroughness"
        static let deflectionDampening =
            "org.eclipse.elk.layered.nodePlacement.linearSegments.deflectionDampening"
    }

    /// Additional processor dependencies for graphs with hierarchical ports.
    package static let HIERARCHY_PROCESSING_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> = {
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(
                org_eclipse_elk_alg_layered_LayeredPhases.P5_EDGE_ROUTING,
                org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy.HIERARCHICAL_PORT_POSITION_PROCESSOR
            )
    }()

    /// Property for maximal priority of incoming edges.
    package static let INPUT_PRIO = "linearSegments.inputPrio"

    /// Property for maximal priority of outgoing edges.
    package static let OUTPUT_PRIO = "linearSegments.outputPrio"

    package static let THRESHOLD_FACTOR: Double = 20.0
    package static let PENDULUM_ITERS: Int = 4
    package static let FINAL_ITERS: Int = 3
    package static let OVERLAP_DETECT: Double = 0.0001

    /// Array of sorted linear segments.
    package var linearSegments: [LinearSegment] = []

    /// Spacing values.
    package var spacings: org_eclipse_elk_alg_layered_options_Spacings?

    package init() {}

    package func getLayoutProcessorConfiguration(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph
    ) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        let graphProperties = graph.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.GRAPH_PROPERTIES)
            as? Set<org_eclipse_elk_alg_layered_options_GraphProperties> ?? []
        if graphProperties.contains(.EXTERNAL_PORTS) {
            return Self.HIERARCHY_PROCESSING_ADDITIONS
        }
        return nil
    }

    package func process(
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) {
        monitor.begin("Linear segments node placement", 1)

        spacings = layeredGraph.getProperty(_Keys.spacings) as? org_eclipse_elk_alg_layered_options_Spacings

        linearSegments = sortLinearSegments(layeredGraph, monitor)
        createUnbalancedPlacement(layeredGraph)
        balancePlacement(layeredGraph)
        postProcess(layeredGraph)

        linearSegments = []
        spacings = nil
        monitor.done()
    }

    /// Sorts the linear segments by finding a topological ordering in the segment ordering graph.
    @discardableResult
    package func sortLinearSegments(
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor
    ) -> [LinearSegment] {
        var segmentList: [LinearSegment] = []

        // Initialize ids and in/out priorities on all nodes.
        for layer in layeredGraph {
            for node in layer {
                node.id = -1

                var inPrio = Int.min
                var outPrio = Int.min
                for port in node.getPorts() {
                    for edge in port.getIncomingEdges() {
                        let prio = edge.getProperty(org_eclipse_elk_alg_layered_options_LayeredOptions.PRIORITY_STRAIGHTNESS) as? Int ?? 0
                        inPrio = max(inPrio, prio)
                    }
                    for edge in port.getOutgoingEdges() {
                        let prio = edge.getProperty(org_eclipse_elk_alg_layered_options_LayeredOptions.PRIORITY_STRAIGHTNESS) as? Int ?? 0
                        outPrio = max(outPrio, prio)
                    }
                }
                node.setProperty(Self.INPUT_PRIO, inPrio)
                node.setProperty(Self.OUTPUT_PRIO, outPrio)
            }
        }

        var nextLinearSegmentID = 0
        for layer in layeredGraph {
            for node in layer {
                if node.id < 0 {
                    let segment = LinearSegment()
                    segment.id = nextLinearSegmentID
                    nextLinearSegmentID += 1
                    _ = fillSegment(node, segment)
                    segmentList.append(segment)
                }
            }
        }

        var outgoingList: [[LinearSegment]] = Array(repeating: [], count: segmentList.count)
        var incomingCountList: [Int] = Array(repeating: 0, count: segmentList.count)

        createDependencyGraphEdges(monitor, layeredGraph, &segmentList, &outgoingList, &incomingCountList)

        // Stable Kahn topological ordering.
        var queue: [LinearSegment] = []
        queue.reserveCapacity(segmentList.count)
        for segment in segmentList where segment.id >= 0 && segment.id < incomingCountList.count {
            if incomingCountList[segment.id] == 0 {
                queue.append(segment)
            }
        }
        queue.sort()

        var sortedSegments: [LinearSegment] = []
        sortedSegments.reserveCapacity(segmentList.count)

        while !queue.isEmpty {
            let segment = queue.removeFirst()
            sortedSegments.append(segment)

            let out = segment.id >= 0 && segment.id < outgoingList.count ? outgoingList[segment.id] : []
            for target in out {
                guard target.id >= 0 && target.id < incomingCountList.count else {
                    continue
                }
                incomingCountList[target.id] -= 1
                if incomingCountList[target.id] == 0 {
                    queue.append(target)
                }
            }
            queue.sort()
        }

        // Keep leftovers in deterministic order if any remain.
        if sortedSegments.count < segmentList.count {
            let seen = Set(sortedSegments.map(\.id))
            let leftovers = segmentList.filter { !seen.contains($0.id) }.sorted()
            sortedSegments.append(contentsOf: leftovers)
        }

        // Apply new ranking as segment/node ids, matching Java post-topological rewrite.
        for (rank, segment) in sortedSegments.enumerated() {
            segment.id = rank
            for node in segment.nodes {
                node.id = rank
            }
        }

        return sortedSegments
    }

    package func createDependencyGraphEdges(
        _ monitor: any org_eclipse_elk_core_util_IElkProgressMonitor,
        _ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ segmentList: inout [LinearSegment],
        _ outgoingList: inout [[LinearSegment]],
        _ incomingCountList: inout [Int]
    ) {
        _ = monitor

        var nextLinearSegmentID = segmentList.count
        var layerIndex = 0

        for layer in layeredGraph {
            let nodes = layer.getNodes()
            if nodes.isEmpty {
                continue
            }

            var indexInLayer = 0
            var previousNode: org_eclipse_elk_alg_layered_graph_LNode?
            var currentNode: org_eclipse_elk_alg_layered_graph_LNode? = nodes.first

            while let current = currentNode {
                var currentSegment = segmentList[current.id]

                if currentSegment.indexInLastLayer >= 0 {
                    var cycleSegment: LinearSegment?

                    if indexInLayer + 1 < nodes.count {
                        for candidateNode in nodes[(indexInLayer + 1)...] {
                            let candidateSegment = segmentList[candidateNode.id]
                            if candidateSegment.lastLayer == currentSegment.lastLayer,
                               candidateSegment.indexInLastLayer < currentSegment.indexInLastLayer
                            {
                                cycleSegment = candidateSegment
                                break
                            }
                        }
                    }

                    if cycleSegment != nil {
                        if let previous = previousNode {
                            incomingCountList[current.id] -= 1
                            if let removeIndex = outgoingList[previous.id].firstIndex(of: currentSegment) {
                                outgoingList[previous.id].remove(at: removeIndex)
                            }
                        }

                        currentSegment = currentSegment.split(current, nextLinearSegmentID)
                        nextLinearSegmentID += 1
                        segmentList.append(currentSegment)
                        outgoingList.append([])

                        if let previous = previousNode {
                            outgoingList[previous.id].append(currentSegment)
                            incomingCountList.append(1)
                        } else {
                            incomingCountList.append(0)
                        }
                    }
                }

                var nextNode: org_eclipse_elk_alg_layered_graph_LNode?
                if indexInLayer + 1 < nodes.count {
                    nextNode = nodes[indexInLayer + 1]
                    if let nextNode {
                        let nextSegment = segmentList[nextNode.id]
                        outgoingList[current.id].append(nextSegment)
                        incomingCountList[nextNode.id] += 1
                    }
                }

                currentSegment.lastLayer = layerIndex
                currentSegment.indexInLastLayer = indexInLayer

                previousNode = current
                currentNode = nextNode
                indexInLayer += 1
            }

            layerIndex += 1
        }
    }

    /// Creates a linear segment for one regular node or one long-edge dummy chain.
    @discardableResult
    package func fillSegment(
        _ node: org_eclipse_elk_alg_layered_graph_LNode,
        _ segment: LinearSegment
    ) -> Bool {
        let nodeType = node.getType()

        if node.id >= 0 {
            return false
        }

        node.id = segment.id
        segment.nodes.append(node)
        segment.nodeType = nodeType

        if nodeType == .LONG_EDGE || nodeType == .NORTH_SOUTH_PORT {
            for sourcePort in node.getPorts() {
                for targetPort in sourcePort.getSuccessorPorts() {
                    guard let targetNode = targetPort.getNode() else {
                        continue
                    }
                    let targetNodeType = targetNode.getType()

                    if node.getLayer() !== targetNode.getLayer(),
                       targetNodeType == .LONG_EDGE || targetNodeType == .NORTH_SOUTH_PORT
                    {
                        if fillSegment(targetNode, segment) {
                            return true
                        }
                    }
                }
            }
        }

        return true
    }

    package func createUnbalancedPlacement(_ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph) {
        let layerCount = layeredGraph.getLayers().count
        var nodeCount = Array(repeating: 0, count: layerCount)
        var recentNode: [org_eclipse_elk_alg_layered_graph_LNode?] = Array(repeating: nil, count: layerCount)

        for segment in linearSegments {
            var uppermostPlace = 0.0
            for node in segment.nodes {
                guard let layer = node.getLayer() else { continue }
                let layerIndex = layer.getIndex()
                guard layerIndex >= 0, layerIndex < layerCount else { continue }

                nodeCount[layerIndex] += 1

                var spacing = doubleProperty(layeredGraph, _Keys.spacingEdgeEdge, 0.0)
                if nodeCount[layerIndex] > 0, let prev = recentNode[layerIndex] {
                    spacing = verticalSpacing(prev, node)
                }

                uppermostPlace = max(uppermostPlace, layer.getSize().y + spacing)
            }

            for node in segment.nodes {
                guard let layer = node.getLayer() else { continue }
                let layerIndex = layer.getIndex()
                guard layerIndex >= 0, layerIndex < layerCount else { continue }

                node.getPosition().y = uppermostPlace + node.getMargin().top
                layer.getSize().y = uppermostPlace + node.getMargin().top + node.getSize().y + node.getMargin().bottom
                recentNode[layerIndex] = node
            }
        }
    }

    package func balancePlacement(_ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph) {
        let deflectionDampening = doubleProperty(layeredGraph, _Keys.deflectionDampening, 1.0)
        let thoroughness = max(1, intProperty(layeredGraph, _Keys.thoroughness, 1))

        var pendulumIters = Self.PENDULUM_ITERS
        var finalIters = Self.FINAL_ITERS
        let threshold = Self.THRESHOLD_FACTOR / Double(thoroughness)

        var ready = false
        var mode = Mode.FORW_PENDULUM
        var lastTotalDeflection = Double.greatestFiniteMagnitude

        repeat {
            let incoming = mode != .BACKW_PENDULUM
            let outgoing = mode != .FORW_PENDULUM

            var totalDeflection = 0.0
            for segment in linearSegments {
                segment.refSegment = nil
                calcDeflection(segment, incoming, outgoing, deflectionDampening)
                totalDeflection += abs(segment.deflection)
            }

            while mergeRegions(layeredGraph) {
                // Keep merging as long as overlapping regions are found.
            }

            for segment in linearSegments {
                let deflection = segment.region().deflection
                if deflection != 0.0 {
                    for node in segment.nodes {
                        node.getPosition().y += deflection
                    }
                }
            }

            if mode == .FORW_PENDULUM || mode == .BACKW_PENDULUM {
                pendulumIters -= 1
                if pendulumIters <= 0 && (totalDeflection < lastTotalDeflection
                    || -pendulumIters > thoroughness)
                {
                    mode = .RUBBER
                    lastTotalDeflection = Double.greatestFiniteMagnitude
                } else if mode == .FORW_PENDULUM {
                    mode = .BACKW_PENDULUM
                    lastTotalDeflection = totalDeflection
                } else {
                    mode = .FORW_PENDULUM
                    lastTotalDeflection = totalDeflection
                }
            } else {
                ready = totalDeflection >= lastTotalDeflection
                    || (lastTotalDeflection - totalDeflection) < threshold
                lastTotalDeflection = totalDeflection
                if ready {
                    finalIters -= 1
                }
            }
        } while !(ready && finalIters <= 0)
    }

    package func calcDeflection(
        _ segment: LinearSegment,
        _ incoming: Bool,
        _ outgoing: Bool,
        _ deflectionDampening: Double
    ) {
        var segmentDeflection = 0.0
        var nodeWeightSum = 0

        for node in segment.nodes {
            var nodeDeflection = 0.0
            var edgeWeightSum = 0

            let inputPrio = incoming ? (node.getProperty(Self.INPUT_PRIO) as? Int ?? Int.min) : Int.min
            let outputPrio = outgoing ? (node.getProperty(Self.OUTPUT_PRIO) as? Int ?? Int.min) : Int.min
            let minPrio = max(inputPrio, outputPrio)

            for port in node.getPorts() {
                let portPos = node.getPosition().y + port.getPosition().y + port.getAnchor().y

                if outgoing {
                    for edge in port.getOutgoingEdges() {
                        guard let otherPort = edge.getTarget(),
                              let otherNode = otherPort.getNode(),
                              let otherSegment = segmentForNode(otherNode)
                        else {
                            continue
                        }
                        if segment === otherSegment {
                            continue
                        }

                        let otherPrio = max(
                            otherNode.getProperty(Self.INPUT_PRIO) as? Int ?? Int.min,
                            otherNode.getProperty(Self.OUTPUT_PRIO) as? Int ?? Int.min
                        )
                        let prio = edge.getProperty(
                            org_eclipse_elk_alg_layered_options_LayeredOptions.PRIORITY_STRAIGHTNESS
                        ) as? Int ?? 0

                        if prio >= minPrio && prio >= otherPrio {
                            nodeDeflection += otherNode.getPosition().y + otherPort.getPosition().y
                                + otherPort.getAnchor().y - portPos
                            edgeWeightSum += 1
                        }
                    }
                }

                if incoming {
                    for edge in port.getIncomingEdges() {
                        guard let otherPort = edge.getSource(),
                              let otherNode = otherPort.getNode(),
                              let otherSegment = segmentForNode(otherNode)
                        else {
                            continue
                        }
                        if segment === otherSegment {
                            continue
                        }

                        let otherPrio = max(
                            otherNode.getProperty(Self.INPUT_PRIO) as? Int ?? Int.min,
                            otherNode.getProperty(Self.OUTPUT_PRIO) as? Int ?? Int.min
                        )
                        let prio = edge.getProperty(
                            org_eclipse_elk_alg_layered_options_LayeredOptions.PRIORITY_STRAIGHTNESS
                        ) as? Int ?? 0

                        if prio >= minPrio && prio >= otherPrio {
                            nodeDeflection += otherNode.getPosition().y + otherPort.getPosition().y
                                + otherPort.getAnchor().y - portPos
                            edgeWeightSum += 1
                        }
                    }
                }
            }

            if edgeWeightSum > 0 {
                segmentDeflection += nodeDeflection / Double(edgeWeightSum)
                nodeWeightSum += 1
            }
        }

        if nodeWeightSum > 0 {
            segment.deflection = deflectionDampening * segmentDeflection / Double(nodeWeightSum)
            segment.weight = nodeWeightSum
        } else {
            segment.deflection = 0
            segment.weight = 0
        }
    }

    @discardableResult
    package func mergeRegions(_ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph) -> Bool {
        var changed = false
        let nodeSpacing = doubleProperty(layeredGraph, _Keys.spacingNodeNode, 0.0)
        let threshold = Self.OVERLAP_DETECT * nodeSpacing

        for layer in layeredGraph {
            let nodes = layer.getNodes()
            if nodes.isEmpty {
                continue
            }

            var node1 = nodes[0]
            guard let seg1 = segmentForNode(node1) else { continue }
            var region1 = seg1.region()

            if nodes.count > 1 {
                for idx in 1..<nodes.count {
                    let node2 = nodes[idx]
                    guard let seg2 = segmentForNode(node2) else {
                        node1 = node2
                        continue
                    }
                    let region2 = seg2.region()

                    if region1 !== region2 {
                        let spacing = verticalSpacing(node1, node2)

                        let node1Extent = node1.getPosition().y + node1.getSize().y + node1.getMargin().bottom
                            + region1.deflection + spacing
                        let node2Extent = node2.getPosition().y - node2.getMargin().top + region2.deflection

                        if node1Extent > node2Extent + threshold {
                            let weightSum = region1.weight + region2.weight
                            if weightSum > 0 {
                                region2.deflection = (
                                    Double(region2.weight) * region2.deflection
                                        + Double(region1.weight) * region1.deflection
                                ) / Double(weightSum)
                            }
                            region2.weight = weightSum
                            region1.refSegment = region2
                            changed = true
                        }
                    }

                    node1 = node2
                    region1 = region2
                }
            }
        }

        return changed
    }

    package func postProcess(_ layeredGraph: org_eclipse_elk_alg_layered_graph_LGraph) {
        _ = layeredGraph

        for segment in linearSegments {
            var minRoomAbove = Double.greatestFiniteMagnitude
            var minRoomBelow = Double.greatestFiniteMagnitude

            for node in segment.nodes {
                let index = node.getIndex()
                guard let layer = node.getLayer() else { continue }

                let roomAbove: Double
                if index > 0 {
                    let neighbor = layer.getNodes()[index - 1]
                    let spacing = verticalSpacing(node, neighbor)
                    roomAbove = node.getPosition().y - node.getMargin().top
                        - (neighbor.getPosition().y + neighbor.getSize().y + neighbor.getMargin().bottom + spacing)
                } else {
                    roomAbove = node.getPosition().y - node.getMargin().top
                }
                minRoomAbove = min(roomAbove, minRoomAbove)

                let roomBelow: Double
                if index < layer.getNodes().count - 1 {
                    let neighbor = layer.getNodes()[index + 1]
                    let spacing = verticalSpacing(node, neighbor)
                    roomBelow = neighbor.getPosition().y - neighbor.getMargin().top
                        - (node.getPosition().y + node.getSize().y + node.getMargin().bottom + spacing)
                } else {
                    roomBelow = 2 * node.getPosition().y
                }
                minRoomBelow = min(roomBelow, minRoomBelow)
            }

            var minDisplacement = Double.greatestFiniteMagnitude
            var foundPlace = false

            if let firstNode = segment.nodes.first {
                for target in firstNode.getPorts() {
                    let pos = firstNode.getPosition().y + target.getPosition().y + target.getAnchor().y
                    for edge in target.getIncomingEdges() {
                        guard let source = edge.getSource(),
                              let sourceNode = source.getNode()
                        else {
                            continue
                        }
                        let d = sourceNode.getPosition().y + source.getPosition().y + source.getAnchor().y - pos
                        if abs(d) < abs(minDisplacement)
                            && abs(d) < (d < 0 ? minRoomAbove : minRoomBelow)
                        {
                            minDisplacement = d
                            foundPlace = true
                        }
                    }
                }
            }

            if let lastNode = segment.nodes.last {
                for source in lastNode.getPorts() {
                    let pos = lastNode.getPosition().y + source.getPosition().y + source.getAnchor().y
                    for edge in source.getOutgoingEdges() {
                        guard let target = edge.getTarget(),
                              let targetNode = target.getNode()
                        else {
                            continue
                        }
                        let d = targetNode.getPosition().y + target.getPosition().y + target.getAnchor().y - pos
                        if abs(d) < abs(minDisplacement)
                            && abs(d) < (d < 0 ? minRoomAbove : minRoomBelow)
                        {
                            minDisplacement = d
                            foundPlace = true
                        }
                    }
                }
            }

            if foundPlace, minDisplacement != 0 {
                for node in segment.nodes {
                    node.getPosition().y += minDisplacement
                }
            }
        }
    }

    package func segmentForNode(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> LinearSegment? {
        guard node.id >= 0, node.id < linearSegments.count else {
            return nil
        }
        return linearSegments[node.id]
    }

    package func verticalSpacing(
        _ upper: org_eclipse_elk_alg_layered_graph_LNode,
        _ lower: org_eclipse_elk_alg_layered_graph_LNode
    ) -> Double {
        spacings?.getVerticalSpacing(upper, lower) ?? 0.0
    }

    package func intProperty(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ key: String,
        _ defaultValue: Int
    ) -> Int {
        graph.getProperty(key) as? Int ?? defaultValue
    }

    package func doubleProperty(
        _ graph: org_eclipse_elk_alg_layered_graph_LGraph,
        _ key: String,
        _ defaultValue: Double
    ) -> Double {
        graph.getProperty(key) as? Double ?? defaultValue
    }
}
