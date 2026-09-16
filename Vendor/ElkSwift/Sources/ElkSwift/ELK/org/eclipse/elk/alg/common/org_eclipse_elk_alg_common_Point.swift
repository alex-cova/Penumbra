import Foundation

/**
 * A very special point, used by the `RectilinearConvexHull` algorithm.
 */
package struct Point: Hashable, Equatable {
    
    // SUPPRESS CHECKSTYLE NEXT 10 VisibilityModifier
    /// The x coordinate.
    package var x: Double
    /// The y coordinate.
    package var y: Double
    
    /// The quadrant this point is located in.
    package var quadrant: Quadrant?
    /// Whether the point represents a convex point in the rectilinear convex hull.
    package var convex = true
    
    /**
     * Constructs a new point.
     *
     * - Parameters:
     *   - x: x coordinate
     *   - y: y coordinate
     */
    package init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    
    /**
     * Constructs a new point with is associated with a quadrant.
     *
     * - Parameters:
     *   - x: x coordinate
     *   - y: y coordinate
     *   - quadrant: one of Q1 to Q4
     */
    package init(x: Double, y: Double, quadrant: Quadrant) {
        self.init(x: x, y: y)
        self.quadrant = quadrant
    }
    
    /**
     * - Parameter v: a `KVector`
     * - Returns: for the passed vector v returns a new point (v.x, v.y)
     */
    package static func from(_ v: KVector) -> Point {
        return Point(x: v.x, y: v.y)
    }
    
    package var description: String {
        return "(\(x), \(y)\(convex ? "cx" : "")\(quadrant?.rawValue ?? ""))"
    }
    
    package static func == (lhs: Point, rhs: Point) -> Bool {
        return lhs.x == rhs.x && lhs.y == rhs.y
    }
    
    package func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
    
    /**
     * Represents a quadrant of a plane split into four parts.
     *
     * ```
     *  Q1 | Q2
     * ---------
     *  Q4 | Q3
     * ```
     */
    package enum Quadrant: String {
        // SUPPRESS CHECKSTYLE NEXT 30 Javadoc
        // order important!
        case Q1, Q4, Q2, Q3
        
        package func isUpper() -> Bool {
            return self == .Q1 || self == .Q2
        }

        package func isLeft() -> Bool {
            return self == .Q1 || self == .Q4
        }
        
        /**
         * - Returns: true if both q1 and q2 are either located in Q1 and Q4 or are located in Q2 and Q3.
         */
        package static func isBothLeftOrBothRight(_ q1: Quadrant, _ q2: Quadrant) -> Bool {
            return (q1 == .Q1 && q2 == .Q4)
                || (q1 == .Q4 && q2 == .Q1)
                || (q1 == .Q3 && q2 == .Q2)
                || (q1 == .Q2 && q2 == .Q3)
        }
        
        /**
         * - Returns: true if one of q1 and q2 is located in Q1 or Q4 and the other one is located in Q2 or Q3.
         */
        package static func isOneLeftOneRight(_ q1: Quadrant, _ q2: Quadrant) -> Bool {
            return (q1 == .Q1 && q2 == .Q2)
                || (q1 == .Q1 && q2 == .Q3)
                || (q1 == .Q4 && q2 == .Q3)
                || (q1 == .Q4 && q2 == .Q2)
        }
    }
}

// Placeholder for KVector since it's referenced but not defined in the input
