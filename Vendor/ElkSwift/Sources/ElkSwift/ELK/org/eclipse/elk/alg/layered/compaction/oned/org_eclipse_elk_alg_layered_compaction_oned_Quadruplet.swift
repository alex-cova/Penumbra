import Foundation

/**
 * Internal class representing a 4-tuple that, in one application as a 'compaction lock', states for
 * a `CNode` if the compaction should be locked in a particular direction.
 */
package final class Quadruplet {
    
    // SUPPRESS CHECKSTYLE NEXT 2 VisibilityModifier
    /** Locking values. */
    package var left: Bool = false
    package var right: Bool = false
    package var up: Bool = false
    package var down: Bool = false

    /**
     * The lock defaults to false.
     */
    package init() {}

    /**
     * This constructor initializes the lock.
     */
    package init(_ l: Bool, _ r: Bool, _ u: Bool, _ d: Bool) {
        left = l
        right = r
        up = u
        down = d
    }
    
    /**
     * Sets the lock.
     *
     * - Parameters:
     *   - l: left
     *   - r: right
     *   - u: up
     *   - d: down
     */
    package func set(_ l: Bool, _ r: Bool, _ u: Bool, _ d: Bool) {
        left = l
        right = r
        up = u
        down = d
    }
    
    /**
     * Sets the lock in a specific `Direction`.
     *
     * - Parameters:
     *   - value: the desired state
     *   - direction: the `Direction` of compaction
     */
    package func set(_ value: Bool, direction: Direction) {
        switch direction {
        case .LEFT:
            left = value
        case .RIGHT:
            right = value
        case .UP:
            up = value
        case .DOWN:
            down = value
        default:
            break
        }
    }

    /**
     * Returns the state for a `Direction`.
     *
     * - Parameter direction: the `Direction`
     * - Returns: the state
     */
    package func get(direction: Direction) -> Bool {
        switch direction {
        case .LEFT:
            return left
        case .RIGHT:
            return right
        case .UP:
            return up
        case .DOWN:
            return down
        default:
            return false
        }
    }
}
