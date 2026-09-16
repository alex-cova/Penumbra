/**
 * Copyright (c) 2016 Kiel University and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 */


/**
 * A representation of the model object '<em>Element</em>'.
 *
 * This is the superclass of all elements of a graph such as nodes, edges, ports, and labels. Each element can have an arbitrary number of labels attached to it. A graph element can also hold properties that, for instance, influence how it is treated by layout algorithms. Finally, each graph element can have an arbitrary number of `ElkGraphData` objects associated with it to further annotate it with more specific information.
 *
 * The following features are supported:
 * - `labels`: Labels associated with this graph element.
 * - `identifier`: An optional String identifier for this graph element.
 */
package protocol ElkGraphElement: EMapPropertyHolder {
    
    /// Labels associated with this graph element.
    ///
    /// Adding or removing a label to/from this list automatically updates its parent element.
    var labels: EList<ElkLabel> { get }
    
    /// An optional String identifier for this graph element. Can be used as an ID for defining graphs in Xtext-based languages.
    var identifier: String? { get set }
}
