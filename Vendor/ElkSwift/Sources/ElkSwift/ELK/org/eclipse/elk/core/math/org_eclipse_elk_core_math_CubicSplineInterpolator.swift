import Foundation

/**
 * Provides a technique to calculate a piece-wise bezier spline for a list of given points.
 * 
 * As described in "Graphic Gems, Andrew Glassner (editor), Academic Press, 1990".
 */
package class CubicSplineInterpolator: ISplineInterpolator {
    
    /**
     * Interpolation Coefficients for even n. Address like : [m-1][k-1] for m > 7 the values for 1
     * <= k <= 7 have converged to constant values independent of m. thus, fur n >= 15 one can use
     * the values of m = 7
     */
    package static let INTERP_COEF_EVEN: [[Double]] = [
        [0.25],
        [0.2677, -0.0667],
        [0.2679, -0.0714, 0.0179],
        [0.2679, -0.0718, 0.0191, -0.0048],
        [0.2679, -0.0718, 0.0192, -0.0051, 0.0013],
        [0.2679, -0.0718, 0.0192, -0.0052, 0.0014, -0.0003],
        [0.2679, -0.0718, 0.0192, -0.0052, 0.0014, -0.0004, 0.0001]
    ]
    
    /**
     * Interpolation Coefficients for odd n. Address like : [m-1][k-1]. for m > 7 the values for 1
     * <= k <= 7 have converged to constant values independent of m. thus, fur n >= 15 one can use
     * the values of m = 7
     */
    package static let INTERP_COEF_ODD: [[Double]] = [
        [0.3333],
        [0.2727, -0.0909],
        [0.2683, -0.0732, 0.0244],
        [0.2680, -0.0719, 0.0196, -0.0065],
        [0.2680, -0.0718, 0.0193, -0.0053, 0.0018],
        [0.2679, -0.0718, 0.0192, -0.0052, 0.0014, -0.0005],
        [0.2679, -0.0718, 0.0192, -0.0052, 0.0014, -0.0004, 0.0001]
    ]
    
    /** maximal k value which is "interesting". */
    package static let MAX_K = 7
    
    /** factor describing the length a in/outgoing vector is scaled. */
    package static let TANGENT_SCALE: Double = 0.25
    
    /**
     * Calculates a closed piecewise bezier spline where the first point is start and end.
     * 
     * this function is not fully tested yet!
     * 
     * @param points
     *            points being passed by the spline
     * @return piecewise bezier spline
     */
    package func calculateClosedBezierSpline(_ points: [KVector]) -> BezierSpline {
        let spline = BezierSpline()
        
        let n = points.count
        let even = (n % 2 == 0)
        // set m depending on n even or odd.
        let mRaw = even ? (n - 2) / 2 : (n - 1) / 2
        let m = min(mRaw, CubicSplineInterpolator.MAX_K)
        
        let d: [KVector] = Array(repeating: KVector(), count: n)
        
        for i in 0..<n {
            // calculate sum for every Di
            for k in 1...m {
                let coefIndex = min(m - 1, CubicSplineInterpolator.MAX_K - 1)
                let kIndex = min(k - 1, CubicSplineInterpolator.MAX_K - 1)
                let a = even ? CubicSplineInterpolator.INTERP_COEF_ODD[coefIndex][kIndex] : CubicSplineInterpolator.INTERP_COEF_EVEN[coefIndex][kIndex]
                let idxPlus = (i + k) % n
                let idxMinus = (i - k + n) % n
                d[i].x += a * (points[idxPlus].x - points[idxMinus].x)
                d[i].y += a * (points[idxPlus].y - points[idxMinus].y)
            }
        }
        
        // add all pieces to the piecewise bezier spline
        for i in 0..<n {
            let nextIndex = (i + 1) % n
            let p1 = KVector.sum(d[i], points[i])
            let p2 = points[nextIndex].clone().sub(d[nextIndex])
            spline.addCurve(points[i], p1, p2, points[nextIndex])
        }
        
        return spline
    }
    
    /**
     * Calculates a piecewise bezier spline, hereby assumes, that the "head in" tangent corresponds
     * to the line from the starting point to the first point and the "head out" tangent from the
     * n-1th point to the end point.
     * 
     * @param points
     *            points being passed by the spline
     * @return piecewise bezier spline
     */
    package func calculateOpenBezierSpline(_ points: [KVector]) -> BezierSpline {
        let startTan = points[1].clone().sub(points[0]).normalize()
        let endTan = points[points.count - 2].clone().sub(points[points.count - 1]).normalize()
        return calculateOpenBezierSpline(points, startTan, endTan, false)
    }
    
    /**
     * Calculates a piecewise bezier spline.
     * 
     * @param points
     *            points being passed by the spline
     * 
     * @param startTan
     *            vector describing into which direction to head out of the initial point
     * @param endTan
     *            vector describing direction to head into the final node
     * @param tangentScale
     *            if true, the tangent is scaled depending on the distance to the next ctr point, if
     *            false the tangent is used as passed
     * @return piecewise bezier spline
     */
    package func calculateOpenBezierSpline(_ points: [KVector], _ startTan: KVector, _ endTan: KVector, _ tangentScale: Bool) -> BezierSpline {
        // in this case the paper talks about n-1 points, therefore it's kind of inconsistent to the
        // closed approach
        let spline = BezierSpline()
        
        let n = points.count - 1
        // t is the "extended curve" degenerating the points to a closed loop
        var t: [KVector] = Array(repeating: KVector(), count: 2 * n)
        var d: [KVector] = Array(repeating: KVector(), count: n + 1)
        
        // set initial and final tangent vectors
        var startScale: Double = 1.0
        var endScale: Double = 1.0
        if tangentScale {
            if points.count == 2 {
                let dist = points[0].distance(points[1])
                startScale = dist * CubicSplineInterpolator.TANGENT_SCALE
                endScale = startScale
            } else {
                let dist1 = points[0].distance(points[1])
                let dist2 = points[n - 1].distance(points[n])
                startScale = dist1 * CubicSplineInterpolator.TANGENT_SCALE
                endScale = dist2 * CubicSplineInterpolator.TANGENT_SCALE
            }
        }
        d[0] = startTan.clone().scale(startScale)
        d[n] = endTan.clone().scale(endScale)
        
        // set first and last t
        t[0] = KVector.sum(points[0], d[0])
        t[n] = points[n].clone().sub(d[n])
        
        // extend t
        for i in 1..<n {
            t[i] = points[i]
            t[2 * n - i] = t[i]
        }
        
        // n in this case always even
        let m = min(n - 1, CubicSplineInterpolator.MAX_K)
        
        // calculate all Di's using the Ti's
        for i in 1..<n {
            for k in 1...m {
                let a = CubicSplineInterpolator.INTERP_COEF_EVEN[m - 1][k - 1]
                // Ti = T-i for 0 < i < n, is it really ok to neglect 0 and n?!
                let idxPlus = i + k
                let idxMinus = abs(i - k)
                d[i].x += a * (t[idxPlus].x - t[idxMinus].x)
                d[i].y += a * (t[idxPlus].y - t[idxMinus].y)
            }
        }
        
        // create all bezier spline segments
        for i in 0..<n {
            let bend1 = KVector.sum(points[i], d[i])
            let bend2 = points[i + 1].clone().sub(d[i + 1])
            spline.addCurve(points[i], bend1, bend2, points[i + 1])
        }
        
        return spline
    }
    
    package func interpolatePoints(_ points: [KVector]) -> BezierSpline {
        return calculateOpenBezierSpline(points)
    }

    package func interpolatePoints(_ points: [KVector], _ startVec: KVector, _ endVec: KVector, _ tangentScale: Bool) -> BezierSpline {
        return calculateOpenBezierSpline(points, startVec, endVec, tangentScale)
    }
}
