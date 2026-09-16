/*******************************************************************************
 * Copyright (c) 2015, 2020 Kiel University and others.
 * 
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0.
 *
 * SPDX-License-Identifier: EPL-2.0
 *******************************************************************************/
import Foundation

// Stub types for constructs not yet fully transpiled
package class LabelManagementOptions {
    package static let LABEL_MANAGER = Property<Any?>("org.eclipse.elk.labels.labelManager")
}

/// Simple random number generator (java.util.Random equivalent).
/// Uses a linear congruential generator matching Java's java.util.Random algorithm.
package class Random {
    package var seed: UInt64

    package init() {
        self.seed = UInt64(bitPattern: Int64(Date().timeIntervalSince1970 * 1000)) ^ 0x5DEECE66D
    }

    package init(seed: Int) {
        self.seed = (UInt64(bitPattern: Int64(seed)) ^ 0x5DEECE66D) & 0xFFFFFFFFFFFF
    }

    private func next(_ bits: Int) -> Int32 {
        seed = (seed &* 0x5DEECE66D &+ 0xB) & 0xFFFFFFFFFFFF
        return Int32(truncatingIfNeeded: seed >> (48 - bits))
    }

    package func nextInt() -> Int {
        return Int(next(32))
    }

    package func nextInt(_ bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        // Java's algorithm for nextInt(bound)
        if bound & (bound - 1) == 0 { // power of 2
            return Int((Int64(bound) &* Int64(next(31))) >> 31)
        }
        var bits: Int32, val: Int32
        repeat {
            bits = next(31)
            val = bits % Int32(bound)
        } while bits &- val &+ Int32(bound) &- 1 < 0
        return Int(val)
    }

    package func nextDouble() -> Double {
        let result = Double((Int64(next(26)) << 27) + Int64(next(27))) / Double(1 << 53)

        return result
    }

    package func nextLong() -> Int64 {
        let result = (Int64(next(32)) << 32) + Int64(next(32))

        return result
    }

    package func nextBoolean() -> Bool {
        let result = next(1) != 0

        return result
    }

    /// Matches java.util.Random.nextFloat(): next(24) / (float)(1 << 24)
    /// Uses only ONE next() call, unlike nextDouble() which uses TWO.
    package func nextFloat() -> Float {
        return Float(next(24)) / Float(1 << 24)
    }

    /// Matches java.util.Random.setSeed(long seed)
    package func setSeed(_ seed: Int) {

        self.seed = (UInt64(bitPattern: Int64(seed)) ^ 0x5DEECE66D) & 0xFFFFFFFFFFFF

    }
}

