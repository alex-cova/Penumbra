import Foundation

/**
 * Definition of layout directions. To be accessed using `CoreOptions.DIRECTION`.
 */
package enum Direction: String, AnyEnum {
    /// undefined layout direction.
    case UNDEFINED
    /// rightward horizontal layout.
    case RIGHT
    /// leftward horizontal layout.
    case LEFT
    /// downward vertical layout.
    case DOWN
    /// upward vertical layout.
    case UP

    // Lowercase aliases for compatibility
    package static var undefined: Direction { .UNDEFINED }
    package static var right: Direction { .RIGHT }
    package static var left: Direction { .LEFT }
    package static var down: Direction { .DOWN }
    package static var up: Direction { .UP }

    // Polyomino cardinal direction aliases
    package static var NORTH: Direction { .UP }
    package static var SOUTH: Direction { .DOWN }
    package static var EAST: Direction { .RIGHT }
    package static var WEST: Direction { .LEFT }

    /**
     * Checks if this layout direction is horizontal. (that is, left or right) An undefined layout
     * direction is not horizontal.
     *
     * - Returns: `true` if the layout direction is horizontal.
     */
    package func isHorizontal() -> Bool {
        switch self {
        case .LEFT, .RIGHT:
            return true
        default:
            return false
        }
    }

    /**
     * Checks if this layout direction is vertical. (that is, up or down) An undefined layout
     * direction is not vertical.
     *
     * - Returns: `true` if the layout direction is vertical.
     */
    package func isVertical() -> Bool {
        switch self {
        case .UP, .DOWN:
            return true
        default:
            return false
        }
    }

    /**
     * Returns the opposite direction of `self`. For instance, if `self` is `.LEFT`,
     * returns `.RIGHT`.
     */
    package func opposite() -> Direction {
        switch self {
        case .LEFT:
            return .RIGHT
        case .RIGHT:
            return .LEFT
        case .UP:
            return .DOWN
        case .DOWN:
            return .UP
        case .UNDEFINED:
            return .UNDEFINED
        }
    }
}
