import Foundation

/**
 * Represents a piecewise bezier spline. This means a collection of bezier curves adding up to a
 * smooth spline.
 */
package class BezierSpline {
    
    /**
     * internal storage for all pieces, use LinkedList, as there usually is added an arbitrary
     * number of piecewise curves to the end.
     */
    package var curves: [BezierCurve] = []
    
    /**
     * Add a new piece of bezierCurve to the whole spline.
     */
    package func addCurve(_ curve: BezierCurve) {
        curves.append(curve)
    }
    
    /**
     * add a whole piecewise spline to this spline.
     * 
     * @param spline spline being added
     * @param beginning if true, the new spline is added at the beginning, otherwise at the end
     */
    package func addSpline(_ spline: BezierSpline, beginning: Bool) {
        if !beginning {
            curves.append(contentsOf: spline.curves)
        } else {
            curves.insert(contentsOf: spline.curves, at: 0)
        }
    }
    
    /**
     * Adds a new curve to this piecewise bezier spline. The curve is represented by the startPnt,
     * endPnt and its control points.
     */
    package func addCurve(_ startPnt: KVector, _ fstCtrPnt: KVector, _ sndCtrPnt: KVector, _ endPnt: KVector) {
        curves.append(BezierCurve(start: startPnt, fstControlPnt: fstCtrPnt, sndControlPnt: sndCtrPnt, end: endPnt))
    }
    
    /**
     * returns the first point of the first piece of the spline.
     */
    package func getStartPoint() -> KVector {
        guard let first = curves.first else { return KVector() }
        return first.start
    }
    
    /**
     * returns the last point of the last piece of the spline.
     */
    package func getEndPoint() -> KVector {
        guard let last = curves.last else { return KVector() }
        return last.end
    }
    
    /**
     * returns the inner points of this piecewise bezier spline.
     */
    package func getInnerPoints() -> [KVector] {
        if curves.isEmpty {
            return []
        }
        
        let size = (curves.count * 3) - 1
        var points: [KVector] = Array(repeating: KVector(), count: size)
        
        var i = 0
        for (index, curve) in curves.enumerated() {
            points[i] = curve.fstControlPnt
            i += 1
            points[i] = curve.sndControlPnt
            i += 1
            if index < curves.count - 1 {
                points[i] = curve.end
                i += 1
            }
        }
        
        return points
    }
    
    /**
     * returns just the base points, including start and end point. those are the points REALLY
     * lying on the curve.
     */
    package func getBasePoints() -> [KVector] {
        let size = curves.count + 1
        var ret: [KVector] = Array(repeating: KVector(), count: size)
        
        guard let firstCurve = curves.first else { return [] }
        ret[0] = firstCurve.start
        var i = 1
        for curve in curves {
            ret[i] = curve.end
            i += 1
        }
        
        return ret
    }
    
    /**
     * Returns a sequence of points, representing this spline as an approximated polyline.
     */
    package func getPolylineApprx(accuracy: Int) -> [KVector] {
        // there are #accuracy points per curve, plus the additional start point
        let totalPoints = (curves.count * accuracy) + 1
        var apprx: [KVector] = Array(repeating: KVector(), count: totalPoints)
        
        // add initial point
        guard let firstCurve = curves.first else { return [] }
        apprx[0] = firstCurve.start
        
        var i = 1
        // add all further points
        for curve in curves {
            let pts = ElkMath.approximateBezierSegmentArray(accuracy, curve.asArray())
            for p in pts {
                // clone in case of latter changes
                apprx[i] = p.clone()
                i += 1
            }
        }
        return apprx
    }
    
    /**
     * Returns piecewise curves.
     */
    package func getCurves() -> [BezierCurve] {
        return curves
    }
    
    package func toString() -> String {
        var s = ""
        for curve in curves {
            s += "\(curve.start) -> \(curve.fstControlPnt) -> \(curve.sndControlPnt) -> \(curve.end)\n"
        }
        return s
    }
    
    /**
     * Represents a part of the whole spline consisting of start and end point, and two control
     * points.
     */
    package struct BezierCurve {
        
        /**
         * start point.
         */
        package var start: KVector
        /**
         * first control point.
         */
        package var fstControlPnt: KVector
        /**
         * snd control point.
         */
        package var sndControlPnt: KVector
        /**
         * end point.
         */
        package var end: KVector
        
        /**
         * Initialize a Bezier curve segment.
         */
        package init(start: KVector, fstControlPnt: KVector, sndControlPnt: KVector, end: KVector) {
            self.start = start
            self.fstControlPnt = fstControlPnt
            self.sndControlPnt = sndControlPnt
            self.end = end
        }
        
        /**
         * Returns this segment of the bezier spline as a list of Points.
         */
        package func asVectorList() -> [KVector] {
            return [start, fstControlPnt, sndControlPnt, end]
        }
        
        /**
         * Returns this segment of the bezier spline as an array of Points.
         */
        package func asArray() -> [KVector] {
            return [start, fstControlPnt, sndControlPnt, end]
        }
    }
}
