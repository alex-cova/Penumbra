// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/PortType.java
import Foundation

/// Definition of port types.
package enum org_eclipse_elk_alg_layered_options_PortType {
    /// Undefined port type.
    case UNDEFINED
    /// Input port type.
    case INPUT
    /// Output port type.
    case OUTPUT

    // MARK: - Lowercase Aliases (Swift convention)
    package static let input = org_eclipse_elk_alg_layered_options_PortType.INPUT
    package static let output = org_eclipse_elk_alg_layered_options_PortType.OUTPUT
    package static let undefined = org_eclipse_elk_alg_layered_options_PortType.UNDEFINED
}
