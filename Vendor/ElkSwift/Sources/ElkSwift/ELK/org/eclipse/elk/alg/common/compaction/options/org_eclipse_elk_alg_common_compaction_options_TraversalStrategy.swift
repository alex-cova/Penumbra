// Copyright (c) 2017 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


/// Possible traversal orders (with an implicit cost function) for placing polyominoes on an infinite square planar grid.
package enum TraversalStrategy {
    /// Spiral traversal strategy
    case SPIRAL
    /// Line-by-line traversal strategy
    case LINE_BY_LINE
    /// Manhattan traversal strategy
    case MANHATTAN
    /// Jitter traversal strategy
    case JITTER
    /// Quadrants line-by-line traversal strategy
    case QUADRANTS_LINE_BY_LINE
    /// Quadrants Manhattan traversal strategy
    case QUADRANTS_MANHATTAN
    /// Quadrants jitter traversal strategy
    case QUADRANTS_JITTER
    /// Combine line-by-line and Manhattan traversal strategy
    case COMBINE_LINE_BY_LINE_MANHATTAN
    /// Combine jitter and Manhattan traversal strategy
    case COMBINE_JITTER_MANHATTAN
}
