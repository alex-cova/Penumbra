import Foundation

/**
 * Internal Class for tolerance affected double comparisons.
 */
package final class CompareFuzzy {
    package static let tolerance: Double = 0.0001
    
    private init() {}
    
    // SUPPRESS CHECKSTYLE NEXT 20 Javadoc
    package static func eq(_ d1: Double, _ d2: Double) -> Bool {
        return abs(d1 - d2) <= tolerance
    }
    
    package static func gt(_ d1: Double, _ d2: Double) -> Bool {
        return d1 - d2 > tolerance
    }
    
    package static func lt(_ d1: Double, _ d2: Double) -> Bool {
        return d2 - d1 > tolerance
    }
    
    package static func ge(_ d1: Double, _ d2: Double) -> Bool {
        return d1 >= d2 - tolerance
    }
    
    package static func le(_ d1: Double, _ d2: Double) -> Bool {
        return d1 <= d2 + tolerance
    }
}
