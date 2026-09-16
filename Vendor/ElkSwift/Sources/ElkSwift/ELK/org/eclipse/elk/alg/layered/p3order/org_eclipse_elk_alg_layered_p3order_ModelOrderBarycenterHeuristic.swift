// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/p3order/ModelOrderBarycenterHeuristic.java
import Foundation

/// Minimizes crossings with the barycenter method while preserving model order among real nodes.
/// Only dummy nodes are sorted between the already-sorted real nodes.
///
/// **MUST extend BarycenterHeuristic** (matching Java) to inherit:
/// - Port-position-based `calculateBarycenters` (NOT model-order-based)
/// - Neighbor-interpolation-based `fillInUnknownBarycenters`
/// - `constraintResolver`, `portDistributor`, `barycenterState`, etc.
package class org_eclipse_elk_alg_layered_p3order_ModelOrderBarycenterHeuristic:
    org_eclipse_elk_alg_layered_p3order_BarycenterHeuristic
{
    /// Each node has an entry of nodes for which it is bigger.
    package var biggerThan: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]
    /// Each node has an entry of nodes for which it is smaller.
    package var smallerThan: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]

    package override init(
        _ constraintResolver: org_eclipse_elk_alg_layered_p3order_ForsterConstraintResolver,
        _ random: Any? = nil,
        _ portDistributor: org_eclipse_elk_alg_layered_p3order_AbstractBarycenterPortDistributor,
        _ graph: [[org_eclipse_elk_alg_layered_graph_LNode]]
    ) {
        super.init(constraintResolver, random, portDistributor, graph)
    }

    // MARK: - Overridden minimizeCrossings (matching Java exactly)

    package override func minimizeCrossings(
        _ layer: inout [org_eclipse_elk_alg_layered_graph_LNode],
        _ preOrdered: Bool,
        _ randomize: Bool,
        _ forward: Bool
    ) {
        if layer.isEmpty { return }

        // Use inherited (parent) barycenter calculation — port-position-based
        if randomize {
            randomizeBarycenters(layer)
        } else {
            calculateBarycenters(layer, forward)
            fillInUnknownBarycenters(layer, preOrdered)
        }

        if layer.count > 1 {
            let forceModelOrder = (layer[0].getGraph()?.getProperty(
                Self.FORCE_MODEL_ORDER_KEY) as? Bool) ?? false

            if forceModelOrder {
                Self.insertionSort(&layer, compareNodes(_:_:), self)
            } else {
                // Java: Collections.sort(layer, barycenterStateComparator)
                layer = layer.enumerated().sorted { lhs, rhs in
                    let value = self.compareNodes(lhs.element, rhs.element)
                    if value == 0 { return lhs.offset < rhs.offset }
                    return value < 0
                }.map(\.element)
            }

            // Resolve ordering constraints (matching Java: only when NOT forceModelOrder)
            if !forceModelOrder {
                constraintResolver?.processConstraints(&layer)
            }
        }
    }

    // MARK: - Model-order-aware comparator (barycenterStateComparator in Java)

    package func compareNodes(
        _ n1: org_eclipse_elk_alg_layered_graph_LNode,
        _ n2: org_eclipse_elk_alg_layered_graph_LNode
    ) -> Int {
        // Skip FIRST_SEPARATE / LAST_SEPARATE constraint nodes
        if isSeparateConstraintNode(n1) || isSeparateConstraintNode(n2) {
            return 0
        }

        // Check transitive dependencies first
        let transitive = compareBasedOnTransitiveDependencies(n1, n2)
        if transitive != 0 { return transitive }

        // Compare by model order for real nodes (both must have MODEL_ORDER)
        let m1 = n1.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER) as? Int
        let m2 = n2.getProperty(org_eclipse_elk_alg_layered_options_InternalProperties.MODEL_ORDER) as? Int

        if let m1, let m2 {
            // In Java, this calls CMGroupModelOrderCalculator.calculateModelOrderOrGroupModelOrder
            // For normal case (no enforced group order), it returns plain model order
            var value = m1 == m2 ? 0 : (m1 < m2 ? -1 : 1)

            // Check group order strategy
            let strategy = n1.getGraph()?.getProperty(
                org_eclipse_elk_alg_layered_options_LayeredOptions
                    .CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CM_GROUP_ORDER_STRATEGY
            ) as? org_eclipse_elk_alg_layered_options_GroupOrderStrategy

            if strategy == .ONLY_WITHIN_GROUP {
                let group1 = n1.getProperty(
                    org_eclipse_elk_alg_layered_options_LayeredOptions
                        .CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CROSSING_MINIMIZATION_ID
                ) as? AnyHashable
                let group2 = n2.getProperty(
                    org_eclipse_elk_alg_layered_options_LayeredOptions
                        .CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CROSSING_MINIMIZATION_ID
                ) as? AnyHashable
                if group1 != group2 {
                    value = 0
                }
            }

            if value < 0 {
                updateBiggerAndSmallerAssociations(n1, n2)
                return value
            } else if value > 0 {
                updateBiggerAndSmallerAssociations(n2, n1)
                return value
            }
        }

        // Fall back to barycenter comparison (uses port-position-based barycenters from parent)
        return compareBasedOnBarycenter(n1, n2)
    }

    // MARK: - Barycenter-based comparison using inherited BarycenterState

    private func compareBasedOnBarycenter(
        _ n1: org_eclipse_elk_alg_layered_graph_LNode,
        _ n2: org_eclipse_elk_alg_layered_graph_LNode
    ) -> Int {
        let s1 = stateOf(n1)
        let s2 = stateOf(n2)
        if let b1 = s1.barycenter, let b2 = s2.barycenter {
            if b1 < b2 {
                updateBiggerAndSmallerAssociations(n1, n2)
                return -1
            }
            if b1 > b2 {
                updateBiggerAndSmallerAssociations(n2, n1)
                return 1
            }
            return 0
        } else if s1.barycenter != nil {
            updateBiggerAndSmallerAssociations(n1, n2)
            return -1
        } else if s2.barycenter != nil {
            updateBiggerAndSmallerAssociations(n2, n1)
            return 1
        }
        return 0
    }

    // MARK: - Transitive dependency tracking

    private func compareBasedOnTransitiveDependencies(
        _ n1: org_eclipse_elk_alg_layered_graph_LNode,
        _ n2: org_eclipse_elk_alg_layered_graph_LNode
    ) -> Int {
        let id1 = ObjectIdentifier(n1)
        let id2 = ObjectIdentifier(n2)

        if let set = biggerThan[id1], set.contains(id2) { return 1 }
        else if biggerThan[id1] == nil { biggerThan[id1] = [] }

        if let set = biggerThan[id2], set.contains(id1) { return -1 }
        else if biggerThan[id2] == nil { biggerThan[id2] = [] }

        if let set = smallerThan[id1], set.contains(id2) { return -1 }
        else if smallerThan[id1] == nil { smallerThan[id1] = [] }

        if let set = smallerThan[id2], set.contains(id1) { return 1 }
        else if smallerThan[id2] == nil { smallerThan[id2] = [] }

        return 0
    }

    package func updateBiggerAndSmallerAssociations(
        _ bigger: org_eclipse_elk_alg_layered_graph_LNode,
        _ smaller: org_eclipse_elk_alg_layered_graph_LNode
    ) {
        let biggerID = ObjectIdentifier(bigger)
        let smallerID = ObjectIdentifier(smaller)

        let smallerNodeBiggerThan = biggerThan[smallerID] ?? []
        let biggerNodeSmallerThan = smallerThan[biggerID] ?? []

        biggerThan[biggerID, default: []].insert(smallerID)
        smallerThan[smallerID, default: []].insert(biggerID)

        for verySmallID in smallerNodeBiggerThan {
            biggerThan[biggerID, default: []].insert(verySmallID)
            smallerThan[verySmallID, default: []].insert(biggerID)
            smallerThan[verySmallID, default: []].formUnion(biggerNodeSmallerThan)
        }

        for veryBigID in biggerNodeSmallerThan {
            smallerThan[smallerID, default: []].insert(veryBigID)
            biggerThan[veryBigID, default: []].insert(smallerID)
            biggerThan[veryBigID, default: []].formUnion(smallerNodeBiggerThan)
        }
    }

    // MARK: - Insertion sort for forceModelOrder mode

    package static func insertionSort(
        _ layer: inout [org_eclipse_elk_alg_layered_graph_LNode],
        _ comparator: (org_eclipse_elk_alg_layered_graph_LNode, org_eclipse_elk_alg_layered_graph_LNode) -> Int,
        _ barycenterHeuristic: org_eclipse_elk_alg_layered_p3order_ModelOrderBarycenterHeuristic
    ) {
        guard layer.count > 1 else {
            barycenterHeuristic.clearTransitiveOrdering()
            return
        }

        var i = 1
        while i < layer.count {
            let temp = layer[i]
            var j = i
            while j > 0, comparator(layer[j - 1], temp) > 0 {
                layer[j] = layer[j - 1]
                j -= 1
            }
            layer[j] = temp
            i += 1
        }

        barycenterHeuristic.clearTransitiveOrdering()
    }

    package func clearTransitiveOrdering() {
        biggerThan = [:]
        smallerThan = [:]
    }

    // MARK: - Helpers

    private func isSeparateConstraintNode(_ node: org_eclipse_elk_alg_layered_graph_LNode) -> Bool {
        guard let constraint = node.getProperty(
            org_eclipse_elk_alg_layered_options_LayeredOptions.LAYERING_LAYER_CONSTRAINT
        ) as? org_eclipse_elk_alg_layered_options_LayerConstraint else {
            return false
        }
        return constraint == .FIRST_SEPARATE || constraint == .LAST_SEPARATE
    }

    package override func isDeterministic() -> Bool {
        true
    }
}
