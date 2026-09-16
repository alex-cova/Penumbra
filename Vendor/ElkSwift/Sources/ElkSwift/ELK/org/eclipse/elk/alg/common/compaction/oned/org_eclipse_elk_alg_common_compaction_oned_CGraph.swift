/*******************************************************************************
 * Copyright (c) 2017 Kiel University and others.
 * 
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/

import Foundation

/**
 * Representation of a constraint graph that can be compacted using the `OneDimensionalCompactor`.
 */
package final class CommonCGraph {
    
    // Variables are package for convenience reasons
    // SUPPRESS CHECKSTYLE NEXT 14 VisibilityModifier
    /** the list of `CNode`s modeling the constraints in this graph. */
    package var cNodes: [CNode] = []
    /** groups of elements that are supposed to stay in the configuration they are. */
    package var cGroups: [CGroup] = []
    /** the directions that are supported for compaction. */
    package var supportedDirections: Set<Direction>
    
    /** static constraints between pairs of `CNode`s that are to be added by the `OneDimensionalCompactor`.
     *  Depending on the compaction direction, the constraints may be applied in reverse. */
    package var predefinedHorizontalConstraints: [(CNode, CNode)] = []
    /** static constraints between pairs of `CNode`s that are to be added by the `OneDimensionalCompactor`.
     *  Depending on the compaction direction, the constraints may be applied in reverse. */
    package var predefinedVerticalConstraints: [(CNode, CNode)] = []
    
    /**
     * Constructor sets the supported directions.
     * 
     * @param supportedDirections
     *          the directions that are supported for compaction
     */
    package init(_ supportedDirections: Set<Direction>) {
        self.supportedDirections = supportedDirections
    }
    
    /**
     * If the `CGraph` supports compaction in the direction specified by the parameter.
     * @param direction
     *          the direction to check
     * @return if compaction is supported
     */
    package func supports(_ direction: Direction) -> Bool {
        return supportedDirections.contains(direction)
    }
}
