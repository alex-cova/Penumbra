// Copyright (c) 2024 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0



/// A topdown size approximator returns an estimated size of the graph drawing after performing layout using some 
/// heuristic.
package protocol ITopdownSizeApproximator {
    /// Returns an approximated required size for a given node.
    /// - Parameter node: the node
    /// - Returns: the size as a vector
    func getSize(_ node: any ElkNode) throws -> KVector
}
