// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/GroupOrderStrategy.java

import Foundation

/// Determines how to count ordering violations during layered phases.
package enum org_eclipse_elk_alg_layered_options_GroupOrderStrategy {
    /// Different groups are not comparable neither by group id nor by model order.
    /// If total ordering is required, either ordering can still be used to create it.
    case ONLY_WITHIN_GROUP

    /// Model order is more important than group id when comparing elements from
    /// different ordering groups.
    case MODEL_ORDER

    /// Group id is more important than model order when comparing elements from
    /// different ordering groups. Secondary criterion is model order.
    case ENFORCED
}
