import Foundation

/**
 * Global interface for any Spline interpolator.
 */
package protocol ISplineInterpolator {

    /**
     * Returns a piecewise Bezier spline.
     *
     * - Parameter points: Array of points
     * - Returns: Piecewise Bezier spline
     */
    func interpolatePoints(_ points: [KVector]) -> BezierSpline

    /**
     * Returns a piecewise Bezier spline.
     *
     * - Parameters:
     *   - points: Array of points
     *   - startVec: Tangent vector specifying to head out of the first node
     *   - endVec: Tangent vector specifying to head into the last node
     *   - tangentScale: If true, the tangent is scaled depending on the distance to the next control point; if false, the tangent is used as passed
     * - Returns: Piecewise Bezier spline
     */
    func interpolatePoints(_ points: [KVector], _ startVec: KVector, _ endVec: KVector, _ tangentScale: Bool) -> BezierSpline
}
