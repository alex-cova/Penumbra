import Foundation

/**
 * Definition of port sides on a node.
 */
package enum PortSide: String, Hashable {
    case UNDEFINED
    case NORTH
    case EAST
    case SOUTH
    case WEST

    // Lowercase aliases for compatibility
    package static var undefined: PortSide { .UNDEFINED }
    package static var north: PortSide { .NORTH }
    package static var east: PortSide { .EAST }
    package static var south: PortSide { .SOUTH }
    package static var west: PortSide { .WEST }

    // Port Side Combinations
    package static let SIDES_NONE: Set<PortSide> = []
    package static let SIDES_NORTH: Set<PortSide> = [.NORTH]
    package static let SIDES_EAST: Set<PortSide> = [.EAST]
    package static let SIDES_SOUTH: Set<PortSide> = [.SOUTH]
    package static let SIDES_WEST: Set<PortSide> = [.WEST]
    package static let SIDES_NORTH_SOUTH: Set<PortSide> = [.NORTH, .SOUTH]
    package static let SIDES_EAST_WEST: Set<PortSide> = [.EAST, .WEST]
    package static let SIDES_NORTH_WEST: Set<PortSide> = [.NORTH, .WEST]
    package static let SIDES_NORTH_EAST: Set<PortSide> = [.NORTH, .EAST]
    package static let SIDES_SOUTH_WEST: Set<PortSide> = [.SOUTH, .WEST]
    package static let SIDES_EAST_SOUTH: Set<PortSide> = [.EAST, .SOUTH]
    package static let SIDES_NORTH_EAST_WEST: Set<PortSide> = [.NORTH, .EAST, .WEST]
    package static let SIDES_EAST_SOUTH_WEST: Set<PortSide> = [.EAST, .SOUTH, .WEST]
    package static let SIDES_NORTH_SOUTH_WEST: Set<PortSide> = [.NORTH, .SOUTH, .WEST]
    package static let SIDES_NORTH_EAST_SOUTH: Set<PortSide> = [.NORTH, .EAST, .SOUTH]
    package static let SIDES_NORTH_EAST_SOUTH_WEST: Set<PortSide> = [.NORTH, .EAST, .SOUTH, .WEST]

    package func right() -> PortSide {
        switch self {
        case .NORTH: return .EAST
        case .EAST: return .SOUTH
        case .SOUTH: return .WEST
        case .WEST: return .NORTH
        case .UNDEFINED: return .UNDEFINED
        }
    }

    package func left() -> PortSide {
        switch self {
        case .NORTH: return .WEST
        case .EAST: return .NORTH
        case .SOUTH: return .EAST
        case .WEST: return .SOUTH
        case .UNDEFINED: return .UNDEFINED
        }
    }

    package func opposed() -> PortSide {
        switch self {
        case .NORTH: return .SOUTH
        case .EAST: return .WEST
        case .SOUTH: return .NORTH
        case .WEST: return .EAST
        case .UNDEFINED: return .UNDEFINED
        }
    }

    package func areAdjacent(_ other: PortSide) -> Bool {
        if self == .UNDEFINED { return false }
        return self.left() == other || self.right() == other
    }

    package static func fromDirection(_ direction: Direction) -> PortSide {
        switch direction {
        case .UP: return .NORTH
        case .RIGHT: return .EAST
        case .DOWN: return .SOUTH
        case .LEFT: return .WEST
        default: return .UNDEFINED
        }
    }

    package static func isVertical(_ side: PortSide) -> Bool {
        return side == .NORTH || side == .SOUTH
    }

    package static func isHorizontal(_ side: PortSide) -> Bool {
        return side == .WEST || side == .EAST
    }

    package func isVertical() -> Bool {
        return PortSide.isVertical(self)
    }

    package func isHorizontal() -> Bool {
        return PortSide.isHorizontal(self)
    }

    /// Returns the ordinal index of this port side (matching Java enum ordinal).
    package var ordinal: Int {
        switch self {
        case .UNDEFINED: return 0
        case .NORTH: return 1
        case .EAST: return 2
        case .SOUTH: return 3
        case .WEST: return 4
        }
    }

    /// Returns the ordinal index as a function call (Java compatibility).
    package func getOrdinal() -> Int {
        return ordinal
    }
}

// MARK: - Set<PortSide> convenience names (matching Java EnumSet usage)
extension Set where Element == PortSide {
    package static var none: Set<PortSide> { [] }
    package static var north: Set<PortSide> { [.NORTH] }
    package static var east: Set<PortSide> { [.EAST] }
    package static var south: Set<PortSide> { [.SOUTH] }
    package static var west: Set<PortSide> { [.WEST] }
    package static var northSouth: Set<PortSide> { [.NORTH, .SOUTH] }
    package static var eastWest: Set<PortSide> { [.EAST, .WEST] }
    package static var northWest: Set<PortSide> { [.NORTH, .WEST] }
    package static var northEast: Set<PortSide> { [.NORTH, .EAST] }
    package static var southWest: Set<PortSide> { [.SOUTH, .WEST] }
    package static var eastSouth: Set<PortSide> { [.EAST, .SOUTH] }
    package static var northEastWest: Set<PortSide> { [.NORTH, .EAST, .WEST] }
    package static var eastSouthWest: Set<PortSide> { [.EAST, .SOUTH, .WEST] }
    package static var northSouthWest: Set<PortSide> { [.NORTH, .SOUTH, .WEST] }
    package static var northEastSouth: Set<PortSide> { [.NORTH, .EAST, .SOUTH] }
    package static var northEastSouthWest: Set<PortSide> { [.NORTH, .EAST, .SOUTH, .WEST] }
}
