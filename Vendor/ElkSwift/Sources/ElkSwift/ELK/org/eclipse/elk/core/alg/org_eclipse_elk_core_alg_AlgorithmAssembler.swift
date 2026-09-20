/*******************************************************************************
 * Copyright (c) 2017 cds and others.
 *
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 ******************************************************************************/

import Foundation

// MARK: - AlgorithmAssembler

package class AlgorithmAssembler<P: Hashable & CaseIterable & RawRepresentable, G> where P.RawValue == Int {

    package var enableCaching: Bool = true
    package var failOnMissingPhase: Bool = true
    package var processorComparator: EnumBasedFactory = EnumBasedFactory()

    package let phasesEnumClass: P.Type
    package let numberOfPhases: Int
    package var configuredPhases: Set<P> = []
    package let additionalProcessors: LayoutProcessorConfiguration<P, G>

    // Cache uses ObjectIdentifier as key since protocols with associated types can't be Hashable
    package var cache: [ObjectIdentifier: Any] = [:]

    // Phase factories stored by raw value index
    package var phaseFactories: [Int: Any] = [:]
    package var phaseFactoryList: [Any?] = []

    // MARK: - Creation

    package static func create(_ phaseEnum: P.Type) -> AlgorithmAssembler<P, G> {
        return AlgorithmAssembler(phaseEnum)
    }

    private init(_ phaseEnum: P.Type) {
        phasesEnumClass = phaseEnum
        numberOfPhases = Array(phaseEnum.allCases).count

        if numberOfPhases == 0 {
            assertionFailure("There must be at least one phase in the phase enumeration.")
        }

        additionalProcessors = LayoutProcessorConfiguration<P, G>.create()
        phaseFactoryList = Array(repeating: nil, count: numberOfPhases)
    }

    // MARK: - Configuration

    @discardableResult
    package func withCaching(_ enabled: Bool) -> AlgorithmAssembler<P, G> {
        enableCaching = enabled
        return self
    }

    @discardableResult
    package func withFailOnMissingPhase(_ fail: Bool) -> AlgorithmAssembler<P, G> {
        failOnMissingPhase = fail
        return self
    }

    @discardableResult
    package func withProcessorComparator(_ comparator: EnumBasedFactory) -> AlgorithmAssembler<P, G> {
        processorComparator = comparator
        return self
    }

    // MARK: - Phase Assembly

    @discardableResult
    package func clearCache() -> AlgorithmAssembler<P, G> {
        cache.removeAll()
        return self
    }

    @discardableResult
    package func reset() -> AlgorithmAssembler<P, G> {
        phaseFactoryList = Array(repeating: nil, count: numberOfPhases)
        phaseFactories.removeAll()
        configuredPhases.removeAll()
        _ = additionalProcessors.clear()
        return self
    }

    @discardableResult
    package func setPhase(_ phase: P, _ phaseFactory: Any) -> AlgorithmAssembler<P, G> {
        let index = phase.rawValue
        while phaseFactoryList.count <= index {
            phaseFactoryList.append(nil)
        }
        phaseFactoryList[index] = phaseFactory
        phaseFactories[index] = phaseFactory
        configuredPhases.insert(phase)
        return self
    }

    @discardableResult
    package func addProcessorConfiguration(_ config: LayoutProcessorConfiguration<P, G>) -> AlgorithmAssembler<P, G> {
        _ = additionalProcessors.addAll(config)
        return self
    }

    // MARK: - Algorithm Building

    package func build(_ graph: G) -> [AnyGraphProcessor] {
        // Check if there are enough phases
        if failOnMissingPhase && configuredPhases.count < numberOfPhases {
            assertionFailure("Expected \(numberOfPhases) phases to be configured; only found \(configuredPhases.count)")
        }

        let allCases = Array(P.allCases)

        // Instantiate all configured phases
        var phaseImplementations: [Any?] = Array(repeating: nil, count: numberOfPhases)
        for phase in allCases {
            let index = phase.rawValue
            if index < phaseFactoryList.count, let factory = phaseFactoryList[index] {
                phaseImplementations[index] = retrievePhaseFromFactory(factory)
            }
        }

        // Assemble a definitive processor configuration
        let processorConfiguration = LayoutProcessorConfiguration<P, G>.create()
        for phaseImpl in phaseImplementations {
            if let phase = phaseImpl,
               let layoutPhase = phase as? AnyLayoutPhaseBox {
                if let config = layoutPhase.getLayoutProcessorConfigurationErased(graph) as? LayoutProcessorConfiguration<P, G> {
                    _ = processorConfiguration.addAll(config)
                }
            }
        }
        _ = processorConfiguration.addAll(additionalProcessors)

        // The list of processors the algorithm will be made up of
        var algorithm: [AnyGraphProcessor] = []

        // Add processors and phases to the algorithm
        for phase in allCases {
            // Add processors before this phase
            let beforeProcessors = retrieveProcessorsFromFactories(processorConfiguration.processors(before: phase))
            algorithm.append(contentsOf: beforeProcessors)

            // Add the phase itself, if it exists
            let index = phase.rawValue
            if index < phaseImplementations.count, let phaseImpl = phaseImplementations[index] {
                algorithm.append(.wrapping(phaseImpl))
            }
        }

        // Add processors after the last phase
        if let lastPhase = allCases.last {
            let afterProcessors = retrieveProcessorsFromFactories(processorConfiguration.processors(after: lastPhase))
            algorithm.append(contentsOf: afterProcessors)
        }

        return algorithm
    }

    // MARK: - Utilities

    private func retrievePhaseFromFactory(_ factory: Any) -> Any {
        // If factory has a create() method, call it
        if let f = factory as? AnyLayoutProcessorFactoryBox {
            return f.createErased()
        }
        return factory
    }

    package func retrieveProcessorsFromFactories(_ factories: [any ILayoutProcessorFactory]) -> [AnyGraphProcessor] {
        let sortedFactories = factories.sorted { factory1, factory2 in
            processorComparator.compare(factory1, factory2) < 0
        }
        return sortedFactories.map { .wrapping($0.create()) }
    }
}

