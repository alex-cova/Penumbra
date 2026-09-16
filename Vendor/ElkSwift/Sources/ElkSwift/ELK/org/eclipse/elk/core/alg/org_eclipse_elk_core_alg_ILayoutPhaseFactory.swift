// Copyright (c) 2015, 2017 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0


/**
 * Classes that implement this protocol can create layout phases.
 */
package protocol ILayoutPhaseFactory: ILayoutProcessorFactory {

    associatedtype P: Hashable & RawRepresentable where P.RawValue: Hashable
    associatedtype PhaseGraph

    /**
     * Returns an implementation of `ILayoutPhase`.
     */
    func create() -> any ILayoutPhase
}

// Default implementation: ILayoutPhase is-a ILayoutProcessor, so the phase factory's
// create() automatically satisfies ILayoutProcessorFactory's requirement.
extension ILayoutPhaseFactory {
    package func create() -> any ILayoutProcessor {
        let phase: any ILayoutPhase = create()
        return phase
    }
}
