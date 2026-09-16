// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/IntermediateProcessorStrategy.java

import Foundation

package enum org_eclipse_elk_alg_layered_intermediate_IntermediateProcessorStrategy: CaseIterable, EnumOrdinal, org_eclipse_elk_core_alg_ILayoutProcessorFactory {
    package var ordinal: Int {
        Self.allCases.firstIndex(of: self)!
    }

    package typealias G = LGraph

    case DIRECTION_PREPROCESSOR
    case COMMENT_PREPROCESSOR
    case EDGE_AND_LAYER_CONSTRAINT_EDGE_REVERSER
    case INTERACTIVE_EXTERNAL_PORT_POSITIONER
    case PARTITION_PREPROCESSOR
    case LABEL_DUMMY_INSERTER
    case SELF_LOOP_PREPROCESSOR
    case LAYER_CONSTRAINT_PREPROCESSOR
    case PARTITION_MIDPROCESSOR
    case HIGH_DEGREE_NODE_LAYER_PROCESSOR
    case NODE_PROMOTION
    case LAYER_CONSTRAINT_POSTPROCESSOR
    case PARTITION_POSTPROCESSOR
    case HIERARCHICAL_PORT_CONSTRAINT_PROCESSOR
    case SEMI_INTERACTIVE_CROSSMIN_PROCESSOR
    case BREAKING_POINT_INSERTER
    case LONG_EDGE_SPLITTER
    case PORT_SIDE_PROCESSOR
    case INVERTED_PORT_PROCESSOR
    case PORT_LIST_SORTER
    case SORT_BY_INPUT_ORDER_OF_MODEL
    case NORTH_SOUTH_PORT_PREPROCESSOR
    case BREAKING_POINT_PROCESSOR
    case ONE_SIDED_GREEDY_SWITCH
    case TWO_SIDED_GREEDY_SWITCH
    case SELF_LOOP_PORT_RESTORER
    case ALTERNATING_LAYER_UNZIPPER
    case SINGLE_EDGE_GRAPH_WRAPPER
    case IN_LAYER_CONSTRAINT_PROCESSOR
    case END_NODE_PORT_LABEL_MANAGEMENT_PROCESSOR
    case LABEL_AND_NODE_SIZE_PROCESSOR
    case INNERMOST_NODE_MARGIN_CALCULATOR
    case SELF_LOOP_ROUTER
    case COMMENT_NODE_MARGIN_CALCULATOR
    case END_LABEL_PREPROCESSOR
    case LABEL_DUMMY_SWITCHER
    case CENTER_LABEL_MANAGEMENT_PROCESSOR
    case LABEL_SIDE_SELECTOR
    case HYPEREDGE_DUMMY_MERGER
    case HIERARCHICAL_PORT_DUMMY_SIZE_PROCESSOR
    case LAYER_SIZE_AND_GRAPH_HEIGHT_CALCULATOR
    case HIERARCHICAL_PORT_POSITION_PROCESSOR
    case CONSTRAINTS_POSTPROCESSOR
    case COMMENT_POSTPROCESSOR
    case HYPERNODE_PROCESSOR
    case HIERARCHICAL_PORT_ORTHOGONAL_EDGE_ROUTER
    case LONG_EDGE_JOINER
    case SELF_LOOP_POSTPROCESSOR
    case BREAKING_POINT_REMOVER
    case NORTH_SOUTH_PORT_POSTPROCESSOR
    case HORIZONTAL_COMPACTOR
    case LABEL_DUMMY_REMOVER
    case FINAL_SPLINE_BENDPOINTS_CALCULATOR
    case END_LABEL_SORTER
    case REVERSED_EDGE_RESTORER
    case END_LABEL_POSTPROCESSOR
    case HIERARCHICAL_NODE_RESIZER
    case DIRECTION_POSTPROCESSOR

    package func create() -> any org_eclipse_elk_core_alg_ILayoutProcessor {
        switch self {
        case .BREAKING_POINT_INSERTER:
            return org_eclipse_elk_alg_layered_intermediate_wrapping_BreakingPointInserter()
        case .BREAKING_POINT_PROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_wrapping_BreakingPointProcessor()
        case .BREAKING_POINT_REMOVER:
            return org_eclipse_elk_alg_layered_intermediate_wrapping_BreakingPointRemover()
        case .CENTER_LABEL_MANAGEMENT_PROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_LabelManagementProcessor(true)
        case .COMMENT_NODE_MARGIN_CALCULATOR:
            return org_eclipse_elk_alg_layered_intermediate_CommentNodeMarginCalculator()
        case .COMMENT_POSTPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_CommentPostprocessor()
        case .COMMENT_PREPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_CommentPreprocessor()
        case .CONSTRAINTS_POSTPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_ConstraintsPostprocessor()
        case .DIRECTION_POSTPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_GraphTransformer(.TO_INTERNAL_LTR)
        case .DIRECTION_PREPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_GraphTransformer(.TO_INPUT_DIRECTION)
        case .EDGE_AND_LAYER_CONSTRAINT_EDGE_REVERSER:
            return org_eclipse_elk_alg_layered_intermediate_EdgeAndLayerConstraintEdgeReverser()
        case .END_LABEL_POSTPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_EndLabelPostprocessor()
        case .END_LABEL_PREPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_EndLabelPreprocessor()
        case .END_NODE_PORT_LABEL_MANAGEMENT_PROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_LabelManagementProcessor(false)
        case .FINAL_SPLINE_BENDPOINTS_CALCULATOR:
            assertionFailure("Spline routing is not supported")
            return _NoOpProcessor()
        case .HIERARCHICAL_NODE_RESIZER:
            return org_eclipse_elk_alg_layered_intermediate_HierarchicalNodeResizingProcessor()
        case .HIERARCHICAL_PORT_CONSTRAINT_PROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_HierarchicalPortConstraintProcessor()
        case .HIERARCHICAL_PORT_DUMMY_SIZE_PROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_HierarchicalPortDummySizeProcessor()
        case .HIERARCHICAL_PORT_ORTHOGONAL_EDGE_ROUTER:
            return org_eclipse_elk_alg_layered_intermediate_HierarchicalPortOrthogonalEdgeRouter()
        case .HIERARCHICAL_PORT_POSITION_PROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_HierarchicalPortPositionProcessor()
        case .HIGH_DEGREE_NODE_LAYER_PROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_HighDegreeNodeLayeringProcessor()
        case .HORIZONTAL_COMPACTOR:
            return org_eclipse_elk_alg_layered_intermediate_compaction_HorizontalGraphCompactor()
        case .HYPEREDGE_DUMMY_MERGER:
            return org_eclipse_elk_alg_layered_intermediate_HyperedgeDummyMerger()
        case .HYPERNODE_PROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_HypernodesProcessor()
        case .IN_LAYER_CONSTRAINT_PROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_InLayerConstraintProcessor()
        case .INNERMOST_NODE_MARGIN_CALCULATOR:
            return org_eclipse_elk_alg_layered_intermediate_InnermostNodeMarginCalculator()
        case .INTERACTIVE_EXTERNAL_PORT_POSITIONER:
            return org_eclipse_elk_alg_layered_intermediate_InteractiveExternalPortPositioner()
        case .INVERTED_PORT_PROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_InvertedPortProcessor()
        case .LABEL_AND_NODE_SIZE_PROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_LabelAndNodeSizeProcessor()
        case .LABEL_DUMMY_INSERTER:
            return org_eclipse_elk_alg_layered_intermediate_LabelDummyInserter()
        case .LABEL_DUMMY_REMOVER:
            return org_eclipse_elk_alg_layered_intermediate_LabelDummyRemover()
        case .LABEL_DUMMY_SWITCHER:
            return org_eclipse_elk_alg_layered_intermediate_LabelDummySwitcher()
        case .LABEL_SIDE_SELECTOR:
            return org_eclipse_elk_alg_layered_intermediate_LabelSideSelector()
        case .END_LABEL_SORTER:
            return org_eclipse_elk_alg_layered_intermediate_EndLabelSorter()
        case .LAYER_CONSTRAINT_POSTPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_LayerConstraintPostprocessor()
        case .LAYER_CONSTRAINT_PREPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_LayerConstraintPreprocessor()
        case .LAYER_SIZE_AND_GRAPH_HEIGHT_CALCULATOR:
            return org_eclipse_elk_alg_layered_intermediate_LayerSizeAndGraphHeightCalculator()
        case .LONG_EDGE_JOINER:
            return org_eclipse_elk_alg_layered_intermediate_LongEdgeJoiner()
        case .LONG_EDGE_SPLITTER:
            return org_eclipse_elk_alg_layered_intermediate_LongEdgeSplitter()
        case .NODE_PROMOTION:
            return org_eclipse_elk_alg_layered_intermediate_NodePromotion()
        case .NORTH_SOUTH_PORT_POSTPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_NorthSouthPortPostprocessor()
        case .NORTH_SOUTH_PORT_PREPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_NorthSouthPortPreprocessor()
        case .ONE_SIDED_GREEDY_SWITCH:
            return org_eclipse_elk_alg_layered_p3order_LayerSweepCrossingMinimizer(.ONE_SIDED_GREEDY_SWITCH)
        case .PARTITION_MIDPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_PartitionMidprocessor()
        case .PARTITION_POSTPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_PartitionPostprocessor()
        case .PARTITION_PREPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_PartitionPreprocessor()
        case .PORT_LIST_SORTER:
            return org_eclipse_elk_alg_layered_intermediate_PortListSorter()
        case .PORT_SIDE_PROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_PortSideProcessor()
        case .REVERSED_EDGE_RESTORER:
            return org_eclipse_elk_alg_layered_intermediate_ReversedEdgeRestorer()
        case .SELF_LOOP_PREPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_SelfLoopPreProcessor()
        case .SELF_LOOP_PORT_RESTORER:
            return org_eclipse_elk_alg_layered_intermediate_SelfLoopPortRestorer()
        case .ALTERNATING_LAYER_UNZIPPER:
            return org_eclipse_elk_alg_layered_intermediate_unzipping_AlternatingLayerUnzipper()
        case .SELF_LOOP_POSTPROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_SelfLoopPostProcessor()
        case .SELF_LOOP_ROUTER:
            return org_eclipse_elk_alg_layered_intermediate_SelfLoopRouter()
        case .SEMI_INTERACTIVE_CROSSMIN_PROCESSOR:
            return org_eclipse_elk_alg_layered_intermediate_SemiInteractiveCrossMinProcessor()
        case .SINGLE_EDGE_GRAPH_WRAPPER:
            return org_eclipse_elk_alg_layered_intermediate_wrapping_SingleEdgeGraphWrapper()
        case .SORT_BY_INPUT_ORDER_OF_MODEL:
            return org_eclipse_elk_alg_layered_intermediate_SortByInputModelProcessor()
        case .TWO_SIDED_GREEDY_SWITCH:
            return org_eclipse_elk_alg_layered_p3order_LayerSweepCrossingMinimizer(.TWO_SIDED_GREEDY_SWITCH)
        }
    }
}

