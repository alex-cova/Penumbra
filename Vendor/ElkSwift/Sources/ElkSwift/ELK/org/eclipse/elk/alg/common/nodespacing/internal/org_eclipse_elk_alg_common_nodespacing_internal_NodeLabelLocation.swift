// Copyright (c) 2015, 2017 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

// Translated from Java to Swift

import Foundation

// MARK: - NodeLabelLocation

/**
 * Enumeration over all possible label placements and associated things.
 */
package enum NodeLabelLocation: CaseIterable {
    // Outside placements
    case OUT_T_L
    case OUT_T_C
    case OUT_T_R
    case OUT_B_L
    case OUT_B_C
    case OUT_B_R
    case OUT_L_T
    case OUT_L_C
    case OUT_L_B
    case OUT_R_T
    case OUT_R_C
    case OUT_R_B

    // Inside placements
    case IN_T_L
    case IN_T_C
    case IN_T_R
    case IN_C_L
    case IN_C_C
    case IN_C_R
    case IN_B_L
    case IN_B_C
    case IN_B_R

    // Undefined
    case UNDEFINED

    // MARK: - Static Methods

    package static func fromNodeLabelPlacement(_ labelPlacement: NodeLabelPlacement) -> NodeLabelLocation {
        let isInside = labelPlacement.contains(.inside)
        let hasVTop = labelPlacement.contains(.vTop)
        let hasVBottom = labelPlacement.contains(.vBottom)
        let hasVCenter = labelPlacement.contains(.vCenter)
        let hasHLeft = labelPlacement.contains(.hLeft)
        let hasHRight = labelPlacement.contains(.hRight)
        let hasHCenter = labelPlacement.contains(.hCenter)

        if isInside {
            if hasVTop {
                if hasHLeft { return .IN_T_L }
                else if hasHCenter { return .IN_T_C }
                else if hasHRight { return .IN_T_R }
            } else if hasVBottom {
                if hasHLeft { return .IN_B_L }
                else if hasHCenter { return .IN_B_C }
                else if hasHRight { return .IN_B_R }
            } else if hasVCenter {
                if hasHLeft { return .IN_C_L }
                else if hasHCenter { return .IN_C_C }
                else if hasHRight { return .IN_C_R }
            }
        } else {
            if hasVTop {
                if hasHLeft { return .OUT_T_L }
                else if hasHCenter { return .OUT_T_C }
                else if hasHRight { return .OUT_T_R }
            } else if hasVBottom {
                if hasHLeft { return .OUT_B_L }
                else if hasHCenter { return .OUT_B_C }
                else if hasHRight { return .OUT_B_R }
            } else if hasVCenter {
                if hasHLeft { return .OUT_L_T }
                else if hasHCenter { return .OUT_L_C }
                else if hasHRight { return .OUT_L_B }
            }
        }
        return .UNDEFINED
    }

    // MARK: - Computed Properties

    package var horizontalAlignment: HorizontalLabelAlignment {
        switch self {
        case .OUT_T_L, .OUT_B_L, .OUT_L_T, .OUT_L_C, .OUT_L_B, .IN_T_L, .IN_B_L, .IN_C_L:
            return .left
        case .OUT_T_C, .OUT_B_C, .IN_T_C, .IN_B_C, .IN_C_C:
            return .center
        case .OUT_T_R, .OUT_B_R, .OUT_R_T, .OUT_R_C, .OUT_R_B, .IN_T_R, .IN_B_R, .IN_C_R:
            return .right
        default:
            return .center
        }
    }

    package var verticalAlignment: VerticalLabelAlignment {
        switch self {
        case .OUT_T_L, .OUT_T_C, .OUT_T_R, .OUT_L_T, .OUT_R_T, .IN_T_L, .IN_T_C, .IN_T_R, .IN_C_L, .IN_C_C, .IN_C_R:
            return .top
        case .OUT_B_L, .OUT_B_C, .OUT_B_R, .OUT_L_B, .OUT_R_B, .IN_B_L, .IN_B_C, .IN_B_R:
            return .bottom
        case .OUT_L_C, .OUT_R_C:
            return .center
        default:
            return .center
        }
    }

    /// Alias methods for code that calls getHorizontalAlignment() / getVerticalAlignment()
    package func getHorizontalAlignment() -> HorizontalLabelAlignment {
        return horizontalAlignment
    }

    package func getVerticalAlignment() -> VerticalLabelAlignment {
        return verticalAlignment
    }

    package var containerRow: ContainerArea {
        switch self {
        case .OUT_T_L, .OUT_T_C, .OUT_T_R, .OUT_L_T, .OUT_R_T, .IN_T_L, .IN_T_C, .IN_T_R:
            return .begin
        case .OUT_B_L, .OUT_B_C, .OUT_B_R, .OUT_L_B, .OUT_R_B, .IN_B_L, .IN_B_C, .IN_B_R:
            return .end
        case .OUT_L_C, .OUT_R_C, .IN_C_L, .IN_C_C, .IN_C_R:
            return .center
        default:
            return .center
        }
    }

    package var containerColumn: ContainerArea {
        switch self {
        case .OUT_T_L, .OUT_B_L, .OUT_L_T, .OUT_L_C, .OUT_L_B, .IN_T_L, .IN_B_L, .IN_C_L:
            return .begin
        case .OUT_T_R, .OUT_B_R, .OUT_R_T, .OUT_R_C, .OUT_R_B, .IN_T_R, .IN_B_R, .IN_C_R:
            return .end
        case .OUT_T_C, .OUT_B_C, .IN_T_C, .IN_B_C, .IN_C_C:
            return .center
        default:
            return .center
        }
    }

    /// Java-style getters
    package func getContainerRow() -> ContainerArea {
        return containerRow
    }

    package func getContainerColumn() -> ContainerArea {
        return containerColumn
    }

    // MARK: - Helper Methods

    package func isInsideLocation() -> Bool {
        switch self {
        case .IN_T_L, .IN_T_C, .IN_T_R, .IN_C_L, .IN_C_C, .IN_C_R, .IN_B_L, .IN_B_C, .IN_B_R:
            return true
        default:
            return false
        }
    }

    package func getOutsideSide() -> PortSide {
        switch self {
        case .OUT_T_L, .OUT_T_C, .OUT_T_R:
            return .NORTH
        case .OUT_B_L, .OUT_B_C, .OUT_B_R:
            return .SOUTH
        case .OUT_L_T, .OUT_L_C, .OUT_L_B:
            return .WEST
        case .OUT_R_T, .OUT_R_C, .OUT_R_B:
            return .EAST
        default:
            return .UNDEFINED
        }
    }
}
