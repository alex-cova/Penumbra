// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/ValidifyStrategy.java

import Foundation

package enum org_eclipse_elk_alg_layered_options_ValidifyStrategy {
    /// Do not touch my cuts!.
    case NO
    /// Just increase forbidden cuts until they are valid.
    case GREEDY
    /// Be a bit smarter and check if the lastly valid cut is closer than the next valid cut.
    case LOOK_BACK
}
