import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_loops_SelfLoopPort {

    private let lPort: LPort
    private let hadOnlySelfLoopsValue: Bool
    private var incomingSLEdges: [SelfLoopEdge] = []
    private var outgoingSLEdges: [SelfLoopEdge] = []
    private var hiddenValue: Bool = false

    init(_ lPort: LPort) {
        self.lPort = lPort

        // Check if the port is only incident to self loops
        self.hadOnlySelfLoopsValue = lPort.getConnectedEdges().allSatisfy { $0.isSelfLoop() }
    }

    package func getLPort() -> LPort {
        return lPort
    }

    package func hadOnlySelfLoops() -> Bool {
        return hadOnlySelfLoopsValue
    }

    package func isHidden() -> Bool {
        return hiddenValue
    }

    package func setHidden(_ hidden: Bool) {
        self.hiddenValue = hidden
    }

    package func getIncomingSLEdges() -> [SelfLoopEdge] {
        return incomingSLEdges
    }

    package func getOutgoingSLEdges() -> [SelfLoopEdge] {
        return outgoingSLEdges
    }

    func appendIncomingSLEdge(_ edge: SelfLoopEdge) {
        incomingSLEdges.append(edge)
    }

    func appendOutgoingSLEdge(_ edge: SelfLoopEdge) {
        outgoingSLEdges.append(edge)
    }

    package func getSLNetFlow() -> Int {
        return incomingSLEdges.count - outgoingSLEdges.count
    }
}
