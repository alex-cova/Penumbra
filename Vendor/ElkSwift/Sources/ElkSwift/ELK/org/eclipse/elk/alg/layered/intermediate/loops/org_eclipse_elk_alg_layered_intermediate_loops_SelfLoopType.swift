// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/loops/SelfLoopType.java

import Foundation

package enum org_eclipse_elk_alg_layered_intermediate_loops_SelfLoopType {
    case ONE_SIDE
    case TWO_SIDES_CORNER
    case TWO_SIDES_OPPOSING
    case THREE_SIDES
    case FOUR_SIDES

    package static func fromPortSides(
        _ portSides: Set<org_eclipse_elk_core_options_PortSide>
    ) -> org_eclipse_elk_alg_layered_intermediate_loops_SelfLoopType? {
        if portSides.contains(.UNDEFINED) {
            assertionFailure("Port sides must not contain UNDEFINED")
            return nil
        }

        switch portSides.count {
        case 1:
            return .ONE_SIDE

        case 2:
            let eastWest = portSides.contains(.EAST) && portSides.contains(.WEST)
            let northSouth = portSides.contains(.NORTH) && portSides.contains(.SOUTH)
            return (eastWest || northSouth) ? .TWO_SIDES_OPPOSING : .TWO_SIDES_CORNER

        case 3:
            return .THREE_SIDES

        case 4:
            return .FOUR_SIDES

        default:
            return nil
        }
    }
}
