// Copyright (c) 2016 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


/**
 * Interface for classes that import a `CGraph`.
 *
 * @param T The type of data structure that is transformed into a `CGraph`
 */
package protocol ICGraphTransformer {
    associatedtype T

    /**
     * Transforms the input graph into a `CGraph` consisting of `CNode`s that may
     * be grouped in `CGroup`s.
     *
     * @param inputGraph The graph to transform into a `CGraph`
     * @return A `CGraph`
     */
    func transform(_ inputGraph: T) -> CGraph

    /**
     * Updates the properties of the input graph and applies the compacted positions to the
     * elements of the input graph.
     */
    func applyLayout()
}
