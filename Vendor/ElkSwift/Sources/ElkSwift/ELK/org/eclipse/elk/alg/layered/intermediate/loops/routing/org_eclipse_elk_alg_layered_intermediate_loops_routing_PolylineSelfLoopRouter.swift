import Foundation

package class org_eclipse_elk_alg_layered_intermediate_loops_routing_PolylineSelfLoopRouter: OrthogonalSelfLoopRouter {

    private static let CORNER_DISTANCE: Double = 10
    private static let TOLERANCE: Double = 0.01

    package override init() {
        super.init()
    }

    override func modifyBendPoints(_ slEdge: SelfLoopEdge, _ routingDirection: EdgeRoutingDirection,
                                    _ bendPoints: KVectorChain) -> KVectorChain {
        let lSourcePort = slEdge.getSLSource().getLPort()
        bendPoints.insert(lSourcePort.getPosition().clone().add(lSourcePort.getAnchor()), at: 0)

        let lTargetPort = slEdge.getSLTarget().getLPort()
        bendPoints.add(lTargetPort.getPosition().clone().add(lTargetPort.getAnchor()))

        return cutCorners(bendPoints, Self.CORNER_DISTANCE)
    }

    package func cutCorners(_ bendPoints: KVectorChain, _ distance: Double) -> KVectorChain {
        let result = KVectorChain()

        var corner = bendPoints.get(0)
        var next = bendPoints.get(1)

        for secondBPIndex in 2..<bendPoints.size() {
            let previous = corner
            corner = next
            next = bendPoints.get(secondBPIndex)

            let offset1 = nearZeroToZero(previous.clone().sub(corner))
            let offset2 = nearZeroToZero(next.clone().sub(corner))

            var effectiveDistance = distance
            effectiveDistance = min(effectiveDistance, abs(offset1.x + offset1.y) / 2)
            effectiveDistance = min(effectiveDistance, abs(offset2.x + offset2.y) / 2)

            offset1.x = copysign(effectiveDistance, offset1.x) * (offset1.x == 0 ? 0 : 1)
            offset1.y = copysign(effectiveDistance, offset1.y) * (offset1.y == 0 ? 0 : 1)
            offset2.x = copysign(effectiveDistance, offset2.x) * (offset2.x == 0 ? 0 : 1)
            offset2.y = copysign(effectiveDistance, offset2.y) * (offset2.y == 0 ? 0 : 1)

            result.add(offset1.add(corner))
            result.add(offset2.add(corner))
        }

        return result
    }

    private func nearZeroToZero(_ vector: KVector) -> KVector {
        if vector.x >= -Self.TOLERANCE && vector.x <= Self.TOLERANCE {
            vector.x = 0
        }
        if vector.y >= -Self.TOLERANCE && vector.y <= Self.TOLERANCE {
            vector.y = 0
        }
        return vector
    }
}
