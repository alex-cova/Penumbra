/*******************************************************************************
 * Copyright (c) 2010, 2019 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

import Foundation

/**
 * An edge in a layered graph.
 */
package final class LEdge: LGraphElement {

    package var bendPoints = KVectorChain()
    package var source: LPort?
    package var target: LPort?
    package var labels: [LLabel] = []

    package func reverse(_ layeredGraph: LGraph, _ adaptPorts: Bool) {
        guard let oldSource = self.source, let oldTarget = self.target else { return }

        setSource(nil)
        setTarget(nil)

        if adaptPorts, let collect: Bool = oldTarget.getProperty(InternalProperties.INPUT_COLLECT), collect,
           let oldTargetNode = oldTarget.getNode() {
            setSource(LGraphUtil.provideCollectorPort(layeredGraph, node: oldTargetNode, type: .output, side: .EAST))
        } else {
            setSource(oldTarget)
        }

        if adaptPorts, let collect: Bool = oldSource.getProperty(InternalProperties.OUTPUT_COLLECT), collect,
           let oldSourceNode = oldSource.getNode() {
            setTarget(LGraphUtil.provideCollectorPort(layeredGraph, node: oldSourceNode, type: .input, side: .WEST))
        } else {
            setTarget(oldSource)
        }

        // Switch end labels
        for label in labels {
            if let labelPlacement: EdgeLabelPlacement = label.getProperty(LayeredOptions.EDGE_LABELS_PLACEMENT) {
                if labelPlacement == .tail {
                    label.setProperty(LayeredOptions.EDGE_LABELS_PLACEMENT, EdgeLabelPlacement.head)
                } else if labelPlacement == .head {
                    label.setProperty(LayeredOptions.EDGE_LABELS_PLACEMENT, EdgeLabelPlacement.tail)
                }
            }
        }

        let reversed: Bool = getProperty(InternalProperties.REVERSED) ?? false
        setProperty(InternalProperties.REVERSED, !reversed)

        self.bendPoints = self.bendPoints.reverse()
    }

    package func getSource() -> LPort? {
        return source
    }

    package func setSource(_ source: LPort?) {
        if let oldSource = self.source {
            oldSource.outgoingEdges.removeAll { $0 === self }
        }
        self.source = source
        if let newSource = self.source {
            newSource.outgoingEdges.append(self)
        }
    }

    package func getTarget() -> LPort? {
        return target
    }

    package func setTarget(_ target: LPort?) {
        if let oldTarget = self.target {
            oldTarget.incomingEdges.removeAll { $0 === self }
        }
        self.target = target
        if let newTarget = self.target {
            newTarget.incomingEdges.append(self)
        }
    }

    package func setTargetAndInsertAtIndex(_ targetPort: LPort?, _ index: Int) {
        if let oldTarget = self.target {
            oldTarget.incomingEdges.removeAll { $0 === self }
        }
        self.target = targetPort
        if let newTarget = self.target {
            newTarget.incomingEdges.insert(self, at: index)
        }
    }

    package func isSelfLoop() -> Bool {
        guard let src = source, let tgt = target else { return false }
        return src.getNode() != nil && src.getNode() === tgt.getNode()
    }

    package func isInLayerEdge() -> Bool {
        return !isSelfLoop() && (source?.getNode()?.getLayer() === target?.getNode()?.getLayer())
    }

    package func getBendPoints() -> KVectorChain {
        return bendPoints
    }

    package func getLabels() -> [LLabel] {
        return labels
    }

    package func getOther(_ port: LPort) -> LPort {
        if port === source, let t = target { return t }
        if port === target, let s = source { return s }
        assertionFailure("'port' must be either the source port or target port of the edge.")
        return port
    }

    package func getOther(_ node: LNode) -> LNode {
        if node === source?.getNode(), let t = target?.getNode() { return t }
        if node === target?.getNode(), let s = source?.getNode() { return s }
        assertionFailure("'node' must either be the source node or target node of the edge.")
        return node
    }

    package override func getDesignation() -> String? {
        if !labels.isEmpty, let firstLabel = labels.first {
            let text = firstLabel.getText()
            if !text.isEmpty {
                return text
            }
        }
        return super.getDesignation()
    }

    package func toString() -> String {
        var result = "e_"
        if let designation = getDesignation() {
            result += designation
        }
        if let src = source, let tgt = target {
            result += " \(src.getDesignation() ?? "") -> \(tgt.getDesignation() ?? "")"
        }
        return result
    }
}
