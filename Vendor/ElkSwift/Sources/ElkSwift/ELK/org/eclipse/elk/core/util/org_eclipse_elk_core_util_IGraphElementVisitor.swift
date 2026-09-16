// Copyright (c) 2015 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0



/// A graph element visitor is applied to all elements of a graph.
package protocol IGraphElementVisitor {
    /// Visit the given graph element.
    func visit(_ element: ElkGraphElement) throws
}