private struct _NoOpProcessor: ILayoutProcessor {
    typealias G = LGraph
    func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}

package enum org_eclipse_elk_alg_layered_intermediate_GraphTransformer_Mode {
    case TO_INPUT_DIRECTION
    case TO_INTERNAL_LTR
}

extension org_eclipse_elk_alg_layered_intermediate_GraphTransformer_Mode {
    package static var defaults: org_eclipse_elk_alg_layered_intermediate_GraphTransformer_Mode {
        .TO_INPUT_DIRECTION
    }
}


// Stub types: need typealias G and process method for ILayoutProcessor conformance
extension org_eclipse_elk_alg_layered_intermediate_wrapping_BreakingPointInserter: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}
extension org_eclipse_elk_alg_layered_intermediate_wrapping_BreakingPointProcessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}
extension org_eclipse_elk_alg_layered_intermediate_wrapping_BreakingPointRemover: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}
extension org_eclipse_elk_alg_layered_intermediate_LabelManagementProcessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}
// Classes that already declare : ILayoutProcessor and have process method - no redundant conformance needed
// CommentNodeMarginCalculator, CommentPostprocessor, CommentPreprocessor, ConstraintsPostprocessor
// EdgeAndLayerConstraintEdgeReverser, EndLabelPostprocessor, EndLabelSorter, DummySelfLoopProcessor

