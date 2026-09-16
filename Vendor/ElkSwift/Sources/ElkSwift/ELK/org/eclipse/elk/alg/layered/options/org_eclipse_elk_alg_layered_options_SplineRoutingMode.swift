// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/SplineRoutingMode.java

import Foundation

package enum org_eclipse_elk_alg_layered_options_SplineRoutingMode {
    /// Uses computed long edge dummies as hint for the spline paths. Ensures that the splines
    /// do not overlap with nodes. On the downside, the spline paths feel rather orthogonal-ish.
    case CONSERVATIVE
    /// Basically the same as `CONSERVATIVE`. Uses softer curves where edges attach to the nodes,
    /// at the risk of overlapping other graph elements in that area.
    case CONSERVATIVE_SOFT
    /// Still uses computed long edge dummies as hints but uses far less control points to define
    /// the spline paths. While this makes the splines curvier, the chances of splines overlapping
    /// nodes increase significantly.
    case SLOPPY
}
