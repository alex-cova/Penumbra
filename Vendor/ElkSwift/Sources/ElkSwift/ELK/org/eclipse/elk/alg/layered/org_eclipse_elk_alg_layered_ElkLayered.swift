// Copyright (c) 2010, 2020 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

// MARK: - ELK Layered Implementation

package class ElkLayered {

    // MARK: - Variables

    package let graphConfigurator = GraphConfigurator()
    package let componentsProcessor = ComponentsProcessor()
    package let compoundGraphPreprocessor = CompoundGraphPreprocessor()
    package let compoundGraphPostprocessor = CompoundGraphPostprocessor()
    package var testController: TestController? = nil

    // MARK: - Regular Layout

    package func doLayout(_ lgraph: LGraph, _ monitor: IElkProgressMonitor?) {
        let theMonitor: IElkProgressMonitor = monitor ?? BasicProgressMonitor()
        theMonitor.begin("Layered layout", 1)

        graphConfigurator.prepareGraphForLayout(lgraph)

        let components = componentsProcessor.split(lgraph)
        if components.count == 1 {
            layout(components[0], theMonitor)
        } else {
            let compWork = Float(1.0) / Float(components.count)
            for comp in components {
                if theMonitor.isCanceled() {
                    return
                }
                if let subMonitor = theMonitor.subTask(compWork) {
                    layout(comp, subMonitor)
                }
            }
        }
        componentsProcessor.combine(components, target: lgraph)

        resizeGraph(lgraph)

        theMonitor.done()
    }

    // MARK: - Compound Graph Layout

    package func doCompoundLayout(_ lgraph: LGraph, _ monitor: IElkProgressMonitor?) {
        let theMonitor: IElkProgressMonitor = monitor ?? BasicProgressMonitor()
        theMonitor.begin("Layered layout", 2)

        // Preprocess the compound graph by splitting cross-hierarchy edges
        if let sub = theMonitor.subTask(1) { compoundGraphPreprocessor.process(lgraph, sub) }

        // Run the lockstep hierarchical layout (matches Java's ElkLayered.hierarchicalLayout)
        if let sub = theMonitor.subTask(1) { hierarchicalLayout(lgraph, sub) }

        // Postprocess the compound graph by combining split cross-hierarchy edges
        if let sub = theMonitor.subTask(1) { compoundGraphPostprocessor.process(lgraph, sub) }

        theMonitor.done()
    }

    /// Lockstep hierarchical layout matching Java's ElkLayered.hierarchicalLayout exactly.
    ///
    /// All graphs are collected bottom-up (innermost first). Each graph gets its own processor list.
    /// Processors are executed in lockstep: non-hierarchy-aware processors run immediately per graph,
    /// but hierarchy-aware processors (IHierarchyAwareLayoutProcessor) are only executed on the root
    /// graph. Non-root graphs pause at hierarchy-aware processors until root has processed them.
    package func hierarchicalLayout(_ lgraph: LGraph, _ monitor: IElkProgressMonitor) {
        // Innermost graphs first, root last
        let graphs = collectAllGraphsBottomUp(lgraph)
        reviewAndCorrectHierarchicalProcessors(lgraph, graphs)

        // Get processor list for each graph. Use index to track progress (simulates Java Iterator).
        var work = 0
        var graphsAndAlgorithms: [(graph: LGraph, processors: [AnyGraphProcessor], idx: Int)] = []

        for g in graphs {
            graphConfigurator.prepareGraphForLayout(g)
            let processors = g.getProperty(InternalProperties.PROCESSORS) as? [AnyGraphProcessor] ?? []
            work += processors.count
            graphsAndAlgorithms.append((g, processors, 0))
        }

        monitor.begin("Recursive hierarchical layout", Float(work))

        // Find the root graph entry (last in the list since innermost-first ordering)
        guard let rootIdx = graphsAndAlgorithms.lastIndex(where: { isRoot($0.graph) }) else {
            monitor.done()
            return
        }

        var slotIndex = 0

        // While root still has processors to run
        while graphsAndAlgorithms[rootIdx].idx < graphsAndAlgorithms[rootIdx].processors.count {
            // Layout from bottom up (innermost graphs first)
            for i in 0..<graphsAndAlgorithms.count {
                var idx = graphsAndAlgorithms[i].idx
                let processors = graphsAndAlgorithms[i].processors
                let graph = graphsAndAlgorithms[i].graph

                // Inner while: run consecutive non-hierarchy-aware processors until we hit
                // a hierarchy-aware one or exhaust the list (matches Java's inner while loop)
                while idx < processors.count {
                    let processor = processors[idx]

                    if !processor.isHierarchyAware {
                        // Regular processor: execute immediately
                        if let sub = monitor.subTask(1) { processor.process(graph, sub) }

                        idx += 1
                        slotIndex += 1

                    } else if isRoot(graph) {
                        // Hierarchy-aware processor on root: execute it
                        if let sub = monitor.subTask(1) { processor.process(graph, sub) }

                        idx += 1
                        slotIndex += 1

                        // Continue operation with the graph at the bottom of the hierarchy
                        break

                    } else {
                        // Non-root hierarchy-aware: skip past it (Java's iterator.next() consumed it)
                        // and pause execution until root graph has processed
                        idx += 1
                        break
                    }
                }

                graphsAndAlgorithms[i] = (graph, processors, idx)
            }
        }

        monitor.done()
    }

    /// Breadth-first search with reversed order: innermost graphs come first, root comes last.
    /// Matches Java's ArrayDeque.push (addFirst) behavior for collectedGraphs.
    package func collectAllGraphsBottomUp(_ root: LGraph) -> [LGraph] {
        // Java uses ArrayDeque as stack: push=addFirst, pop=removeFirst
        // collectedGraphs.push puts children BEFORE parents → innermost first
        // We append in parent-first order and reverse at the end to avoid O(N) insert(at:0).
        var collectedGraphs: [LGraph] = []
        var stack: [LGraph] = []

        collectedGraphs.append(root)
        stack.append(root)

        while !stack.isEmpty {
            let nextGraph = stack.removeLast()
            for node in nextGraph.getLayerlessNodes() {
                if hasNestedGraph(node) {
                    if let nestedGraph = node.getNestedGraph() {
                        collectedGraphs.append(nestedGraph)
                        stack.append(nestedGraph)
                    }
                }
            }
        }

        return collectedGraphs.reversed()
    }

    package func reviewAndCorrectHierarchicalProcessors(_ root: LGraph, _ graphs: [LGraph]) {
        let parentCms = root.getProperty(LayeredOptions.CROSSING_MINIMIZATION_STRATEGY) as? CrossingMinimizationStrategy
        for child in graphs {
            let childCms = child.getProperty(LayeredOptions.CROSSING_MINIMIZATION_STRATEGY) as? CrossingMinimizationStrategy
            if childCms != parentCms {
                assertionFailure("UnsupportedGraphException")
                return
            }
        }

        let rootType = root.getProperty(LayeredOptions.CROSSING_MINIMIZATION_GREEDY_SWITCH_HIERARCHICAL_TYPE) as? GreedySwitchType
        for g in graphs {
            g.setProperty(LayeredOptions.CROSSING_MINIMIZATION_GREEDY_SWITCH_HIERARCHICAL_TYPE, rootType)
        }
    }

    package func isRoot(_ graph: LGraph) -> Bool {
        return graph.getParentNode() == nil
    }

    package func hasNestedGraph(_ node: LNode) -> Bool {
        return node.getNestedGraph() != nil
    }

    // MARK: - Layout Testing

    package class TestExecutionState {
        var graphs: [LGraph] = []
        var step: Int = 0

        package func getGraphs() -> [LGraph] {
            return graphs
        }

        package func getStep() -> Int {
            return step
        }
    }

    package func prepareLayoutTest(_ lgraph: LGraph) -> TestExecutionState {
        let state = TestExecutionState()

        graphConfigurator.prepareGraphForLayout(lgraph)
        state.graphs = componentsProcessor.split(lgraph)

        return state
    }

    package func isLayoutTestFinished(_ state: TestExecutionState) -> Bool {
        guard let algorithm = state.graphs.first?.getProperty(InternalProperties.PROCESSORS) as? [AnyGraphProcessor] else {
            return true
        }
        return state.step >= algorithm.count
    }

    package func runLayoutTestUntil(_ phase: AnyClass, _ inclusive: Bool, _ state: TestExecutionState) {
        guard let algorithm = state.graphs.first?.getProperty(InternalProperties.PROCESSORS) as? [AnyGraphProcessor] else {
            return
        }

        var phaseExists = false
        var phaseIndex = state.step
        var iterator = algorithm[state.step...].makeIterator()

        while let processor = iterator.next(), !phaseExists {
            if type(of: processor).self == phase {
                phaseExists = true
                if inclusive {
                    phaseIndex += 1
                }
            } else {
                phaseIndex += 1
            }
        }

        if !phaseExists {
            // No-op
        }

        for i in state.step..<phaseIndex {
            let processor = algorithm[i]
            layoutTest(state.graphs, processor)
            state.step += 1
        }
    }

    package func runLayoutTestUntil(_ phase: AnyClass, _ state: TestExecutionState) {
        runLayoutTestUntil(phase, true, state)
    }

    package func runLayoutTestStep(_ state: TestExecutionState) {
        if isLayoutTestFinished(state) {
            assertionFailure("Current layout test run has finished.")
            return
        }

        guard let algorithm = state.graphs.first?.getProperty(InternalProperties.PROCESSORS) as? [AnyGraphProcessor] else {
            return
        }

        let processor = algorithm[state.step]
        layoutTest(state.graphs, processor)
        state.step += 1
    }

    package func getLayoutTestConfiguration(_ state: TestExecutionState) -> [AnyGraphProcessor] {
        return state.graphs.first?.getProperty(InternalProperties.PROCESSORS) as? [AnyGraphProcessor] ?? []
    }

    package func setTestController(_ testController: TestController?) {
        self.testController = testController
    }

    package func notifyProcessorReady(_ lgraph: LGraph, _ processor: Any) {
        // TestController notification — stubbed out since TestController protocol
        // does not define these methods in the Swift codebase
    }

    package func notifyProcessorFinished(_ lgraph: LGraph, _ processor: Any) {
        // TestController notification — stubbed out
    }

    // MARK: - Actual Layout

    package func layout(_ lgraph: LGraph, _ monitor: IElkProgressMonitor) {
        let monitorWasAlreadyRunning = monitor.isRunning()
        if !monitorWasAlreadyRunning {
            monitor.begin("Component Layout", 1)
        }

        guard let algorithm = lgraph.getProperty(InternalProperties.PROCESSORS) as? [AnyGraphProcessor] else {
            return
        }

        let monitorProgress = Float(1.0) / Float(algorithm.count)

        if monitor.isLoggingEnabled() {
            monitor.log("ELK Layered uses the following \(algorithm.count) modules:")
            for (index, processor) in algorithm.enumerated() {
                let slot = index < 10 ? "0\(index)" : "\(index)"
                monitor.log("   Slot \(slot): \(type(of: processor))")
            }
        }

        for processor in algorithm {
            if monitor.isCanceled() {
                return
            }

            if let sub = monitor.subTask(monitorProgress) { processor.process(lgraph, sub) }
        }

        for layer in lgraph.getLayers() {
            for node in layer.getNodes() {
                lgraph.layerlessNodes.append(node)
                node.layer = nil
            }
        }

        lgraph.layers.removeAll()

        if !monitorWasAlreadyRunning {
            monitor.done()
        }
    }

    package func layoutTest(_ lgraphs: [LGraph], _ processor: AnyGraphProcessor) {
        for lgraph in lgraphs {
            processor.process(lgraph, BasicProgressMonitor())
        }
    }

    // MARK: - Graph Postprocessing

    package func resizeGraph(_ lgraph: LGraph) {
        let sizeConstraint = lgraph.getProperty(LayeredOptions.NODE_SIZE_CONSTRAINTS) as? SizeConstraint ?? []
        let sizeOptions = lgraph.getProperty(LayeredOptions.NODE_SIZE_OPTIONS) as? SizeOptions ?? []

        let calculatedSize = lgraph.getActualSize()
        let adjustedSize = KVector(calculatedSize.x, calculatedSize.y)

        if sizeConstraint.contains(.minimumSize) {
            let minSize = lgraph.getProperty(LayeredOptions.NODE_SIZE_MINIMUM) as? KVector ?? KVector()

            if sizeOptions.contains(.defaultMinimumSize) {
                if minSize.x <= 0 {
                    minSize.x = ElkUtil.DEFAULT_MIN_WIDTH
                }
                if minSize.y <= 0 {
                    minSize.y = ElkUtil.DEFAULT_MIN_HEIGHT
                }
            }

            adjustedSize.x = max(calculatedSize.x, minSize.x)
            adjustedSize.y = max(calculatedSize.y, minSize.y)
        }

        let fixedGraphSize = lgraph.getProperty(LayeredOptions.NODE_SIZE_FIXED_GRAPH_SIZE) as? Bool ?? false
        if !fixedGraphSize {
            resizeGraphNoReallyIMeanIt(lgraph, calculatedSize, adjustedSize)
        }
    }

    package func resizeGraphNoReallyIMeanIt(_ lgraph: LGraph, _ oldSize: KVector, _ newSize: KVector) {
        let contentAlignment = lgraph.getProperty(LayeredOptions.CONTENT_ALIGNMENT) as? ContentAlignment ?? []

        if newSize.x > oldSize.x {
            if contentAlignment.contains(.hCenter) {
                lgraph.offset.x += (newSize.x - oldSize.x) / 2.0
            } else if contentAlignment.contains(.hRight) {
                lgraph.offset.x += newSize.x - oldSize.x
            }
        }

        if newSize.y > oldSize.y {
            if contentAlignment.contains(.vCenter) {
                lgraph.offset.y += (newSize.y - oldSize.y) / 2.0
            } else if contentAlignment.contains(.vBottom) {
                lgraph.offset.y += newSize.y - oldSize.y
            }
        }

        let graphProperties = lgraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []
        if graphProperties.contains(.EXTERNAL_PORTS) && (newSize.x > oldSize.x || newSize.y > oldSize.y) {
            for node in lgraph.getLayerlessNodes() {
                if node.type == .externalPort {
                    let extPortSide = node.getProperty(InternalProperties.EXT_PORT_SIDE) as? PortSide
                    if extPortSide == .east {
                        node.position.x += newSize.x - oldSize.x
                    } else if extPortSide == .south {
                        node.position.y += newSize.y - oldSize.y
                    }
                }
            }
        }

        let lPadding = lgraph.padding
        lgraph.size.x = newSize.x - lPadding.left - lPadding.right
        lgraph.size.y = newSize.y - lPadding.top - lPadding.bottom
    }
}
