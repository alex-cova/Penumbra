/*******************************************************************************
 * Copyright (c) 2017 Kiel University and others.
 * 
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

/// Enumeration of three container areas that can be used by containers that use three areas.
///
/// - SeeAlso: StripContainerCell
/// - SeeAlso: GridContainerCell
package enum ContainerArea: Int, CaseIterable {
    /// The top row or left column of the container.
    case begin = 0

    /// The center row or column of the container.
    case center = 1

    /// The bottom row or right column of the container.
    case end = 2

    /// Java-compatible ordinal.
    package var ordinal: Int { rawValue }

    // MARK: - Uppercase Aliases (Java compatibility)
    package static let BEGIN = ContainerArea.begin
    package static let CENTER = ContainerArea.center
    package static let END = ContainerArea.end

    /// Java-compatible values array.
    package static var values: [ContainerArea] { return ContainerArea.allCases }

    /// Number of container areas.
    package static var count: Int { return allCases.count }
}
