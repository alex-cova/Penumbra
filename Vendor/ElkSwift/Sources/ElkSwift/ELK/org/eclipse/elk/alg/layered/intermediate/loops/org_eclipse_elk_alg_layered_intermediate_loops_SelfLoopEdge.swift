import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_loops_SelfLoopEdge: Hashable {

    private let lEdge: LEdge
    private var slHyperLoop: SelfHyperLoop?
    private let slSource: SelfLoopPort
    private let slTarget: SelfLoopPort

    init(_ lEdge: LEdge, _ slSource: SelfLoopPort, _ slTarget: SelfLoopPort) {
        self.lEdge = lEdge
        self.slSource = slSource
        self.slTarget = slTarget

        slSource.appendOutgoingSLEdge(self)
        slTarget.appendIncomingSLEdge(self)
    }

    package func getLEdge() -> LEdge {
        return lEdge
    }

    package func getSLHyperLoop() -> SelfHyperLoop? {
        return slHyperLoop
    }

    func setSLHyperLoop(_ slLoop: SelfHyperLoop) {
        self.slHyperLoop = slLoop
    }

    package func getSLSource() -> SelfLoopPort {
        return slSource
    }

    package func getSLTarget() -> SelfLoopPort {
        return slTarget
    }

    package func isInline() -> Bool {
        for label in lEdge.getLabels() {
            if let inline: Bool = label.getProperty(LayeredOptions.EDGE_LABELS_INLINE) as? Bool, inline {
                return true
            }
        }
        return false
    }

    package func getLabelSide() -> PortSide {
        guard let loop = self.slHyperLoop, let labels = loop.getSLLabels() else { return .UNDEFINED }
        return labels.getSide()
    }

    // MARK: - Hashable

    package static func == (lhs: org_eclipse_elk_alg_layered_intermediate_loops_SelfLoopEdge,
                           rhs: org_eclipse_elk_alg_layered_intermediate_loops_SelfLoopEdge) -> Bool {
        return lhs === rhs
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
