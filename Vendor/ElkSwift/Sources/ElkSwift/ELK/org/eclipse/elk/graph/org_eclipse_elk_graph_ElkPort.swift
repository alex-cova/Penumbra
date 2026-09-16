/**
 * Copyright (c) 2016 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 */

import Foundation

/**
 * A port represents an explicit point through which to connect to a node. Different ports of a node will usually have different associated meanings, much like different method parameters. Each port belongs to the node it is contained in.
 *
 * The following features are supported:
 * - `parent`: The node the port belongs to.
 */
package protocol ElkPort: ElkConnectableShape {
    
    /// The node the port belongs to.
    ///
    /// Setting the parent node automatically updates the node's list of ports.
    var parent: ElkNode? { get set }
}
