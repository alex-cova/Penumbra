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

package typealias Predicate<T> = (T) -> Bool

/**
 * A port in a layered graph.
 */
package final class LPort: LShape {

    package static let OUTPUT_PREDICATE: Predicate<LPort> = { !$0.outgoingEdges.isEmpty }
    package static let INPUT_PREDICATE: Predicate<LPort> = { !$0.incomingEdges.isEmpty }
    package static let NORTH_PREDICATE: Predicate<LPort> = { $0.side == .NORTH }
    package static let EAST_PREDICATE: Predicate<LPort> = { $0.side == .EAST }
    package static let SOUTH_PREDICATE: Predicate<LPort> = { $0.side == .SOUTH }
    package static let WEST_PREDICATE: Predicate<LPort> = { $0.side == .WEST }

    package weak var owner: LNode?
    package var side: PortSide = .UNDEFINED
    package var anchor: KVector = KVector()
    package var explicitlySuppliedPortAnchor = false
    package var margin = LMargin()
    package var labels: [LLabel] = []
    package var incomingEdges: [LEdge] = []
    package var outgoingEdges: [LEdge] = []
    package var connectedToExternalNodes = true

    /// Alias for owner, for code that accesses `port.node`
    package var node: LNode? {
        get { return owner }
        set { owner = newValue }
    }

    package var isInput: Bool { !incomingEdges.isEmpty }
    package var isOutput: Bool { !outgoingEdges.isEmpty }

    /// Computed property returning position + anchor (same as getAbsoluteAnchor()).
    package var absoluteAnchor: KVector {
        return getAbsoluteAnchor()
    }

    /// The number of connected edges (incoming + outgoing).
    package var degree: Int {
        return incomingEdges.count + outgoingEdges.count
    }

    package func getNode() -> LNode? {
        return owner
    }

    package func setNode(_ node: LNode?) {
        if let oldOwner = owner {
            oldOwner.ports.removeAll { $0 === self }
        }
        owner = node
        if let newOwner = owner {
            newOwner.ports.append(self)
        }
    }

    package func getSide() -> PortSide {
        return side
    }

    package func setSide(_ theside: PortSide) {
        guard theside != .UNDEFINED else { return }
        side = theside
        if !explicitlySuppliedPortAnchor {
            switch side {
            case .NORTH:
                anchor.x = getSize().x / 2
                anchor.y = 0
            case .EAST:
                anchor.x = getSize().x
                anchor.y = getSize().y / 2
            case .SOUTH:
                anchor.x = getSize().x / 2
                anchor.y = getSize().y
            case .WEST:
                anchor.x = 0
                anchor.y = getSize().y / 2
            default:
                break
            }
        }
    }

    package func getAnchor() -> KVector {
        return anchor
    }

    package func isExplicitlySuppliedPortAnchor() -> Bool {
        return explicitlySuppliedPortAnchor
    }

    package func setExplicitlySuppliedPortAnchor(_ fixed: Bool) {
        explicitlySuppliedPortAnchor = fixed
    }

    package func getAbsoluteAnchor() -> KVector {
        guard let ownerPos = owner?.getPosition() else { return KVector() }
        let myPos = getPosition()
        return KVector(ownerPos.x + myPos.x + anchor.x, ownerPos.y + myPos.y + anchor.y)
    }

    package func getMargin() -> LMargin {
        return margin
    }

    package func getLabels() -> [LLabel] {
        return labels
    }

    package func getName() -> String? {
        if !labels.isEmpty {
            return labels[0].getText()
        }
        return nil
    }

    package func getDegree() -> Int {
        return incomingEdges.count + outgoingEdges.count
    }

    package func getNetFlow() -> Int {
        return incomingEdges.count - outgoingEdges.count
    }

    package func getIncomingEdges() -> [LEdge] {
        return incomingEdges
    }

    package func getOutgoingEdges() -> [LEdge] {
        return outgoingEdges
    }

    package func getConnectedEdges() -> [LEdge] {
        return incomingEdges + outgoingEdges
    }

    package func isConnectedToExternalNodes() -> Bool {
        return connectedToExternalNodes
    }

    package func setConnectedToExternalNodes(_ conn: Bool) {
        connectedToExternalNodes = conn
    }

    package func getPredecessorPorts() -> [LPort] {
        return incomingEdges.compactMap { $0.getSource() }
    }

    package func getSuccessorPorts() -> [LPort] {
        return outgoingEdges.compactMap { $0.getTarget() }
    }

    package func getConnectedPorts() -> [LPort] {
        return getPredecessorPorts() + getSuccessorPorts()
    }

    package func getIndex() -> Int {
        guard let owner = owner else { return -1 }
        return owner.ports.firstIndex { $0 === self } ?? -1
    }

    package override func getDesignation() -> String? {
        if !labels.isEmpty {
            let text = labels[0].getText()
            if !text.isEmpty {
                return text
            }
        }
        if let designation = super.getDesignation(), !designation.isEmpty {
            return designation
        }
        return String(getIndex())
    }

    package func toString() -> String {
        var result = "p_\(getDesignation() ?? "")"
        if let owner = owner {
            result += "[\(owner)]"
        }
        return result
    }
}
