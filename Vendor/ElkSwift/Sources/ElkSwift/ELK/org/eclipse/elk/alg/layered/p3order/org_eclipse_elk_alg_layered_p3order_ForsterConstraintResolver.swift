// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/ForsterConstraintResolver.java
import Foundation

package final class org_eclipse_elk_alg_layered_p3order_ForsterConstraintResolver:
    org_eclipse_elk_alg_layered_p3order_counting_IInitializable
{
    package static let BARYCENTER_EQUALITY_DELTA: Float = 0.0001

    package enum _Keys {
        static let inLayerSuccessorConstraintsBetweenNonDummies =
            "org.eclipse.elk.layered.inLayerSuccessorConstraintsBetweenNonDummies"
        static let inLayerSuccessorConstraints = org_eclipse_elk_alg_layered_options_InternalProperties.IN_LAYER_SUCCESSOR_CONSTRAINTS
        static let inLayerLayoutUnit = org_eclipse_elk_alg_layered_options_InternalProperties.IN_LAYER_LAYOUT_UNIT
    }

    package var constraintsBetweenNonDummies = false
    package var layoutUnits: [ObjectIdentifier: [org_eclipse_elk_alg_layered_graph_LNode]] = [:]
    package var barycenterStates: [[org_eclipse_elk_alg_layered_p3order_BarycenterState?]]
    package var constraintGroups: [[ConstraintGroup?]]

    package init(_ currentNodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]) {
        if let first = currentNodeOrder.first?.first,
           let graph = first.getGraph()
        {
            constraintsBetweenNonDummies =
                graph.getProperty(_Keys.inLayerSuccessorConstraintsBetweenNonDummies) as? Bool ?? false
        }

        barycenterStates = Array(repeating: [], count: currentNodeOrder.count)
        constraintGroups = Array(repeating: [], count: currentNodeOrder.count)
    }

    package func initAtLayerLevel(
        _ l: Int,
        _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]
    ) {
        guard l >= 0, l < nodeOrder.count else { return }
        barycenterStates[l] = Array(repeating: nil, count: nodeOrder[l].count)
        constraintGroups[l] = Array(repeating: nil, count: nodeOrder[l].count)
    }

    package func initAtNodeLevel(
        _ l: Int,
        _ n: Int,
        _ nodeOrder: [[org_eclipse_elk_alg_layered_graph_LNode]]
    ) {
        guard l >= 0, l < nodeOrder.count, n >= 0, n < nodeOrder[l].count else { return }
        initAtNodeLevel(nodeOrder[l][n], true)
    }

    package func getBarycenterStates() -> [[org_eclipse_elk_alg_layered_p3order_BarycenterState?]] {
        barycenterStates
    }

    package func processConstraints(_ nodes: inout [org_eclipse_elk_alg_layered_graph_LNode]) {
        if constraintsBetweenNonDummies {
            processConstraints(&nodes, true)
            for node in nodes {
                initAtNodeLevel(node, false)
            }
        }

        processConstraints(&nodes, false)
    }

    package func initAtNodeLevel(_ node: org_eclipse_elk_alg_layered_graph_LNode, _ fullInit: Bool) {
        guard let layer = node.getLayer() else { return }
        let layerIndex = layer.id
        let nodeIndex = node.id
        guard layerIndex >= 0,
              layerIndex < constraintGroups.count,
              nodeIndex >= 0,
              nodeIndex < constraintGroups[layerIndex].count
        else {
            return
        }

        constraintGroups[layerIndex][nodeIndex] = ConstraintGroup(node, resolver: self)

        if fullInit {
            barycenterStates[layerIndex][nodeIndex] = org_eclipse_elk_alg_layered_p3order_BarycenterState(node)

            if let layoutUnit = node.getProperty(_Keys.inLayerLayoutUnit) as? org_eclipse_elk_alg_layered_graph_LNode {
                let key = ObjectIdentifier(layoutUnit)
                layoutUnits[key, default: []].append(node)
            }
        }
    }

    package func processConstraints(
        _ nodes: inout [org_eclipse_elk_alg_layered_graph_LNode],
        _ onlyBetweenNormalNodes: Bool
    ) {
        var groups: [ConstraintGroup] = nodes.compactMap(groupOf)

        buildConstraintsGraph(groups, onlyBetweenNormalNodes)

        while let violated = findViolatedConstraint(groups) {
            if let first = violated.getFirst(),
               let second = violated.getSecond()
            {
                handleViolatedConstraint(first, second, &groups)
            } else {
                break
            }
        }

        var resolved: [org_eclipse_elk_alg_layered_graph_LNode] = []
        resolved.reserveCapacity(nodes.count)
        for group in groups {
            for node in group.getNodes() {
                resolved.append(node)
                stateOf(node)?.barycenter = group.getBarycenter()
            }
        }
        nodes = resolved
    }

    package func buildConstraintsGraph(_ groups: [ConstraintGroup], _ onlyBetweenNormalNodes: Bool) {
        for group in groups {
            group.resetOutgoingConstraints()
            group.incomingConstraintsCount = 0
        }

        var lastNonDummyNode: org_eclipse_elk_alg_layered_graph_LNode?

        for group in groups {
            guard let node = group.getNode() else { continue }

            if onlyBetweenNormalNodes && node.getType() != .NORMAL {
                continue
            }

            let successors = node.getProperty(_Keys.inLayerSuccessorConstraints)
                as? [org_eclipse_elk_alg_layered_graph_LNode] ?? []
            for successor in successors {
                if !onlyBetweenNormalNodes || successor.getType() == .NORMAL {
                    guard let successorGroup = groupOf(successor) else { continue }
                    group.addOutgoingConstraint(successorGroup)
                    successorGroup.incomingConstraintsCount += 1
                }
            }

            if !onlyBetweenNormalNodes && node.getType() == .NORMAL {
                if let lastNonDummyNode {
                    for lastUnitNode in layoutUnitNodes(for: lastNonDummyNode) {
                        for currentUnitNode in layoutUnitNodes(for: node) {
                            guard let lastGroup = groupOf(lastUnitNode),
                                  let currentGroup = groupOf(currentUnitNode)
                            else {
                                continue
                            }
                            lastGroup.addOutgoingConstraint(currentGroup)
                            currentGroup.incomingConstraintsCount += 1
                        }
                    }
                }

                lastNonDummyNode = node
            }
        }
    }

    package func findViolatedConstraint(
        _ groups: [ConstraintGroup]
    ) -> org_eclipse_elk_core_util_Pair<ConstraintGroup, ConstraintGroup>? {
        var activeGroups = ArrayDeque<ConstraintGroup>()

        var lastValue = Double(Int16.min)
        for group in groups {
            if let barycenter = group.getBarycenter() {
                assert(barycenter >= lastValue)
                lastValue = barycenter
            }
            group.resetIncomingConstraints()

            if group.hasOutgoingConstraints() && group.incomingConstraintsCount == 0 {
                activeGroups.append(group)
            }
        }

        while !activeGroups.isEmpty {
            let group = activeGroups.removeFirst()

            if group.hasIncomingConstraints() {
                for predecessor in group.getIncomingConstraints() {
                    let predecessorBarycenter = predecessor.getBarycenter()
                    let groupBarycenter = group.getBarycenter()

                    if Float(predecessorBarycenter ?? .nan) == Float(groupBarycenter ?? .nan) {
                        if indexOf(groups, predecessor) > indexOf(groups, group) {
                            return org_eclipse_elk_core_util_Pair<ConstraintGroup, ConstraintGroup>.of(predecessor, group)
                        }
                    } else if (predecessorBarycenter ?? -.infinity) > (groupBarycenter ?? .infinity) {
                        return org_eclipse_elk_core_util_Pair<ConstraintGroup, ConstraintGroup>.of(predecessor, group)
                    }
                }
            }

            for successor in group.getOutgoingConstraints() {
                successor.prependIncomingConstraint(group)
                if successor.incomingConstraintsCount == successor.getIncomingConstraints().count {
                    activeGroups.append(successor)
                }
            }
        }

        return nil
    }

    package func handleViolatedConstraint(
        _ firstNodeGroup: ConstraintGroup,
        _ secondNodeGroup: ConstraintGroup,
        _ nodeGroups: inout [ConstraintGroup]
    ) {
        let newNodeGroup = ConstraintGroup(firstNodeGroup, secondNodeGroup, resolver: self)

        if let secondBarycenter = secondNodeGroup.getBarycenter(),
           let newBarycenter = newNodeGroup.getBarycenter()
        {
            assert(newBarycenter + Double(Self.BARYCENTER_EQUALITY_DELTA) >= secondBarycenter)
        }

        if let firstBarycenter = firstNodeGroup.getBarycenter(),
           let newBarycenter = newNodeGroup.getBarycenter()
        {
            assert(newBarycenter - Double(Self.BARYCENTER_EQUALITY_DELTA) <= firstBarycenter)
        }

        var i = 0
        var alreadyInserted = false
        while i < nodeGroups.count {
            let nodeGroup = nodeGroups[i]

            if nodeGroup === firstNodeGroup || nodeGroup === secondNodeGroup {
                nodeGroups.remove(at: i)
                continue
            }

            if !alreadyInserted,
               let currentBarycenter = nodeGroup.getBarycenter(),
               let newBarycenter = newNodeGroup.getBarycenter(),
               currentBarycenter > newBarycenter
            {
                nodeGroups.insert(newNodeGroup, at: i)
                alreadyInserted = true
                i += 1
                continue
            }

            if nodeGroup.hasOutgoingConstraints() {
                let firstRemoved = nodeGroup.removeOutgoingConstraint(firstNodeGroup)
                let secondRemoved = nodeGroup.removeOutgoingConstraint(secondNodeGroup)

                if firstRemoved || secondRemoved {
                    nodeGroup.addOutgoingConstraint(newNodeGroup)
                    newNodeGroup.incomingConstraintsCount += 1
                }
            }

            i += 1
        }

        if !alreadyInserted {
            nodeGroups.append(newNodeGroup)
        }
    }

    package func layoutUnitNodes(
        for node: org_eclipse_elk_alg_layered_graph_LNode
    ) -> [org_eclipse_elk_alg_layered_graph_LNode] {
        if let own = layoutUnits[ObjectIdentifier(node)], !own.isEmpty {
            return own
        }
        return [node]
    }

    package func indexOf(_ groups: [ConstraintGroup], _ target: ConstraintGroup) -> Int {
        groups.firstIndex(where: { $0 === target }) ?? -1
    }

    package func groupOf(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> ConstraintGroup? {
        guard let layerIndex = node.getLayer()?.id,
              layerIndex >= 0,
              layerIndex < constraintGroups.count,
              node.id >= 0,
              node.id < constraintGroups[layerIndex].count
        else {
            return nil
        }
        return constraintGroups[layerIndex][node.id]
    }

    package func stateOf(
        _ node: org_eclipse_elk_alg_layered_graph_LNode
    ) -> org_eclipse_elk_alg_layered_p3order_BarycenterState? {
        guard let layerIndex = node.getLayer()?.id,
              layerIndex >= 0,
              layerIndex < barycenterStates.count,
              node.id >= 0,
              node.id < barycenterStates[layerIndex].count
        else {
            return nil
        }
        return barycenterStates[layerIndex][node.id]
    }

    package final class ConstraintGroup: Hashable, CustomStringConvertible {
        package unowned let resolver: org_eclipse_elk_alg_layered_p3order_ForsterConstraintResolver

        package var summedWeight: Double = 0
        package var degree: Int = 0
        package let nodes: [org_eclipse_elk_alg_layered_graph_LNode]
        package var outgoingConstraints: [ConstraintGroup]?
        package var incomingConstraints: [ConstraintGroup]?
        package var incomingConstraintsCount: Int = 0

        fileprivate init(
            _ node: org_eclipse_elk_alg_layered_graph_LNode,
            resolver: org_eclipse_elk_alg_layered_p3order_ForsterConstraintResolver
        ) {
            self.nodes = [node]
            self.resolver = resolver
            if let state = resolver.stateOf(node) {
                summedWeight = state.summedWeight
                degree = state.degree
            }
        }

        fileprivate init(
            _ nodeGroup1: ConstraintGroup,
            _ nodeGroup2: ConstraintGroup,
            resolver: org_eclipse_elk_alg_layered_p3order_ForsterConstraintResolver
        ) {
            self.nodes = nodeGroup1.nodes + nodeGroup2.nodes
            self.resolver = resolver

            if let out1 = nodeGroup1.outgoingConstraints {
                var merged = out1.filter { $0 !== nodeGroup2 }
                if let out2 = nodeGroup2.outgoingConstraints {
                    for candidate in out2 {
                        if candidate === nodeGroup1 {
                            continue
                        }
                        if merged.contains(where: { $0 === candidate }) {
                            candidate.incomingConstraintsCount -= 1
                        } else {
                            merged.append(candidate)
                        }
                    }
                }
                outgoingConstraints = merged
            } else if let out2 = nodeGroup2.outgoingConstraints {
                outgoingConstraints = out2.filter { $0 !== nodeGroup1 }
            }

            summedWeight = nodeGroup1.summedWeight + nodeGroup2.summedWeight
            degree = nodeGroup1.degree + nodeGroup2.degree

            if degree > 0 {
                setBarycenter(summedWeight / Double(degree))
            } else if let b1 = nodeGroup1.getBarycenter(), let b2 = nodeGroup2.getBarycenter() {
                setBarycenter((b1 + b2) / 2)
            } else if let b1 = nodeGroup1.getBarycenter() {
                setBarycenter(b1)
            } else if let b2 = nodeGroup2.getBarycenter() {
                setBarycenter(b2)
            }
        }

        package func setBarycenter(_ barycenter: Double?) {
            for node in nodes {
                resolver.stateOf(node)?.barycenter = barycenter
            }
        }

        package func getBarycenter() -> Double? {
            guard let first = nodes.first else { return nil }
            return resolver.stateOf(first)?.barycenter
        }

        package func getOutgoingConstraints() -> [ConstraintGroup] {
            if outgoingConstraints == nil {
                outgoingConstraints = []
            }
            return outgoingConstraints ?? []
        }

        package func setOutgoingConstraints(_ constraints: [ConstraintGroup]?) {
            outgoingConstraints = constraints
        }

        package func addOutgoingConstraint(_ constraint: ConstraintGroup) {
            if outgoingConstraints == nil {
                outgoingConstraints = []
            }
            outgoingConstraints?.append(constraint)
        }

        package func resetOutgoingConstraints() {
            outgoingConstraints = nil
        }

        package func hasOutgoingConstraints() -> Bool {
            !(outgoingConstraints ?? []).isEmpty
        }

        package func getIncomingConstraints() -> [ConstraintGroup] {
            if incomingConstraints == nil {
                incomingConstraints = []
            }
            return incomingConstraints ?? []
        }

        package func setIncomingConstraints(_ constraints: [ConstraintGroup]?) {
            incomingConstraints = constraints
        }

        package func prependIncomingConstraint(_ constraint: ConstraintGroup) {
            if incomingConstraints == nil {
                incomingConstraints = []
            }
            incomingConstraints?.insert(constraint, at: 0)
        }

        package func resetIncomingConstraints() {
            incomingConstraints = nil
        }

        package func hasIncomingConstraints() -> Bool {
            !(incomingConstraints ?? []).isEmpty
        }

        package func getNodes() -> [org_eclipse_elk_alg_layered_graph_LNode] {
            nodes
        }

        package func getNode() -> org_eclipse_elk_alg_layered_graph_LNode? {
            guard nodes.count == 1 else { return nil }
            return nodes[0]
        }

        package func removeOutgoingConstraint(_ group: ConstraintGroup) -> Bool {
            guard var outgoingConstraints else { return false }
            let before = outgoingConstraints.count
            outgoingConstraints.removeAll(where: { $0 === group })
            self.outgoingConstraints = outgoingConstraints
            return outgoingConstraints.count != before
        }

        package static func == (lhs: ConstraintGroup, rhs: ConstraintGroup) -> Bool {
            lhs === rhs
        }

        package func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(self))
        }

        package var description: String {
            let content = nodes.map {
                if let b = getBarycenter() {
                    return "\($0)<\(b)>"
                }
                return "\($0)"
            }.joined(separator: ", ")
            return "[\(content)]"
        }
    }
}

/// Temporary stand-in for Java's `BarycenterHeuristic.BarycenterState` until the full
/// `BarycenterHeuristic` runtime is ported into V2.
package final class org_eclipse_elk_alg_layered_p3order_BarycenterState: CustomStringConvertible {
    package var node: org_eclipse_elk_alg_layered_graph_LNode
    package var barycenter: Double?
    package var summedWeight: Double
    package var degree: Int
    package var visited: Bool

    package init(_ node: org_eclipse_elk_alg_layered_graph_LNode) {
        self.node = node
        barycenter = nil
        summedWeight = 0
        degree = 0
        visited = false
    }

    package var description: String {
        "BarycenterState [node=\(node), summedWeight=\(summedWeight), degree=\(degree), barycenter=\(String(describing: barycenter)), visited=\(visited)]"
    }
}