extension org_eclipse_elk_alg_layered_intermediate_GraphTransformer: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
// EndLabelPreprocessor has process method but doesn't declare : ILayoutProcessor
extension org_eclipse_elk_alg_layered_intermediate_EndLabelPreprocessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {
        process(graph, monitor: progressMonitor)
    }
}
extension org_eclipse_elk_alg_layered_intermediate_HierarchicalNodeResizingProcessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_HierarchicalPortConstraintProcessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_HierarchicalPortDummySizeProcessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_HierarchicalPortOrthogonalEdgeRouter: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_HierarchicalPortPositionProcessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_HighDegreeNodeLayeringProcessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_compaction_HorizontalGraphCompactor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_HyperedgeDummyMerger: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}
extension org_eclipse_elk_alg_layered_intermediate_HypernodesProcessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}
extension org_eclipse_elk_alg_layered_intermediate_InLayerConstraintProcessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_InnermostNodeMarginCalculator: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_InteractiveExternalPortPositioner: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}
extension org_eclipse_elk_alg_layered_intermediate_InvertedPortProcessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_LabelAndNodeSizeProcessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_LabelDummyInserter: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_LabelDummyRemover: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_LabelDummySwitcher: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_LabelSideSelector: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_LayerConstraintPostprocessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_LayerConstraintPreprocessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_LayerSizeAndGraphHeightCalculator: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_LongEdgeJoiner: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_LongEdgeSplitter: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_NodePromotion: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}
extension org_eclipse_elk_alg_layered_intermediate_NorthSouthPortPostprocessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_NorthSouthPortPreprocessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
// LayerSweepCrossingMinimizer already conforms to ILayoutProcessor via ILayoutPhase in CrossingMinimizationStrategy
extension org_eclipse_elk_alg_layered_intermediate_PartitionMidprocessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}
extension org_eclipse_elk_alg_layered_intermediate_PartitionPostprocessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}
extension org_eclipse_elk_alg_layered_intermediate_PartitionPreprocessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}
extension org_eclipse_elk_alg_layered_intermediate_PortListSorter: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_PortSideProcessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
extension org_eclipse_elk_alg_layered_intermediate_ReversedEdgeRestorer: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
// SelfLoopPreProcessor declares its own ILayoutProcessor conformance
// SelfLoopPortRestorer declares its own ILayoutProcessor conformance
extension org_eclipse_elk_alg_layered_intermediate_unzipping_AlternatingLayerUnzipper: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}
// SelfLoopPostProcessor declares its own ILayoutProcessor conformance
// SelfLoopRouter declares its own ILayoutProcessor conformance
extension org_eclipse_elk_alg_layered_intermediate_SemiInteractiveCrossMinProcessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}
extension org_eclipse_elk_alg_layered_intermediate_wrapping_SingleEdgeGraphWrapper: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
    package func process(_ graph: LGraph, _ progressMonitor: IElkProgressMonitor) {}
}
extension org_eclipse_elk_alg_layered_intermediate_SortByInputModelProcessor: org_eclipse_elk_core_alg_ILayoutProcessor {
    package typealias G = LGraph
}
