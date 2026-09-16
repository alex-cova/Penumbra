// Copyright (c) 2010, 2017 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0



/**
 * A layout processor processes a graph. Layout processors are the secondary components of layout algorithms, the
 * primary being {@link ILayoutPhase layout phases}. Layout processors are inserted before or after phases to do further
 * processing on a graph.
 *
 * <p>
 * The {@link AlgorithmAssembler} class can be used to build algorithms by specifying phases and letting the assembler
 * worry about instantiating all required processors.
 * </p>
 *
 * @param G the type of graph the processor will process.
 * @see ILayoutPhase
 * @see AlgorithmAssembler
 */
package protocol ILayoutProcessor: AnyGraphProcessorWrappable {

    associatedtype G

    /**
     * Performs the processor's work on the given graph.
     *
     * @param graph the graph to process.
     * @param progressMonitor a progress monitor to indicate progress with.
     */
    func process(_ graph: G, _ progressMonitor: IElkProgressMonitor)
}

// MARK: - Type-Erased Graph Processor

/// Conforming types can wrap themselves into ``AnyGraphProcessor``.
///
/// `ILayoutProcessor` refines this protocol, so all processors automatically conform.
/// The default implementation is provided per graph type via conditional extensions
/// (see below for `LGraph`).
///
/// ## Adding support for a new graph type
///
/// When porting a new ELK algorithm family (e.g. force layout with `FGraph`):
///
/// 1. Add a new static factory on `AnyGraphProcessor`:
///    ```swift
///    package static func fgraph<P: ILayoutProcessor>(_ processor: P, ...) -> AnyGraphProcessor
///    where P.G == FGraph { ... }
///    ```
///
/// 2. Add a conditional extension providing the wrapping:
///    ```swift
///    extension ILayoutProcessor where G == FGraph {
///        package func asAnyGraphProcessor(isHierarchyAware: Bool) -> AnyGraphProcessor {
///            .fgraph(self, isHierarchyAware: isHierarchyAware)
///        }
///    }
///    ```
///
/// Any `ILayoutProcessor` with an unhandled `G` will produce a compile error,
/// forcing the maintainer to add support for the new graph type.
package protocol AnyGraphProcessorWrappable {
    func asAnyGraphProcessor(isHierarchyAware: Bool) -> AnyGraphProcessor
}

/// Default wrapping for all layered-algorithm processors (`G == LGraph`).
extension ILayoutProcessor where G == LGraph {
    package func asAnyGraphProcessor(isHierarchyAware: Bool) -> AnyGraphProcessor {
        .lgraph(self, isHierarchyAware: isHierarchyAware)
    }
}

/// Type-erased wrapper for layout processors, avoiding parameterized existentials
/// (`any ILayoutProcessor<LGraph>`) which require macOS 13+ / iOS 16+ runtime.
///
/// The `process` closure is captured at creation time when the concrete graph type is known,
/// so no runtime cast is needed at dispatch time.
package struct AnyGraphProcessor {

    /// Whether this processor conforms to `IHierarchyAwareLayoutProcessor`.
    /// Used by `ElkLayered.hierarchicalLayout` to decide execution order.
    package let isHierarchyAware: Bool

    private let _process: (Any, IElkProgressMonitor) -> Void

    private init(isHierarchyAware: Bool, _ process: @escaping (Any, IElkProgressMonitor) -> Void) {
        self.isHierarchyAware = isHierarchyAware
        self._process = process
    }

    /// Wraps a processor that operates on `LGraph` (layered algorithm).
    package static func lgraph<P: ILayoutProcessor>(_ processor: P,
                                                     isHierarchyAware: Bool = false) -> AnyGraphProcessor
    where P.G == LGraph {
        AnyGraphProcessor(isHierarchyAware: isHierarchyAware) { graph, monitor in
            guard let lgraph = graph as? LGraph else { return }
            processor.process(lgraph, monitor)
        }
    }

    /// Wraps any processor via the `AnyGraphProcessorWrappable` protocol.
    /// This is the primary entry point used by `AlgorithmAssembler`.
    package static func wrapping(_ processor: Any) -> AnyGraphProcessor {
        let isHierarchyAware = processor is IHierarchyAwareLayoutProcessor
        if let wrappable = processor as? AnyGraphProcessorWrappable {
            return wrappable.asAnyGraphProcessor(isHierarchyAware: isHierarchyAware)
        }
        assertionFailure("Processor does not conform to AnyGraphProcessorWrappable: \(type(of: processor))")
        return AnyGraphProcessor(isHierarchyAware: false) { _, _ in }
    }

    /// Dispatches the wrapped processor.
    package func process(_ graph: Any, _ monitor: IElkProgressMonitor) {
        _process(graph, monitor)
    }
}