/// Type-erased protocol for layout phase factories
package protocol AnyLayoutProcessorFactoryBox {
    func createErased() -> Any
}

/// Type-erased protocol for layout phases
package protocol AnyLayoutPhaseBox {
    func getLayoutProcessorConfigurationErased(_ graph: Any) -> Any?
}

// MARK: - Auto-conformance for ILayoutPhaseFactory → AnyLayoutProcessorFactoryBox

extension ILayoutPhaseFactory {
    package func createErased() -> Any {
        return create() as Any
    }
}

// Make all ILayoutPhaseFactory enums conform to AnyLayoutProcessorFactoryBox
extension CycleBreakingStrategy: AnyLayoutProcessorFactoryBox {}
extension LayeringStrategy: AnyLayoutProcessorFactoryBox {}
extension CrossingMinimizationStrategy: AnyLayoutProcessorFactoryBox {}
extension NodePlacementStrategy: AnyLayoutProcessorFactoryBox {}
extension EdgeRouterFactory: AnyLayoutProcessorFactoryBox {}

// MARK: - Auto-conformance for ILayoutPhase → AnyLayoutPhaseBox

extension org_eclipse_elk_alg_layered_p1cycles_GreedyCycleBreaker: AnyLayoutPhaseBox {
    package func getLayoutProcessorConfigurationErased(_ graph: Any) -> Any? {
        guard let g = graph as? LGraph else { return nil }
        return getLayoutProcessorConfiguration(g)
    }
}

extension org_eclipse_elk_alg_layered_p2layers_NetworkSimplexLayerer: AnyLayoutPhaseBox {
    package func getLayoutProcessorConfigurationErased(_ graph: Any) -> Any? {
        guard let g = graph as? LGraph else { return nil }
        return getLayoutProcessorConfiguration(g)
    }
}

extension org_eclipse_elk_alg_layered_p2layers_LongestPathLayerer: AnyLayoutPhaseBox {
    package func getLayoutProcessorConfigurationErased(_ graph: Any) -> Any? {
        guard let g = graph as? LGraph else { return nil }
        return getLayoutProcessorConfiguration(g)
    }
}

extension org_eclipse_elk_alg_layered_p3order_LayerSweepCrossingMinimizer: AnyLayoutPhaseBox {
    package func getLayoutProcessorConfigurationErased(_ graph: Any) -> Any? {
        guard let g = graph as? LGraph else { return nil }
        return getLayoutProcessorConfiguration(g)
    }
}

extension org_eclipse_elk_alg_layered_p4nodes_bk_BKNodePlacer: AnyLayoutPhaseBox {
    package func getLayoutProcessorConfigurationErased(_ graph: Any) -> Any? {
        guard let g = graph as? LGraph else { return nil }
        return getLayoutProcessorConfiguration(g)
    }
}

extension org_eclipse_elk_alg_layered_p4nodes_SimpleNodePlacer: AnyLayoutPhaseBox {
    package func getLayoutProcessorConfigurationErased(_ graph: Any) -> Any? {
        guard let g = graph as? LGraph else { return nil }
        return getLayoutProcessorConfiguration(g)
    }
}

extension org_eclipse_elk_alg_layered_p5edges_PolylineEdgeRouter: AnyLayoutPhaseBox {
    package func getLayoutProcessorConfigurationErased(_ graph: Any) -> Any? {
        guard let g = graph as? LGraph else { return nil }
        return getLayoutProcessorConfiguration(g)
    }
}

extension org_eclipse_elk_alg_layered_p5edges_OrthogonalEdgeRouter: AnyLayoutPhaseBox {
    package func getLayoutProcessorConfigurationErased(_ graph: Any) -> Any? {
        guard let g = graph as? LGraph else { return nil }
        return getLayoutProcessorConfiguration(g)
    }
}
