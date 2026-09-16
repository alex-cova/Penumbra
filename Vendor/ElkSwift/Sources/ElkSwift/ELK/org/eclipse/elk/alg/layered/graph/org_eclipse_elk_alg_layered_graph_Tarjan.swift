import Foundation

/**
 * Tarjan implementation to be used during layered layout.
 */
package class Tarjan {
    
    package var edgesToBeReversed: [LEdge]
    package var index = 0
    package var stronglyConnectedComponents: [[LNode]] // FIXME Why no ordered set here? this is bad
    package var stack: [LNode] = []
    package var nodeToSCCID: [LNode: Int] = [:]
    
    package init(edgesToBeReversed: [LEdge],
                stronglyConnectedComponents: inout [[LNode]],
                nodeToSCCID: inout [LNode: Int]) {
        self.edgesToBeReversed = edgesToBeReversed
        self.stronglyConnectedComponents = stronglyConnectedComponents
        self.nodeToSCCID = nodeToSCCID
    }
    
    package func tarjan(_ graph: LGraph) {
        index = 0
        stack.removeAll()
        for node in graph.getLayerlessNodes() {
            if (node.getProperty(InternalProperties.TARJAN_ID) as? Int ?? -1) == -1 {
                stronglyConnected(node)
                stack.removeAll()
            }
        }
    }
    
    package func stronglyConnected(_ v: LNode) {
        v.setProperty(InternalProperties.TARJAN_ID, index)
        v.setProperty(InternalProperties.TARJAN_LOWLINK, index)
        index += 1
        stack.append(v)
        v.setProperty(InternalProperties.TARJAN_ON_STACK, true)

        for edge in v.getConnectedEdges() {
            let isReversed = edgesToBeReversed.contains { $0 === edge }
            if edge.getSource()?.getNode() !== v && !isReversed {
                continue
            }
            if edge.getSource()?.getNode() === v && isReversed {
                continue
            }

            let target: LNode
            if edge.getTarget()?.getNode() === v {
                guard let t = edge.getSource()?.getNode() else { continue }
                target = t
            } else {
                guard let t = edge.getTarget()?.getNode() else { continue }
                target = t
            }

            let targetTarjanId: Int = target.getProperty(InternalProperties.TARJAN_ID) as? Int ?? -1
            if targetTarjanId == -1 {
                stronglyConnected(target)
                let currentLowLink: Int = v.getProperty(InternalProperties.TARJAN_LOWLINK) as? Int ?? 0
                let targetLowLink: Int = target.getProperty(InternalProperties.TARJAN_LOWLINK) as? Int ?? 0
                v.setProperty(InternalProperties.TARJAN_LOWLINK, min(currentLowLink, targetLowLink))
            } else if target.getProperty(InternalProperties.TARJAN_ON_STACK) as? Bool ?? false {
                let currentLowLink: Int = v.getProperty(InternalProperties.TARJAN_LOWLINK) as? Int ?? 0
                let targetId: Int = target.getProperty(InternalProperties.TARJAN_ID) as? Int ?? 0
                v.setProperty(InternalProperties.TARJAN_LOWLINK, min(currentLowLink, targetId))
            }
        }

        let vLowLink: Int = v.getProperty(InternalProperties.TARJAN_LOWLINK) as? Int ?? 0
        let vId: Int = v.getProperty(InternalProperties.TARJAN_ID) as? Int ?? 0
        if vLowLink == vId {
            var sCC: Set<LNode> = []
            var n: LNode?
            repeat {
                n = stack.popLast()
                n?.setProperty(InternalProperties.TARJAN_ON_STACK, false)
                if let node = n {
                    sCC.insert(node)
                }
            } while n !== v
            
            if sCC.count > 1 {
                let index = stronglyConnectedComponents.count
                stronglyConnectedComponents.append(Array(sCC))
                for node in sCC {
                    nodeToSCCID[node] = index
                }
            }
        }
    }
    
    package func resetTarjan(_ graph: LGraph) {
        for n in graph.getLayerlessNodes() {
            n.setProperty(InternalProperties.TARJAN_ON_STACK, false)
            n.setProperty(InternalProperties.TARJAN_LOWLINK, -1)
            n.setProperty(InternalProperties.TARJAN_ID, -1)
            stack.removeAll()
            for e in n.getConnectedEdges() {
                e.setProperty(InternalProperties.IS_PART_OF_CYCLE, false)
            }
        }
    }
}
