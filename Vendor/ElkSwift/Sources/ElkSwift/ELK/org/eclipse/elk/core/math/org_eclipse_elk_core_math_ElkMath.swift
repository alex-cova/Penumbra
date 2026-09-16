///*******************************************************************************
// * Copyright (c) 2009, 2015 Kiel University and others.
// * 
// * This program and the accompanying materials are made available under the
// * terms of the Eclipse Public License 2.0 which is available at
// * http://www.eclipse.org/legal/epl-2.0.
// *
// * SPDX-License-Identifier: EPL-2.0
// *******************************************************************************/
//package org.eclipse.elk.core.math;

import Foundation

///**
// * Mathematics utility class for the Eclipse Layout Kernel.
// * 
// * @author msp
// */
package final class ElkMath {
    
    ///**
    // * Hidden constructor to avoid instantiation.
    // */
    private init() {}
    
    ///** table of precomputed factorial values. */
    package static let factTable: [Int64] = [ 1, 1, 2, 6, 24, 120, 720, 5040, 40320,
            362880, 3628800, 39916800, 479001600, 6227020800, 87178291200, 1307674368000,
            20922789888000, 355687428096000, 6402373705728000, 121645100408832000,
            2432902008176640000 ]
    
    ///**
    // * The factorial of an integer x as long value. If x is negative or greater then 20 then
    // * IllegalArgumentException. This method always returns the exact value for x between 0 and 20.
    // * 
    // * @param x
    // *            an integer
    // * @return the factorial of x
    // * @throws IllegalArgumentException
    // *             if x<0 or x>20
    // */
    package static func factl(_ x: Int) -> Int64 {
        // IllegalArgumentException when x not between 0 and 20
        if x < 0 || x >= factTable.count {
            assertionFailure("The input must be between 0 and \(factTable.count)")
            return 0
        }
        // return the appropriate value from FACT_TABLE with index x
        return factTable[x]
    }
    
    ///**
    // * The factorial of an integer x as double value. If x is negative then
    // * IllegalArgumentException. If x>26 then the result is Infinity. This method returns the exact
    // * value for small input values, and uses Stirling's approximation for large input values.
    // * 
    // * @param x
    // *            an integer
    // * @return the factorial of x
    // * @throws IllegalArgumentException
    // *             if x<0
    // */
    package static func factd(_ x: Int) -> Double {
        // IllegalArgumentException when x < 0
        if x < 0 {
            assertionFailure("The input must be positive")
            return 0
        } else if x < factTable.count {
            return Double(factTable[x])
        } else {
            return sqrt(2.0 * Double.pi * Double(x)) * pow(Double(x), Double(x)) / pow(M_E, Double(x))
        }
    }
    
    ///**
    // * The binomial coefficient of integers n and k as long value. If n is not positive or k is not
    // * between 0 and n the result is IllegalArgumentException. This method always returns the exact
    // * value, but may take very long for large input values.
    // * 
    // * @param n
    // *            the upper integer
    // * @param k
    // *            the lower integer
    // * @return n choose k
    // * @throws IllegalArgumentException
    // *             if n < 0 or n < 0 or k > n
    // */
    package static func binomiall(_ n: Int, _ k: Int) -> Int64 {
        if n < 0 || k < 0 {
            assertionFailure("k and n must be positive")
            return 0
        } else if k > n {
            assertionFailure("k must be smaller than n")
            return 0
        } else if k == 0 || k == n {
            return 1
        } else if n == 0 {
            return 0
        } else if n < factTable.count {
            return factl(n) / (factl(k) * factl(n - k))
        } else {
            return binomiall(n - 1, k - 1) + binomiall(n - 1, k)
        }
    }
    
    ///**
    // * The binomial coefficient of integers n and k as double value. If n is not positive or k is
    // * not between 0 and n the result is IllegalArgumentException. This method returns the exact
    // * value for small input values, and uses an approximation for large input values.
    // * 
    // * @param n
    // *            the upper integer
    // * @param k
    // *            the lower integer
    // * @return n choose k
    // * @throws IllegalArgumentException
    // *             if n < 0 or n < 0 or k > n
    // */
    package static func binomiald(_ n: Int, _ k: Int) -> Double {
        if n < 0 || k < 0 {
            assertionFailure("k and n must be positive")
            return 0
        } else if k > n {
            assertionFailure("k must be smaller than n")
            return 0
        } else if k == 0 || k == n {
            return 1
        } else if n == 0 {
            return 0
        } else {
            return factd(n) / (factd(k) * factd(n - k))
        }
    }
    
    ///**
    // * The first argument raised to the power of the second argument.
    // * 
    // * @param a
    // *            the base
    // * @param b
    // *            the exponent
    // * @return a to the power of b
    // */
    package static func powd(_ a: Double, _ b: Int) -> Double {
        var result = 1.0
        var base = a
        var exp = (b >= 0 ? b : -b)
        while exp > 0 {
            if exp % 2 == 0 {
                base *= base
                exp /= 2
            } else {
                result *= base
                exp -= 1
            }
        }
        if b < 0 {
            return 1.0 / result
        } else {
            return result
        }
    }
    
    ///**
    // * The first argument raised to the power of the second argument.
    // * 
    // * @param a
    // *            the base
    // * @param b
    // *            the exponent
    // * @return a to the power of b
    // */
    package static func powf(_ a: Float, _ b: Int) -> Float {
        var result: Float = 1.0
        var base = a
        var exp = (b >= 0 ? b : -b)
        while exp > 0 {
            if exp % 2 == 0 {
                base *= base
                exp /= 2
            } else {
                result *= base
                exp -= 1
            }
        }
        if b < 0 {
            return 1.0 / result
        } else {
            return result
        }
    }
    
    ///**
    // * Compute a number of approximation points on the Bezier curve defined by the given control
    // * points. The degree of the curve is derived from the number of control points. The array of
    // * resulting curve points includes the target point, but does not include the source point of
    // * the curve.
    // * 
    // * @param controlPoints
    // *            the control points
    // * @param resultSize
    // *            number of returned curve points
    // * @return points on the curve defined by the given control points
    // */
    package static func approximateBezierSegment(_ resultSize: Int, _ controlPoints: KVector...) -> [KVector] {
        return approximateBezierSegmentArray(resultSize, controlPoints)
    }

    package static func approximateBezierSegmentArray(_ resultSize: Int, _ controlPoints: [KVector]) -> [KVector] {
        if resultSize <= 0 {
            return []
        }
        var result = [KVector]()
        let dt = (1.0 / Double(resultSize))
        var t = 0.0
        for _ in 0..<resultSize {
            t += dt
            result.append(getPointOnBezierSegment(t, controlPoints))
        }
        return result
    }
    
    ///**
    // * Compute a number of approximation points on the Bezier curve defined by the given control
    // * points. The degree of the curve is derived from the number of control points. The array of
    // * resulting curve points includes the target point, but does not include the source point of
    // * the curve. The number of approximation points is derived from the given control points.
    // * 
    // * @param controlPoints
    // *            the control points of the curve
    // * @return points on the curve defined by the given control points
    // */
    package static func approximateBezierSegment(_ controlPoints: KVector...) -> [KVector] {
        // The number of approximation points simply equals the number of control points.
        // Although there might be more accurate approximations, this approach is the fastest.
        let approximationCount = controlPoints.count + 1
        return approximateBezierSegmentArray(approximationCount, controlPoints)
    }
    
    ///**
    // * Compute a point on the Bezier curve defined by the given control points. The value {@code t}
    // * determines the position of the returned point.
    // * 
    // * @param t
    // *            a value between 0 and 1, where 0 is the start point of the curve, and 1 is the
    // *            end point
    // * @param controlPoints
    // *            the control points of the curve
    // * @return the point at position {@code t}
    // */
    package static func getPointOnBezierSegment(_ t: Double, _ controlPoints: [KVector]) -> KVector {
        let n = controlPoints.count - 1
        var px = 0.0
        var py = 0.0
        for j in 0...n {
            let p = controlPoints[j]
            let factor = binomiald(n, j) * powd(1 - t, n - j) * powd(t, j)
            px += p.x * factor
            py += p.y * factor
        }
        return KVector(px, py)
    }
    
    ///**
    // * Compute an approximation for the spline that is defined by the given control points. The
    // * control points are interpreted as a series of cubic Bezier curves.
    // * 
    // * <p><em>Note:</em> As a more powerful alternative, you might consider using
    // * {@link BezierSpline} instead.</p>
    // * 
    // * @param controlPoints
    // *            control points of a piecewise cubic spline
    // * @return a vector chain that approximates the spline
    // */
    package static func approximateBezierSpline(_ controlPoints: KVectorChain) -> KVectorChain {
        let ctrlPtCount = controlPoints.size()
        let spline = KVectorChain()
        let controlIter = controlPoints.listIterator()
        var currentPoint = controlIter.next()
        spline.add(currentPoint)
        while controlIter.hasNext() {
            let remainingPoints = ctrlPtCount - controlIter.nextIndex()
            if remainingPoints == 1 {
                spline.add(controlIter.next())
            } else if remainingPoints == 2 {
                // calculate a quadratic bezier curve
                spline.addAll(approximateBezierSegment(currentPoint, controlIter.next(), controlIter.next()))
            } else {
                // calculate a cubic bezier curve
                let control1 = controlIter.next()
                let control2 = controlIter.next()
                let nextPoint = controlIter.next()
                spline.addAll(approximateBezierSegment(currentPoint, control1, control2, nextPoint))
                currentPoint = nextPoint
            }
        }
        return spline
    }
    
    ///** degree of splines equation to find roots. */
    package static let wDegree = 5
    
    ///**
    // * Calculate the distance from a cubic spline curve to the point {@code needle}.
    // * 
    // * @param start
    // *            starting point
    // * @param c1
    // *            control point 1
    // * @param c2
    // *            control point 2
    // * @param end
    // *            end point
    // * @param needle
    // *            point to look for
    // * @return distance from needle to curve
    // */
    package static func distanceFromBezierSegment(_ start: KVector, _ c1: KVector,
            _ c2: KVector, _ end: KVector, _ needle: KVector) -> Double {
        var tCandidate = [Double](repeating: 0.0, count: wDegree) // possible roots
        let v = [start, c1, c2, end]
        
        // convert problem to 5th-degree Bezier form
        let w = convertToBezierForm(v, needle)
        
        // Find all possible roots of 5th-degree equation
        let nSolutions = findRoots(w, wDegree, &tCandidate, 0)
        
        // Compare distances of P5 to all candidates, and to t=0, and t=1
        // Check distance to beginning of curve, where t = 0
        var minDistance = needle.distance(start)
        var t: Double = 0.0

        // Find distances for candidate points
        for i in 0..<nSolutions {
            var noLeft: [KVector]? = nil
            var noRight: [KVector]? = nil
            let p = bezier(v, 3, tCandidate[i], &noLeft, &noRight)
            let distance = needle.distance(p)
            if distance < minDistance {
                minDistance = distance
                t = tCandidate[i]
            }
        }
        
        // Finally, look at distance to end point, where t = 1.0
        let distance = needle.distance(end)
        if distance < minDistance {
            t = 1.0
        }
        
        // Return the point on the curve at parameter value t
        var noLeft2: [KVector]? = nil
        var noRight2: [KVector]? = nil
        let pn = KVector(bezier(v, 3, t, &noLeft2, &noRight2))
        return sqrt(pn.distance(needle))
    }
    
    ///** cubic Bezier curves. */
    package static let degree = 3
    ///** precomputed "z" for cubics. */
    package static let cubicZ: [[Double]] = [ [1.0, 0.6, 0.3, 0.1], [0.4, 0.6, 0.6, 0.4],
            [0.1, 0.3, 0.6, 1.0], ]
    
    ///**
    // * Given a point and a Bezier curve, generate a 5th-degree Bezier-format equation whose solution
    // * finds the point on the curve nearest the user-defined point.
    // */
    package static func convertToBezierForm(_ v: [KVector], _ pa: KVector) -> [KVector] {
        var c = [KVector](repeating: KVector(0,0), count: degree + 1) // v(i) - pa
        var d = [KVector](repeating: KVector(0,0), count: degree) // v(i+1) - v(i)
        var cdTable = [[Double]](repeating: [Double](repeating: 0.0, count: degree + 1), count: degree) // dot product of c, d
        var w = [KVector](repeating: KVector(0,0), count: wDegree + 1) // ctl pts of 5th-degree curve
        
        // Determine the c's -- these are vectors created by subtracting
        // point pa from each of the control points
        for i in 0...degree {
            c[i] = KVector(v[i].x - pa.x, v[i].y - pa.y)
        }
        
        // Determine the d's -- these are vectors created by subtracting
        // each control point from the next
        let s = Double(degree)
        for i in 0...degree - 1 {
            d[i] = KVector(s * (v[i + 1].x - v[i].x), s * (v[i + 1].y - v[i].y))
        }
        
        // Create the c,d table -- this is a table of dot products of the
        // c's and d's */
        for row in 0...degree - 1 {
            for column in 0...degree {
                cdTable[row][column] = (d[row].x * c[column].x) + (d[row].y * c[column].y)
            }
        }
        
        // Now, apply the z's to the dot products, on the skew diagonal
        // Also, set up the x-values, making these "points"
        for i in 0...wDegree {
            w[i] = KVector(Double(i) / Double(wDegree), 0.0)
        }
        
        let n = degree
        let m = degree - 1
        for k in 0...n + m {
            let lb = max(0, k - m)
            let ub = min(k, n)
            for i in lb...ub {
                let j = k - i
                w[i + j].y = w[i + j].y + cdTable[j][i] * cubicZ[j][i]
            }
        }
        
        return w
    }
    
    ///** maximum depth for recursion. */
    package static let maxDepth = 64
    
    ///**
    // * Given a 5th-degree equation in Bernstein-Bezier form, find all of the roots in the interval
    // * [0, 1].
    // * 
    // * @return the number of roots found.
    // */
    package static func findRoots(_ w: [KVector], _ degree: Int, _ t: inout [Double], _ depth: Int) -> Int {
        switch crossingCount(w, degree) {
        case 0: // No solutions here
            return 0
        case 1: // Unique solution
            // Stop recursion when the tree is deep enough
            // if deep enough, return 1 solution at midpoint
            if depth >= maxDepth {
                t[0] = (w[0].x + w[wDegree].x) / 2.0
                return 1
            }
            if controlPolygonFlatEnough(w, degree) {
                t[0] = computeXIntercept(w, degree)
                return 1
            }
            break
        default:
            break
        }
        
        // Otherwise, solve recursively after subdividing control polygon
        var left: [KVector]? = [KVector](repeating: KVector(0,0), count: wDegree + 1) // New left and right
        var right: [KVector]? = [KVector](repeating: KVector(0,0), count: wDegree + 1) // control polygons
        var leftT = [Double](repeating: 0.0, count: wDegree + 1) // Solutions from kids
        var rightT = [Double](repeating: 0.0, count: wDegree + 1)

        // start in the middle of the bezier curve, t=0.5
        let _ = bezier(w, degree, 1.0 / 2, &left, &right)
        guard let l = left, let r = right else { return 0 }
        let leftCount = findRoots(l, degree, &leftT, depth + 1)
        let rightCount = findRoots(r, degree, &rightT, depth + 1)
        
        // Gather solutions together
        for i in 0..<leftCount {
            t[i] = leftT[i]
        }
        for i in 0..<rightCount {
            t[i + leftCount] = rightT[i]
        }
        
        // Send back total number of solutions */
        return leftCount + rightCount
    }
    
    ///** Flatness. */
    package static let epsilon = 1.0 * pow(2.0, Double(-maxDepth - 1))
    
    ///**
    // * Check if the control polygon of a Bezier curve is flat enough for recursive subdivision to
    // * bottom out.
    // */
    package static func controlPolygonFlatEnough(_ v: [KVector], _ degree: Int) -> Bool {
        
        // Find the perpendicular distance from each interior control point to
        // line connecting v[0] and v[degree]
        
        // Derive the implicit equation for line connecting first
        // and last control points
        let a = v[0].y - v[degree].y
        let b = v[degree].x - v[0].x
        let c = v[0].x * v[degree].y - v[degree].x * v[0].y
        
        let abSquared = (a * a) + (b * b)
        var distance = [Double](repeating: 0.0, count: degree + 1) // Distances from pts to line
        
        for i in 1...degree - 1 {
            // Compute distance from each of the points to that line
            distance[i] = a * v[i].x + b * v[i].y + c
            if distance[i] > 0.0 {
                distance[i] = (distance[i] * distance[i]) / abSquared
            }
            if distance[i] < 0.0 {
                distance[i] = -((distance[i] * distance[i]) / abSquared)
            }
        }
        
        // Find the largest distance
        var maxDistanceAbove = 0.0
        var maxDistanceBelow = 0.0
        for i in 1...degree - 1 {
            if distance[i] < 0.0 {
                maxDistanceBelow = min(maxDistanceBelow, distance[i])
            }
            if distance[i] > 0.0 {
                maxDistanceAbove = max(maxDistanceAbove, distance[i])
            }
        }
        
        // Implicit equation for zero line
        let a1 = 0.0
        let b1 = 1.0
        let c1 = 0.0
        
        // Implicit equation for "above" line
        let a2 = a
        let b2 = b
        let c2 = c + maxDistanceAbove
        
        let det = a1 * b2 - a2 * b1
        let dInv = 1.0 / det
        
        let intercept1 = (b1 * c2 - b2 * c1) * dInv
        
        // Implicit equation for "below" line
        let a2a = a
        let b2a = b
        let c2a = c + maxDistanceBelow
        
        let det2 = a1 * b2a - a2a * b1
        let dInv2 = 1.0 / det2
        
        let intercept2 = (b1 * c2a - b2a * c1) * dInv2
        
        // Compute intercepts of bounding box
        let leftIntercept = min(intercept1, intercept2)
        let rightIntercept = max(intercept1, intercept2)
        
        let error = (rightIntercept - leftIntercept) / 2
        
        return error < epsilon
    }
    
    ///**
    // * Compute intersection of chord from first control point to last with 0-axis.
    // */
    package static func computeXIntercept(_ v: [KVector], _ degree: Int) -> Double {
        let xnm = v[degree].x - v[0].x
        let ynm = v[degree].y - v[0].y
        let xmk = v[0].x
        let ymk = v[0].y
        
        let detInv = -1.0 / ynm
        
        return (xnm * ymk - ynm * xmk) * detInv
    }
    
    ///**
    // * Count the number of times a Bezier control polygon crosses the 0-axis. This number is >= the
    // * number of roots.
    // */
    package static func crossingCount(_ v: [KVector], _ degree: Int) -> Int {
        var nCrossings = 0
        var sign = v[0].y < 0 ? -1 : 1
        var oldSign = sign
        for i in 1...degree {
            sign = v[i].y < 0 ? -1 : 1
            if sign != oldSign {
                nCrossings += 1
            }
            oldSign = sign
        }
        return nCrossings
    }
    
    ///**
    // * Compute bezier curve.
    // * 
    // * @param c
    // *            control points
    // * @param degree
    // *            degree of curve
    // * @param t
    // *            parameter for bezier function
    // */
    package static func bezier(_ c: [KVector], _ degree: Int, _ t: Double,
            _ left: inout [KVector]?, _ right: inout [KVector]?) -> KVector {
        var p = [[KVector]](repeating: [KVector](repeating: KVector(0,0), count: wDegree + 1), count: wDegree + 1)

        for j in 0...degree {
            p[0][j] = KVector(c[j])
        }

        for i in 1...degree {
            for j in 0...degree - i {
                let newX = (1.0 - t) * p[i - 1][j].x + t * p[i - 1][j + 1].x
                let newY = (1.0 - t) * p[i - 1][j].y + t * p[i - 1][j + 1].y
                p[i][j] = KVector(newX, newY)
            }
        }

        if left != nil {
            for j in 0...degree {
                left?[j] = p[j][0]
            }
        }

        if right != nil {
            for j in 0...degree {
                right?[j] = p[degree - j][j]
            }
        }
        return p[degree][0]
    }
    
    ///**
    // * Determines the maximum for an arbitrary number of integers.
    // * 
    // * @param values
    // *            integer values
    // * @return the maximum of the given values, or {@code MIN_VALUE} if no values are given
    // */
    package static func maxi(_ values: Int...) -> Int {
        var max = Int.min
        for i in 0..<values.count {
            if values[i] > max {
                max = values[i]
            }
        }
        return max
    }
    
    ///**
    // * Determines the minimum for an arbitrary number of integers.
    // * 
    // * @param values
    // *            integer values
    // * @return the minimum of the given values, or {@code MAX_VALUE} if no values are given
    // */
    package static func mini(_ values: Int...) -> Int {
        var min = Int.max
        for i in 0..<values.count {
            if values[i] < min {
                min = values[i]
            }
        }
        return min
    }
    
    ///**
    // * Determines the average for an arbitrary number of integers.
    // * 
    // * @param values
    // *            integer values
    // * @return the average of the given values
    // */
    package static func averagei(_ values: Int...) -> Int {
        var avg = 0
        for i in 0..<values.count {
            avg += values[i]
        }
        return avg / values.count
    }
    
    ///**
    // * Determines the maximum for an arbitrary number of long integers.
    // * 
    // * @param values
    // *            integer values
    // * @return the maximum of the given values, or {@code MIN_VALUE} if no values are given
    // */
    package static func maxl(_ values: Int64...) -> Int64 {
        var max = Int64.min
        for i in 0..<values.count {
            if values[i] > max {
                max = values[i]
            }
        }
        return max
    }
    
    ///**
    // * Determines the minimum for an arbitrary number of long integers.
    // * 
    // * @param values
    // *            integer values
    // * @return the minimum of the given values, or {@code MAX_VALUE} if no values are given
    // */
    package static func minl(_ values: Int64...) -> Int64 {
        var min = Int64.max
        for i in 0..<values.count {
            if values[i] < min {
                min = values[i]
            }
        }
        return min
    }
    
    ///**
    // * Determines the average for an arbitrary number of long integers.
    // * 
    // * @param values
    // *            integer values
    // * @return the average of the given values
    // */
    package static func averagel(_ values: Int64...) -> Int64 {
        var avg: Int64 = 0
        for i in 0..<values.count {
            avg += values[i]
        }
        return avg / Int64(values.count)
    }
    
    ///**
    // * Determines the maximum for an arbitrary number of floats.
    // * 
    // * @param values
    // *            float values
    // * @return the maximum of the given values, or {@code -MAX_VALUE} if no values are given
    // */
    package static func maxf(_ values: Float...) -> Float {
        var max = -Float.greatestFiniteMagnitude
        for i in 0..<values.count {
            if values[i] > max {
                max = values[i]
            }
        }
        return max
    }
    
    ///**
    // * Determines the minimum for an arbitrary number of floats.
    // * 
    // * @param values
    // *            float values
    // * @return the minimum of the given values, or {@code MAX_VALUE} if no values are given
    // */
    package static func minf(_ values: Float...) -> Float {
        var min = Float.greatestFiniteMagnitude
        for i in 0..<values.count {
            if values[i] < min {
                min = values[i]
            }
        }
        return min
    }
    
    ///**
    // * Determines the average for an arbitrary number of floats.
    // * 
    // * @param values
    // *            float values
    // * @return the average of the given values
    // */
    package static func averagef(_ values: Float...) -> Float {
        var avg: Float = 0
        for i in 0..<values.count {
            avg += values[i]
        }
        return avg / Float(values.count)
    }
    
    ///**
    // * Determines the maximum for an arbitrary number of doubles.
    // * 
    // * @param values
    // *            double values
    // * @return the maximum of the given values, or {@code -MAX_VALUE} if no values are given
    // */
    package static func maxd(_ values: Double...) -> Double {
        var max = -Double.greatestFiniteMagnitude
        for i in 0..<values.count {
            if values[i] > max {
                max = values[i]
            }
        }
        return max
    }
    
    ///**
    // * Determines the minimum for an arbitrary number of doubles.
    // * 
    // * @param values
    // *            double values
    // * @return the minimum of the given values, or {@code MAX_VALUE} if no values are given
    // */
    package static func mind(_ values: Double...) -> Double {
        var min = Double.greatestFiniteMagnitude
        for i in 0..<values.count {
            if values[i] < min {
                min = values[i]
            }
        }
        return min
    }
    
    ///**
    // * Determines the average for an arbitrary number of doubles.
    // * 
    // * @param values
    // *            double values
    // * @return the average of the given values
    // */
    package static func averaged(_ values: Double...) -> Double {
        var avg: Double = 0
        for i in 0..<values.count {
            avg += values[i]
        }
        return avg / Double(values.count)
    }
    
    ///**
    // * Limit the given integer to a specific range.
    // * 
    // * @param x an integer value
    // * @param lower the lower limit
    // * @param upper the upper limit
    // * @return if x is beyond the limits, return the limit, otherwise just return x
    // */
    package static func boundi(_ x: Int, _ lower: Int, _ upper: Int) -> Int {
        if x <= lower {
            return lower
        } else if x >= upper {
            return upper
        }
        return x
    }
    
    ///**
    // * Limit the given long to a specific range.
    // * 
    // * @param x an long value
    // * @param lower the lower limit
    // * @param upper the upper limit
    // * @return if x is beyond the limits, return the limit, otherwise just return x
    // */
    package static func boundl(_ x: Int64, _ lower: Int64, _ upper: Int64) -> Int64 {
        if x <= lower {
            return lower
        } else if x >= upper {
            return upper
        }
        return x
    }
    
    ///**
    // * Limit the given float to a specific range.
    // * 
    // * @param x a float value
    // * @param lower the lower limit
    // * @param upper the upper limit
    // * @return if x is beyond the limits, return the limit, otherwise just return x
    // */
    package static func boundf(_ x: Float, _ lower: Float, _ upper: Float) -> Float {
        if x <= lower {
            return lower
        } else if x >= upper {
            return upper
        }
        return x
    }
    
    ///**
    // * Limit the given double to a specific range.
    // * 
    // * @param x a double value
    // * @param lower the lower limit
    // * @param upper the upper limit
    // * @return if x is beyond the limits, return the limit, otherwise just return x
    // */
    package static func boundd(_ x: Double, _ lower: Double, _ upper: Double) -> Double {
        if x <= lower {
            return lower
        } else if x >= upper {
            return upper
        }
        return x
    }
    
    ///**
    // * Clip the given vector to a rectangular box of given size.
    // * 
    // * @param v vector relative to the center of the box
    // * @param width width of the rectangular box
    // * @param height height of the rectangular box
    // * 
    // * @return {@code v}.
    // */
    package static func clipVector(_ v: KVector, _ width: Double, _ height: Double) -> KVector {
        let wh = width / 2, hh = height / 2
        let absx = abs(v.x), absy = abs(v.y)
        var xscale = 1.0, yscale = 1.0
        if absx > wh {
            xscale = wh / absx
        }
        if absy > hh {
            yscale = hh / absy
        }
        v.scale(min(xscale, yscale))
        return v
    }
    
    ///**
    // * Returns the signum function of the specified <tt>double</tt> value. The return value
    // * is -1 if the specified value is negative; 0 if the specified value is zero; and 1 if the
    // * specified value is positive. This is basically {@link Math#signum(double)} with an integer
    // * return value.
    // *
    // * @return the signum function of the specified <tt>double</tt> value.
    // */
    package static func signum(_ x: Double) -> Int {
        if x < 0 {
            return -1
        }
        if x > 0 {
            return 1
        }
        return 0
    }
    
    ///**
    // * Checks whether any of the four borders of {@code rect} intersects with any of the straight line segments of the
    // * closed {@code path = p_1,...,p_n}. Also checks the closing segment {@code (p_n, p_1)}. If the path contains less
    // * than two points, {@code false} is returned. If {@code rect} fully contains the shape, no intersection is assumed.
    // * 
    // * @param rect
    // * @param path
    // *            a {@link KVectorChain} describing a closed path of straight line segments.
    // * @return {@code true} if {@code rect} intersects {@code path}, {@code false} otherwise.
    // */
    package static func intersects(_ rect: ElkRectangle, _ path: KVectorChain) -> Bool {
        if path.size() < 2 {
            return false
        }
        
        var pathIt = path.makeIterator()
        guard let first = pathIt.next() else { return false }
        var p1 = first
        // check every segment
        while let p2 = pathIt.next() {
            if intersects(rect, p1, p2) {
                return true
            }
            p1 = p2
        }
        // check the closing segment
        if intersects(rect, p1, first) {
            return true
        }

        return false
    }

    ///**
    // * Checks whether the straight line {@code l} defined by {@code (p1, p2)} intersects with at least one of the four
    // * segments defining the passed rectangle. If {@code l} is fully contained within {@code rect}'s bounding box, no
    // * intersection assumed. If the line is parallel to, and lies on, one of the four borders, no intersection is
    // * assumed.
    // * 
    // * @param rect
    // * @param p1
    // *            start point of a line
    // * @param p2
    // *            end point of a line
    // * @return {@code true} if {@code (p1, p2)} intersects with {@code rect}, {@code false} otherwise.
    // */
    package static func intersects(_ rect: ElkRectangle, _ p1: KVector, _ p2: KVector) -> Bool {
        // simple cases first: fully contained
        if contains(rect, p1, p2) {
            return false
        }
        // leaves the cases
        //  - where one point is inside and the other outside (don't use contains here, as point on border is 'outside')
        //  - where both points are outside
        // for that, check if (p1, p2) intersects with one of rect's borders
        return intersects(rect.getTopLeft(), rect.getTopRight(), p1, p2) 
            || intersects(rect.getTopRight(), rect.getBottomRight(), p1, p2)
            || intersects(rect.getBottomRight(), rect.getBottomLeft(), p1, p2)
            || intersects(rect.getBottomLeft(), rect.getTopLeft(), p1, p2)
    }
    
    ///**
    // * Double computations are potentially imprecise, we need a robust way of checking if a value is zero in
    // * {@link #intersects(KVector, KVector, KVector, KVector)}, which is done using an epsilon comparison.
    // * Note that other algorithms may use this epsilon and depend on its value being no less than 0.00001.
    // */
    package static let doubleEqEpsilon = 0.00001
    
    ///**
    // * Detects intersection of the two passed lines {@code (l11, l12)} and {@code (l21, l22)}.
    // * 
    // * <p>
    // * Implementation based on https://stackoverflow.com/questions/4977491/determining-if-two-line-segments-intersect.
    // * See also https://en.wikipedia.org/wiki/Line%E2%80%93line_intersection#Mathematics.
    // * </p>
    // * 
    // * @see ElkMath#intersects2(KVector, KVector, KVector, KVector)
    // * @param l11
    // *            start point of first line
    // * @param l12
    // *            end point of first line
    // * @param l21
    // *            start point of second line
    // * @param l22
    // *            end point of second line
    // * @return {@code true} if the two lines intersect, {@code false} otherwise. In particular, if the start or end
    // *         point of one of the lines only "touches" the other line, no intersection is assumed.
    // */
    package static func intersects(_ l11: KVector, _ l12: KVector, _ l21: KVector, _ l22: KVector) -> Bool {
        let u0 = l11
        let v0 = l12.clone().sub(l11)
        let u1 = l21
        let v1 = l22.clone().sub(l21)
        let x00 = u0.x, y00 = u0.y
        let x10 = u1.x, y10 = u1.y
        let x01 = v0.x, y01 = v0.y
        let x11 = v1.x, y11 = v1.y
        
        let d = x11 * y01 - x01 * y11
        if abs(d) < doubleEqEpsilon {
            return false
        }
        let s = (1 / d) * ((x00 - x10) * y01 - (y00 - y10) * x01)
        let t = (1 / d) * -(-(x00 - x10) * y11 + (y00 - y10) * x11)
        // System.out.println("d: " + d + ", s: " + s + ", t: " + t);
        
        // use < instead of <= to not recognize "touching" as intersection
        let intersects =
                // 0 < s
                s > doubleEqEpsilon
                // s < 1
                && s < 1 - doubleEqEpsilon
                // 0 < t
                && t > doubleEqEpsilon
                // t < 1
                && t < 1 - doubleEqEpsilon
        return intersects
    }
    
    ///**
    // * Returns the intersection point of two line segments.
    // * 
    // * <p>
    // * Approach by Ronald Goldman "Intersection of two lines in three-space"
    // * <p>
    // * The segments are defined as {@code p+t*r} and {@code q+u*s} with {@code 0 <= t,u <= 1}.
    // * If the line segments are collinear and overlapping there is not a single intersection point, so of
    // * the possible points the closest to the center of the second segment is returned.
    // * 
    // * @see ElkMath#intersects(KVector, KVector, KVector, KVector)
    // * @param p
    // * @param r
    // * @param q
    // * @param s
    // * @return the point of intersection or null if none exists
    // */
    package static func intersects2(_ p: KVector, _ r: KVector, _ q: KVector, _ s: KVector) -> KVector? {
        let pq = q.clone().sub(p)
        let pqXr = KVector.crossProduct(pq, r)
        let rXs = KVector.crossProduct(r, s)
        let t = KVector.crossProduct(pq, s) / rXs
        let u = pqXr / rXs
        if rXs == 0 {
            if pqXr == 0 { // segments are collinear: return point closest to center of s
                // CHECKSTYLEOFF MagicNumber
                let center = q.clone().add(s.clone().scale(0.5))
                let d1 = p.distance(center)
                let d2 = p.clone().add(r).distance(center)
                let l = s.length() * 0.5
                // CHECKSTYLEON MagicNumber
                if d1 < d2 && d1 <= l {
                    return p.clone()
                }
                if d2 <= l {
                    return p.clone().add(r)
                }
                return nil
            } else { // segments are parallel
                return nil
            }
        } else {
            if t >= 0 && t <= 1 && u >= 0 && u <= 1 { // segments intersect
                return p.clone().add(r.clone().scale(t))
            } else { // segments don't intersect
                return nil
            }
        }
    }
    
    ///**
    // * Returns the distance between the line segments given by {@code (a1,a2)} and {@code (b1,b2)}.
    // * The distance is measured in the direction specified by vector {@code v} starting at segment {@code b}.
    // * If the segments are oriented or spaced such that {@code v} cannot reach one segment from the other, 
    // * {@code Double.POSITIVE_INFINITY} is returned.
    // * 
    // * @param a1 start point of first line segment
    // * @param a2 end point of first line segment
    // * @param b1 start point of second line segment
    // * @param b2 end point of second line segment
    // * @param v direction
    // * @return direction dependent distance between two line segments
    // */
    package static func distance(_ a1: KVector, _ a2: KVector, _ b1: KVector, _ b2: KVector, 
            _ v: KVector) -> Double {
        
        return min(traceRays(a1, a2, b1, b2, v), 
                        traceRays(b1, b2, a1, a2, v.clone().negate()))
    }
    
    ///**
    // * Traces rays from the endpoints of line segment {@code b=(b1, b2)} in the direction {@code v} and 
    // * with the length of {@code v}.
    // * The rays' intersections with {@code a} yield the distance between {@code a} and {@code b}.
    // * 
    // * @param a1 start point of segment a
    // * @param a2 end point of segment a
    // * @param b1 start point of segment b
    // * @param b2 end point of segment b
    // * @param v the direction
    // * @return the distance between {@code a} and {@code b} in direction {@code v} or infinity
    // */
    package static func traceRays(_ a1: KVector, _ a2: KVector, _ b1: KVector, _ b2: KVector, 
            _ v: KVector) -> Double {
        var result = Double.greatestFiniteMagnitude
        var intersection: KVector?
        var endpointHit = false
        
        // check whether (b + v) intersects a to catch an edge case, where one ray exactly hits an endpoint
        // of a but the other ray is too short to reach a.
        intersection = intersects2(a1, a2.clone().sub(a1), b1.clone().add(v), b2.clone().sub(b1))
        let edgeCase: Bool
        if let inter = intersection {
            edgeCase = !(inter.equalsFuzzily(a1) || inter.equalsFuzzily(a2))
        } else {
            edgeCase = false
        }

        // trace ray from point b1 to segment a in direction v
        intersection = intersects2(a1, a2.clone().sub(a1), b1, v)
        if let inter = intersection {
            if inter.equalsFuzzily(a1) == inter.equalsFuzzily(a2) || edgeCase {
                // update the distance result
                result = min(result, inter.sub(b1).length())
            } else {
                // ignore intersection if the ray exactly hits an endpoint of b
                // but track it to allow it only for one ray per segment
                endpointHit = true
            }
        }

        // trace ray from point b2 to segment a in direction v
        intersection = intersects2(a1, a2.clone().sub(a1), b2, v)
        if let inter = intersection {
            if endpointHit || inter.equalsFuzzily(a1) == inter.equalsFuzzily(a2) || edgeCase {
                // update the distance result
                result = min(result, inter.sub(b2).length())
            }
        }
        
        return result
    }
    
    ///**
    // * Checks whether every straight line segment of the path {@code p_1,...,p_n} 
    // * is fully contained within {@code rect}. Also checks the closing segment {@code (p_n, p_1)}.
    // * If the path contains less than two points, {@code false} is returned.
    // * 
    // * @param rect
    // * @param path a {@link KVectorChain} describing a closed path of straight line segments. 
    // * @return {@code true} if {@code rect} fully contains {@code path}, {@code false} otherwise.
    // */
    package static func contains(_ rect: ElkRectangle, _ path: KVectorChain) -> Bool {
        if path.size() < 2 {
            return false
        }
        
        var pathIt = path.makeIterator()
        guard let first = pathIt.next() else { return false }
        var p1 = first
        // check every segment
        while let p2 = pathIt.next() {
            if !contains(rect, p1, p2) {
                return false
            }
            p1 = p2
        }
        // check the closing segment
        if !contains(rect, p1, first) {
            return false
        }

        return true
    }
    
    ///**
    // * Check whether {@code rect} fully contains the straight line {@code l} defined by {@code (p1, p2)}. That is, 
    // * it is checked if both {@code p1} and {@code p2} lie within the bounding box of {@code rect}. If one of the 
    // * two points lies on the border of {@code rect}, the line is considered to be <em>not</em> contained. 
    // * 
    // * @param rect
    // * @param p1 start point of a line 
    // * @param p2 end point of a line
    // * @return {@code true} if {@code rect} fully contains {@code (p1, p2)}, {@code false} otherwise.
    // */
    package static func contains(_ rect: ElkRectangle, _ p1: KVector, _ p2: KVector) -> Bool {
        return contains(rect, p1) && contains(rect, p2)        
    }
    
    ///**
    // * Check whether {@code rect} contains the point {@code p}. That is, it is checked if {@code p} lies within the
    // * bounding box of {@code rect}. If the point lies on the border of {@code rect}, the line is considered to be
    // * <em>not</em> contained.
    // * 
    // * @param rect
    // * @param p
    // * @return {@code true} if {@code rect} contains {@code p1}, {@code false} otherwise.
    // */
    package static func contains(_ rect: ElkRectangle, _ p: KVector) -> Bool {
        let minX = rect.x
        let maxX = rect.x + rect.width
        let minY = rect.y
        let maxY = rect.y + rect.height
        
        return (p.x > minX && p.x < maxX) && (p.y > minY && p.y < maxY)     
    }
    
    ///**
    // * Calculates shortest distance between two axis aligned rectangles.
    // * If they intersect the returned distance becomes negative.
    // * There are three cases to consider:
    // * 1.
    // *              +----+
    // *    +----+....| r2 |
    // *    | r1 |    +----+
    // *    +----+
    // *    
    // * 2.
    // *              +----+
    // *              | r2 |
    // *             .+----+
    // *           .
    // *    +----+
    // *    | r1 |   
    // *    +----+
    // *    
    // * 3. 
    // *
    // *        +----+
    // *    +---|+r2 |
    // *    | r1+|---+   
    // *    +----+
    // *    
    // * In the first case the result is the axis aligned distance between the closest sides
    // * and in the other cases it's the euclidean distance between the closest corners.
    // * @param r1
    // * @param r2
    // * @return shortest distance between r1 and r2
    // */
    package static func shortestDistance(_ r1: ElkRectangle, _ r2: ElkRectangle) -> Double {
        let rightDist = r2.x - (r1.x + r1.width)
        let leftDist = r1.x - (r2.x + r2.width)
        let topDist = r1.y - (r2.y + r2.height)
        let bottomDist = r2.y - (r1.y + r1.height)
        let horzDist = max(leftDist, rightDist)
        let vertDist = max(topDist, bottomDist)
        if (horzDist >= doubleEqEpsilon) != (vertDist >= doubleEqEpsilon) { // case 1
            return max(vertDist, horzDist)
        }
        if horzDist > doubleEqEpsilon { // case 2
            return sqrt(vertDist * vertDist + horzDist * horzDist)
        }
        // case 3
        return -sqrt(vertDist * vertDist + horzDist * horzDist)
    }
    
}
