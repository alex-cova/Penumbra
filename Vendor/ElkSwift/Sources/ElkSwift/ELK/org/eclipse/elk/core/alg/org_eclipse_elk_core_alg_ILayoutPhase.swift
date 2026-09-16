// Copyright (c) 2010, 2017 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


/**
 * A layout phase processes a graph and may depend on ``ILayoutProcessor`` layout processors for further processing
 * of the graph.
 */
package protocol ILayoutPhase: ILayoutProcessor {

    associatedtype P: Hashable & RawRepresentable where P.RawValue: Hashable
    associatedtype PhaseGraph

    /**
     * Returns a layout processor configuration that specifies which ``ILayoutProcessor`` layout processors this
     * phase would require to be executed at which point in the algorithm to process the given graph.
     */
    func getLayoutProcessorConfiguration(_ graph: PhaseGraph) -> LayoutProcessorConfiguration<P, PhaseGraph>?
}
