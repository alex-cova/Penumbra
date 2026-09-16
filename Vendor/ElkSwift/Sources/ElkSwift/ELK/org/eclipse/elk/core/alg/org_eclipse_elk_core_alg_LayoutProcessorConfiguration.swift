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
 * Instances of this class specify layout processors that should be executed in the different
 * processing slots before, in between, and after the phases of a layout algorithm. Layout processor configurations are
 * typically specified by layout phases to specify their processor dependencies. The information
 * can be used by an AlgorithmAssembler to assemble the layout algorithm. Each processor is only ever added once
 * to each processing slot, but can be part of several different slots.
 * 
 * <p>
 * Use this class by first obtaining an instance through the `create()` method and then calling
 * `addBefore(_: ILayoutProcessorFactory)` and `addAfter(_: ILayoutProcessorFactory)` to add the
 * necessary processors before or after any of the algorithm's phases. If more than one processor needs to be added to a
 * certain processing slot, the `before(_:)` and `after(_:)` methods can be called once, followed by
 * arbitrarily many calls to `add(_:)`.
 * </p>
 * 
 * <p>
 * Note that this class provides access to the configured processors in each slot through sets, meaning that they are
 * not sorted according to inter-processor dependencies. If used with AlgorithmAssembler, the assembler
 * determines the correct order.
 * </p>
 * 
 * @param P
 *            enumeration of all available phases. This is not an enumeration of all phase implementations.
 * @param G
 *            type of the graph the created algorithm will operate on.
 * @see ILayoutProcessor
 * @see ILayoutPhase
 * @see AlgorithmAssembler
 */
