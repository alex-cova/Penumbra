import Foundation

/**
 * Utility `Comparable` implementations that can be used to specify exclusive upper and lower
 * bounds for layout options. For instance, a layout option whose values may be in the range (0, 1)
 * could be specified with the lower bound `greaterThan(0)` and the upper bound `lessThan(1)`.
 * 
 * <p>For inclusive bounds, you can simply use the numbers themselves as lower and upper bounds.</p>
 */
package struct ExclusiveBounds {
    
    /**
     * Create a lower bound that does not include the limit.
     * 
     * @param exclusiveLowerBound the lower bound
     * @return a comparable that excludes the given lower bound
     */
    package static func greaterThan(_ exclusiveLowerBound: Double) -> ExclusiveLowerBound {
        return ExclusiveLowerBound(exclusiveLowerBound)
    }
    
    /**
     * Lower bound that does not include the limit.
     */
    package struct ExclusiveLowerBound: Comparable, CustomStringConvertible {
        
        package let exclusiveLowerBound: Double
        
        /**
         * Create an exclusive lower bound.
         */
        package init(_ exclusiveLowerBound: Double) {
            self.exclusiveLowerBound = exclusiveLowerBound
        }

        package static func < (lhs: ExclusiveLowerBound, rhs: ExclusiveLowerBound) -> Bool {
            return lhs.exclusiveLowerBound < rhs.exclusiveLowerBound
        }
        
        package static func == (lhs: ExclusiveLowerBound, rhs: ExclusiveLowerBound) -> Bool {
            return lhs.exclusiveLowerBound == rhs.exclusiveLowerBound
        }
        
        package func compare(_ other: Number) -> ComparisonResult {
            if exclusiveLowerBound < other.doubleValue {
                return .orderedAscending
            } else {
                return .orderedDescending
            }
        }
        
        package var description: String {
            return "\(exclusiveLowerBound) (exclusive)"
        }
        
    }
    
    /**
     * Create an upper bound that does not include the limit.
     * 
     * @param exclusiveUpperBound the upper bound
     * @return a comparable that excludes the given upper bound
     */
    package static func lessThan(_ exclusiveUpperBound: Double) -> ExclusiveUpperBound {
        return ExclusiveUpperBound(exclusiveUpperBound)
    }
    
    /**
     * Upper bound that does not include the limit.
     */
    package struct ExclusiveUpperBound: Comparable, CustomStringConvertible {
        
        package let exclusiveUpperBound: Double
        
        /**
         * Create an exclusive upper bound.
         */
        package init(_ exclusiveUpperBound: Double) {
            self.exclusiveUpperBound = exclusiveUpperBound
        }

        package static func < (lhs: ExclusiveUpperBound, rhs: ExclusiveUpperBound) -> Bool {
            return lhs.exclusiveUpperBound < rhs.exclusiveUpperBound
        }
        
        package static func == (lhs: ExclusiveUpperBound, rhs: ExclusiveUpperBound) -> Bool {
            return lhs.exclusiveUpperBound == rhs.exclusiveUpperBound
        }
        
        package func compare(_ other: Number) -> ComparisonResult {
            if exclusiveUpperBound > other.doubleValue {
                return .orderedAscending
            } else {
                return .orderedDescending
            }
        }
        
        package var description: String {
            return "\(exclusiveUpperBound) (exclusive)"
        }
        
    }

}

// Extension to support Number comparison
extension Number {
    package var doubleValue: Double {
        if let value = self as? Double {
            return value
        } else if let value = self as? Float {
            return Double(value)
        } else if let value = self as? Int {
            return Double(value)
        } else if let value = self as? Int64 {
            return Double(value)
        } else if let value = self as? Int32 {
            return Double(value)
        } else if let value = self as? Int16 {
            return Double(value)
        } else if let value = self as? Int8 {
            return Double(value)
        } else if let value = self as? UInt64 {
            return Double(value)
        } else if let value = self as? UInt32 {
            return Double(value)
        } else if let value = self as? UInt16 {
            return Double(value)
        } else if let value = self as? UInt8 {
            return Double(value)
        } else {
            return 0.0
        }
    }
}