// Main class translation
package final class GraphConfigurator {
    
    // Constants
    
    /** intermediate processing configuration for basic graphs. */
    package static let BASELINE_PROCESSING_CONFIGURATION: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.INNERMOST_NODE_MARGIN_CALCULATOR)
            .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.LABEL_AND_NODE_SIZE_PROCESSOR)
            .addBefore(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.LAYER_SIZE_AND_GRAPH_HEIGHT_CALCULATOR)
            .addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.END_LABEL_SORTER)
    
    /** intermediate processors for label management. */
    package static let LABEL_MANAGEMENT_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.CENTER_LABEL_MANAGEMENT_PROCESSOR)
            .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.END_NODE_PORT_LABEL_MANAGEMENT_PROCESSOR)
    
    /** intermediate processors for hierarchical layout. */
    package static let HIERARCHICAL_ADDITIONS: LayoutProcessorConfiguration<LayeredPhases, LGraph> =
        LayoutProcessorConfiguration<LayeredPhases, LGraph>.create()
            .addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.HIERARCHICAL_NODE_RESIZER)
    
    // Processor Caching
    
    /** The algorithm assembler we use to assemble our algorithm configurations. */
    package let algorithmAssembler: AlgorithmAssembler<LayeredPhases, LGraph> =
        AlgorithmAssembler<LayeredPhases, LGraph>.create(LayeredPhases.self)
    
    // Graph Preprocessing (Property Configuration)
    
    /** the minimal spacing between edges, so edges won't overlap. */
    package static let MIN_EDGE_SPACING: Double = 2.0
    
    /**
     * Set special layout options for the layered graph.
     * 
     * @param lgraph a new layered graph
     */
    package func configureGraphProperties(_ lgraph: LGraph) {
        // check the bounds of some layout options

        let edgeSpacing = lgraph.getProperty(LayeredOptions.SPACING_EDGE_EDGE) as? Double ?? 0.0
        if edgeSpacing < GraphConfigurator.MIN_EDGE_SPACING {
            lgraph.setProperty(LayeredOptions.SPACING_EDGE_EDGE, GraphConfigurator.MIN_EDGE_SPACING)
        }

        let directionRaw = lgraph.getProperty(LayeredOptions.DIRECTION)
        let direction = directionRaw as? Direction ?? .UNDEFINED
        if direction == .UNDEFINED {
            lgraph.setProperty(LayeredOptions.DIRECTION, LGraphUtil.getDirection(lgraph))
        }
        // set the random number generator based on the random seed option
        let randomSeed: Int
        if let i = lgraph.getProperty(LayeredOptions.RANDOM_SEED) as? Int {
            randomSeed = i
        } else if let d = lgraph.getProperty(LayeredOptions.RANDOM_SEED) as? Double {
            randomSeed = Int(d)
        } else {
            randomSeed = 1  // Java .melk default is 1; 0 would create unseeded (non-deterministic) Random
        }
        if randomSeed == 0 {
            lgraph.setProperty(InternalProperties.RANDOM, Random())
        } else {
            lgraph.setProperty(InternalProperties.RANDOM, Random(seed: randomSeed))
        }

        let favorStraightness = lgraph.getProperty(LayeredOptions.NODE_PLACEMENT_FAVOR_STRAIGHT_EDGES) as? Bool
        if favorStraightness == nil {
            let edgeRouting = Self.resolveEdgeRouting(lgraph)
            lgraph.setProperty(LayeredOptions.NODE_PLACEMENT_FAVOR_STRAIGHT_EDGES, edgeRouting == .ORTHOGONAL)
        }

        // copy the port constraints to keep a list of original port constraints
        copyPortContraints(lgraph)

        // pre-calculate spacing information
        let spacings = Spacings(lgraph)
        lgraph.setProperty(InternalProperties.SPACINGS, spacings)
    }
    
    package func copyPortContraints(_ lgraph: LGraph) {
        lgraph.getLayerlessNodes().forEach { lnode in
            copyPortConstraints(lnode)
        }
        lgraph.getLayers().forEach { layer in
            layer.getNodes().forEach { lnode in
                copyPortConstraints(lnode)
            }
        }
    }
    
    package func copyPortConstraints(_ node: LNode) {
        let originalPortconstraints = node.getProperty(LayeredOptions.PORT_CONSTRAINTS) as? PortConstraints ?? .FREE
        node.setProperty(InternalProperties.ORIGINAL_PORT_CONSTRAINTS, originalPortconstraints)
        
        if let nestedGraph = node.getNestedGraph() {
            copyPortContraints(nestedGraph)
        }
    }
    
    // Updating the Configuration
    
    /**
     * Rebuilds the configuration to include all processors required to layout the given graph. The list
     * of processors is attached to the graph in the {@link InternalProperties#PROCESSORS} property.
     * 
     * @param lgraph the graph to layout.
     */
    package func prepareGraphForLayout(_ lgraph: LGraph) {
        // Make sure the graph properties are sensible
        configureGraphProperties(lgraph)
        
        // Setup the algorithm assembler
        algorithmAssembler.reset()
        
        algorithmAssembler.setPhase(LayeredPhases.P1_CYCLE_BREAKING, lgraph.getProperty(LayeredOptions.CYCLE_BREAKING_STRATEGY) ?? CycleBreakingStrategy.GREEDY)
        algorithmAssembler.setPhase(LayeredPhases.P2_LAYERING, lgraph.getProperty(LayeredOptions.LAYERING_STRATEGY) ?? LayeringStrategy.NETWORK_SIMPLEX)
        algorithmAssembler.setPhase(LayeredPhases.P3_NODE_ORDERING, lgraph.getProperty(LayeredOptions.CROSSING_MINIMIZATION_STRATEGY) ?? CrossingMinimizationStrategy.LAYER_SWEEP)
        algorithmAssembler.setPhase(LayeredPhases.P4_NODE_PLACEMENT, lgraph.getProperty(LayeredOptions.NODE_PLACEMENT_STRATEGY) ?? NodePlacementStrategy.BRANDES_KOEPF)
        algorithmAssembler.setPhase(LayeredPhases.P5_EDGE_ROUTING, EdgeRouterFactory.factoryFor(Self.resolveEdgeRouting(lgraph)))

        if let config = getPhaseIndependentLayoutProcessorConfiguration(lgraph) {
            algorithmAssembler.addProcessorConfiguration(config)
        }
        
        lgraph.setProperty(InternalProperties.PROCESSORS, algorithmAssembler.build(lgraph))
    }
    
    /**
     * Returns an intermediate processing configuration with processors not tied to specific phases.
     * 
     * @param lgraph the layered graph to be processed. The configuration may vary depending on certain
     *               properties of the graph.
     * @return intermediate processing configuration. May be {@code null}.
     */
    package func getPhaseIndependentLayoutProcessorConfiguration(_ lgraph: LGraph) -> LayoutProcessorConfiguration<LayeredPhases, LGraph>? {
        
        let graphProperties = lgraph.getProperty(InternalProperties.GRAPH_PROPERTIES) as? Set<GraphProperties> ?? []
        
        // Basic configuration
        var configuration = LayoutProcessorConfiguration<LayeredPhases, LGraph>.create(from: GraphConfigurator.BASELINE_PROCESSING_CONFIGURATION)
        
        // Hierarchical layout. 
        //  Note that the recursive graph layout engine made sure that at this point
        //  'INCLUDE_CHILDREN' has been propagated to all parent nodes with 'INHERIT'.
        //  Thus, every lgraph of the hierarchical lgraph structure is configured with the following additions. 
        let hierarchyHandling = lgraph.getProperty(LayeredOptions.HIERARCHY_HANDLING) as? HierarchyHandling ?? .INHERIT
        if hierarchyHandling == .INCLUDE_CHILDREN {
            configuration.addAll(GraphConfigurator.HIERARCHICAL_ADDITIONS)
        }
        
        // Port side processor, put to first slot only if requested and routing is orthogonal
        if lgraph.getProperty(LayeredOptions.FEEDBACK_EDGES) as? Bool ?? false {
            configuration.addBefore(LayeredPhases.P1_CYCLE_BREAKING, IntermediateProcessorStrategy.PORT_SIDE_PROCESSOR)
        } else {
            configuration.addBefore(LayeredPhases.P3_NODE_ORDERING, IntermediateProcessorStrategy.PORT_SIDE_PROCESSOR)
        }
        
        // If the graph has a label manager, so add label management additions
        if lgraph.getProperty(LabelManagementOptions.LABEL_MANAGER) != nil {
            configuration.addAll(GraphConfigurator.LABEL_MANAGEMENT_ADDITIONS)
        }
        
        // If the graph should be laid out interactively or you really want it,
        // add the layers and positions to the nodes.
        if lgraph.getProperty(LayeredOptions.INTERACTIVE_LAYOUT) as? Bool ?? false ||
            lgraph.getProperty(LayeredOptions.GENERATE_POSITION_AND_LAYER_IDS) as? Bool ?? false {
            configuration.addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.CONSTRAINTS_POSTPROCESSOR)
        }
        
        // graph transformations for unusual layout directions
        let direction = lgraph.getProperty(LayeredOptions.DIRECTION) as? Direction ?? .RIGHT
        switch direction {
        case .LEFT, .DOWN, .UP:
            configuration
                .addBefore(LayeredPhases.P1_CYCLE_BREAKING, IntermediateProcessorStrategy.DIRECTION_PREPROCESSOR)
                .addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.DIRECTION_POSTPROCESSOR)
        default:
            // This is either RIGHT or UNDEFINED, which is just mapped to RIGHT. Either way, we
            // don't need any processors here
            break
        }
        
        // Additional dependencies
        if graphProperties.contains(.COMMENTS) {
            configuration
                .addBefore(LayeredPhases.P1_CYCLE_BREAKING, IntermediateProcessorStrategy.COMMENT_PREPROCESSOR)
                .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.COMMENT_NODE_MARGIN_CALCULATOR)
                .addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.COMMENT_POSTPROCESSOR)
        }
        
        // Node-Promotion application for reduction of dummy nodes after layering
        let nodePromotionStrategy = lgraph.getProperty(LayeredOptions.LAYERING_NODE_PROMOTION_STRATEGY) as? NodePromotionStrategy ?? .NONE
        if nodePromotionStrategy != .NONE {
            configuration.addBefore(LayeredPhases.P3_NODE_ORDERING, IntermediateProcessorStrategy.NODE_PROMOTION)
        }
        
        // Preserve certain partitions during layering
        if graphProperties.contains(.PARTITIONS) {
            configuration.addBefore(LayeredPhases.P1_CYCLE_BREAKING, IntermediateProcessorStrategy.PARTITION_PREPROCESSOR)
            configuration.addBefore(LayeredPhases.P2_LAYERING, IntermediateProcessorStrategy.PARTITION_MIDPROCESSOR)
            configuration.addBefore(LayeredPhases.P3_NODE_ORDERING, IntermediateProcessorStrategy.PARTITION_POSTPROCESSOR)
        }
        
        // Additional horizontal compaction depends on orthogonal edge routing
        let compactionStrategy = lgraph.getProperty(LayeredOptions.COMPACTION_POST_COMPACTION_STRATEGY) as? GraphCompactionStrategy ?? .NONE
        let edgeRouting = Self.resolveEdgeRouting(lgraph)
        if compactionStrategy != .NONE && edgeRouting != .POLYLINE {
            configuration.addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.HORIZONTAL_COMPACTOR)
        }
        
        // Move trees of high degree nodes to separate layers
        if lgraph.getProperty(LayeredOptions.HIGH_DEGREE_NODES_TREATMENT) as? Bool ?? false {
            configuration.addBefore(LayeredPhases.P3_NODE_ORDERING, IntermediateProcessorStrategy.HIGH_DEGREE_NODE_LAYER_PROCESSOR)
        }
        
        // Introduce in-layer constraints to preserve the order of regular nodes
        if lgraph.getProperty(LayeredOptions.CROSSING_MINIMIZATION_SEMI_INTERACTIVE) as? Bool ?? false {
            configuration.addBefore(LayeredPhases.P3_NODE_ORDERING, IntermediateProcessorStrategy.SEMI_INTERACTIVE_CROSSMIN_PROCESSOR)
        }
        
        // Configure greedy switch
        //  Note that in the case of hierarchical layout, the configuration may further be adjusted by
        //  ElkLayered#reviewAndCorrectHierarchicalProcessors(...)
        if GraphConfigurator.activateGreedySwitchFor(lgraph) {
            let greedySwitchType: GreedySwitchType
            if GraphConfigurator.isHierarchicalLayout(lgraph) {
                greedySwitchType = lgraph.getProperty(LayeredOptions.CROSSING_MINIMIZATION_GREEDY_SWITCH_HIERARCHICAL_TYPE) as? GreedySwitchType ?? .OFF
            } else {
                greedySwitchType = lgraph.getProperty(LayeredOptions.CROSSING_MINIMIZATION_GREEDY_SWITCH_TYPE) as? GreedySwitchType ?? .TWO_SIDED
            }
            let internalGreedyType = (greedySwitchType == .ONE_SIDED)
                ? IntermediateProcessorStrategy.ONE_SIDED_GREEDY_SWITCH
                : IntermediateProcessorStrategy.TWO_SIDED_GREEDY_SWITCH
            configuration.addBefore(LayeredPhases.P4_NODE_PLACEMENT, internalGreedyType)
        }
        
        switch lgraph.getProperty(LayeredOptions.LAYER_UNZIPPING_STRATEGY) as? String {
        case "ALTERNATING":
            configuration.addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.ALTERNATING_LAYER_UNZIPPER)
        default:
            break
        }
        
        // Wrapping of graphs
        switch lgraph.getProperty(LayeredOptions.WRAPPING_STRATEGY) as? String {
        case "SINGLE_EDGE":
            configuration.addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.SINGLE_EDGE_GRAPH_WRAPPER)
        case "MULTI_EDGE":
            configuration
                .addBefore(LayeredPhases.P3_NODE_ORDERING, IntermediateProcessorStrategy.BREAKING_POINT_INSERTER)
                .addBefore(LayeredPhases.P4_NODE_PLACEMENT, IntermediateProcessorStrategy.BREAKING_POINT_PROCESSOR)
                .addAfter(LayeredPhases.P5_EDGE_ROUTING, IntermediateProcessorStrategy.BREAKING_POINT_REMOVER)
        default: // OFF
            break
        }
        
        if (lgraph.getProperty(LayeredOptions.CONSIDER_MODEL_ORDER_STRATEGY) as? OrderingStrategy ?? .NONE) != .NONE {
            configuration
                .addBefore(LayeredPhases.P3_NODE_ORDERING, IntermediateProcessorStrategy.SORT_BY_INPUT_ORDER_OF_MODEL)
        }
        
        return configuration
    }
    
    /**
     * Greedy switch may be activated if the following holds.
     * 
     * <h3>Hierarchical layout</h3>
     * <ol>
     *  <li>the {@link LayeredOptions#CROSSING_MINIMIZATION_GREEDY_SWITCH_HIERARCHICAL_TYPE} is set to something 
     *      different than OFF</li>
     * </ol>
     * 
     * <h3>Non-hierarchical layout</h3>
     * <ol>
     *  <li>no interactive crossing minimization is performed</li>
     *  <li>the {@link LayeredOptions#CROSSING_MINIMIZATION_GREEDY_SWITCH_TYPE} option is set to something different 
     *      than OFF</li>
     *  <li>the activationThreshold is larger than or equal to the graph's number of nodes (or '0')</li>
     * </ol>
     * @return {@code true} if above condition holds, {@code false} otherwise.
     */
    package static func activateGreedySwitchFor(_ lgraph: LGraph) -> Bool {
        
        // First, check the hierarchical case
        if isHierarchicalLayout(lgraph) {
            // Note that we only activate it for the root in the hierarchical case and rely on
            // ElkLayered#reviewAndCorrectHierarchicalProcessors(...) to properly set it for the whole hierarchy.
            // Also, interactive crossing minimization is not allowed/applicable for hierarchical layout
            // (and thus doesn't have to be checked here).
            return lgraph.getParentNode() == nil && lgraph.getProperty(
                    LayeredOptions.CROSSING_MINIMIZATION_GREEDY_SWITCH_HIERARCHICAL_TYPE) as? GreedySwitchType != .OFF
        }
        
        // Second, if not hierarchical, check the slightly more complex non-hierarchical case
        let greedySwitchType = lgraph.getProperty(LayeredOptions.CROSSING_MINIMIZATION_GREEDY_SWITCH_TYPE) as? GreedySwitchType ?? .TWO_SIDED
        let interactiveCrossMin =
            lgraph.getProperty(LayeredOptions.CROSSING_MINIMIZATION_SEMI_INTERACTIVE) as? Bool ?? false ||
            lgraph.getProperty(LayeredOptions.CROSSING_MINIMIZATION_STRATEGY) as? CrossingMinimizationStrategy == .INTERACTIVE
        let activationThreshold =
            lgraph.getProperty(LayeredOptions.CROSSING_MINIMIZATION_GREEDY_SWITCH_ACTIVATION_THRESHOLD) as? Int ?? 0
        let graphSize = lgraph.getLayerlessNodes().count
        
        return !interactiveCrossMin 
                && greedySwitchType != .OFF 
                && (activationThreshold == 0 || activationThreshold > graphSize)
    }
    
    package static func isHierarchicalLayout(_ lgraph: LGraph) -> Bool {
        return lgraph.getProperty(LayeredOptions.HIERARCHY_HANDLING) as? HierarchyHandling == .INCLUDE_CHILDREN
    }

    /// Resolves the edge routing setting from the graph, handling both typed EdgeRouting enum and raw String values.
    package static func resolveEdgeRouting(_ lgraph: LGraph) -> EdgeRouting {
        if let er = lgraph.getProperty(LayeredOptions.EDGE_ROUTING) as? EdgeRouting {
            return er
        }
        if let s = lgraph.getProperty(LayeredOptions.EDGE_ROUTING) as? String,
           let er = EdgeRouting(rawValue: s) {
            return er
        }
        return .ORTHOGONAL
    }
}