package final class LayoutProcessorConfiguration<P: Hashable, G> where P: RawRepresentable, P.RawValue: Hashable {
    
    package var processorLists: [[any ILayoutProcessorFactory]]
    package var currentIndex: Int
    
    // MARK: - Creation
    
    /**
     * Creates a new instance.
     * 
     * @return new layout processor configuration.
     */
    package static func create() -> LayoutProcessorConfiguration<P, G> {
        return LayoutProcessorConfiguration()
    }
    
    /**
     * Creates a new instance which is a copy of the given instance.
     * 
     * @param source
     *            the existing configuration to copy.
     * @return new layout processor configuration.
     */
    package static func create(from source: LayoutProcessorConfiguration<P, G>) -> LayoutProcessorConfiguration<P, G> {
        let newConfig = LayoutProcessorConfiguration<P, G>()
        newConfig.processorLists = source.processorLists.map { $0 }
        newConfig.currentIndex = source.currentIndex
        return newConfig
    }
    
    private init() {
        self.processorLists = []
        self.currentIndex = -1
    }

    /// Compute the slot index for processors before a phase.
    /// Each phase has two slots: before (2*ordinal) and after (2*ordinal + 1).
    private func slotIndex(before phase: P) -> Int {
        let ordinal: Int
        if let intRaw = phase.rawValue as? Int {
            ordinal = intRaw
        } else {
            ordinal = phase.rawValue.hashValue
        }
        return ordinal * 2
    }

    /// Compute the slot index for processors after a phase.
    private func slotIndex(after phase: P) -> Int {
        return slotIndex(before: phase) + 1
    }
    
    // MARK: - Processor Assembly
    
    /**
     * Resets the configuration by removing all processors.
     * 
     * @return this configuration to enable method chaining.
     */
    package func clear() -> LayoutProcessorConfiguration<P, G> {
        processorLists.removeAll()
        currentIndex = -1
        return self
    }
    
    /**
     * Sets things up such that subsequent calls to `add(_:)` will add processors to the
     * processing slot right before the given phase.
     * 
     * @param phase
     *            the phase processors should be added before.
     * @return this configuration to enable method chaining.
     */
    package func before(_ phase: P) -> LayoutProcessorConfiguration<P, G> {
        currentIndex = slotIndex(before: phase)
        return self
    }
    
    /**
     * Sets things up such that subsequent calls to `add(_:)` will add processors to the
     * processing slot right after the given phase.
     * 
     * @param phase
     *            the phase processors should be added after.
     * @return this configuration to enable method chaining.
     */
    package func after(_ phase: P) -> LayoutProcessorConfiguration<P, G> {
        currentIndex = slotIndex(after: phase)
        return self
    }
    
    /**
     * Adds the given processor to the current processing slot. The current processing slot is configured by calling
     * `before(_:)` or `after(_:)`. If neither of the two methods was called before or if
     * `addBefore(_: ILayoutProcessorFactory)` or `addAfter(_: ILayoutProcessorFactory)` was called
     * in the interim, there is no current processing slot and the call to this method fails.
     * 
     * @param processor
     *            the processor to add to the current processing slot.
     * @return this configuration to enable method chaining.
     * @throws IllegalStateException
     *             if there is no current processing slot.
     */
    package func add(_ processor: any ILayoutProcessorFactory) throws -> LayoutProcessorConfiguration<P, G> {
        guard currentIndex >= 0 else {
            assertionFailure("Did not call before(...) or after(...) before calling add(...).")
            return self
        }
        
        try doAdd(index: currentIndex, processor: processor)
        return self
    }
    
    /**
     * Adds the given processor to the processing slot right before the given phase.
     * 
     * @param phase
     *            the phase before which to add the processor.
     * @param processor
     *            the processor to add.
     * @return this configuration to enable method chaining.
     */
    @discardableResult
    package func addBefore(_ phase: P, _ processor: any ILayoutProcessorFactory) -> LayoutProcessorConfiguration<P, G> {
        currentIndex = -1
        try? doAdd(index: slotIndex(before: phase), processor: processor)
        return self
    }
    
    /**
     * Adds the given processor to the processing slot right after the given phase.
     * 
     * @param phase
     *            the phase after which to add the processor.
     * @param processor
     *            the processor to add.
     * @return this configuration to enable method chaining.
     */
    @discardableResult
    package func addAfter(_ phase: P, _ processor: any ILayoutProcessorFactory) -> LayoutProcessorConfiguration<P, G> {
        currentIndex = -1
        try? doAdd(index: slotIndex(after: phase), processor: processor)
        return self
    }
    
    /**
     * Adds the given processor to the slot with the given index.
     * 
     * @param index
     *            slot index.
     * @param processor
     *            the processor to add.
     */
    package func doAdd(index: Int, processor: any ILayoutProcessorFactory) throws {
        while processorLists.count <= index {
            processorLists.append([])
        }
        processorLists[index].append(processor)
    }
    
    /**
     * Adds all processors from the given configuration to this configuration.
     * 
     * @param configuration
     *            the configuration to add to this one.
     * @return this configuration to enable method chaining.
     */
    @discardableResult
    package func addAll(_ configuration: LayoutProcessorConfiguration<P, G>) -> LayoutProcessorConfiguration<P, G> {
        for i in 0..<configuration.processorLists.count {
            while processorLists.count <= i {
                processorLists.append([])
            }
            processorLists[i].append(contentsOf: configuration.processorLists[i])
        }
        return self
    }
    
    // MARK: - Processor List Building
    
    /**
     * Returns the set of processors configured to be executed right before the given phase.
     * 
     * @param phase
     *            the phase.
     * @return set of processors.
     */
    package func processors(before phase: P) -> [any ILayoutProcessorFactory] {
        return processors(index: slotIndex(before: phase))
    }
    
    /**
     * Returns the set of processors configured to be executed right after the given phase.
     * 
     * @param phase
     *            the phase.
     * @return set of processors.
     */
    package func processors(after phase: P) -> [any ILayoutProcessorFactory] {
        return processors(index: slotIndex(after: phase))
    }
    
    /**
     * Returns the set of processors in the slot with the given index.
     * 
     * @param index
     *            slot index.
     * @return set of processors.
     */
    package func processors(index: Int) -> [any ILayoutProcessorFactory] {
        if index < 0 || index >= processorLists.count {
            return []
        }
        return processorLists[index]
    }
}
