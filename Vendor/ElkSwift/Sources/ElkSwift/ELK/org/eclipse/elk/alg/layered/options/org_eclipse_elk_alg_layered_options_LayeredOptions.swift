// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/Layered.melk
import Foundation

package final class org_eclipse_elk_alg_layered_options_LayeredOptions {

    // Algorithm identifier
    package static let ALGORITHM_ID = "org.eclipse.elk.layered"

    // p1/p2 + reverse blocker option keys
    package static let LAYERING_LAYER_CONSTRAINT = Property<Any>("org.eclipse.elk.layered.layering.layerConstraint")
    package static let EDGE_LABELS_PLACEMENT = Property<Any>("org.eclipse.elk.edgeLabels.placement")
    package static let NODE_LABELS_PLACEMENT = Property<Any>("org.eclipse.elk.nodeLabels.placement")
    package static let PORT_CONSTRAINTS = Property<Any>("org.eclipse.elk.portConstraints")
    package static let THOROUGHNESS = Property<Int>("org.eclipse.elk.layered.thoroughness")

    // Spacing options (defaults from ELK CoreOptions / LayeredMetaDataProvider)
    package static let SPACING_EDGE_EDGE = Property<Double>("org.eclipse.elk.spacing.edgeEdge", 10.0)
    package static let SPACING_NODE_NODE = Property<Double>("org.eclipse.elk.spacing.nodeNode", 20.0)
    package static let SPACING_PORT_PORT = Property<Double>("org.eclipse.elk.spacing.portPort", 10.0)
    package static let SPACING_PORTS_SURROUNDING = Property<Any>("org.eclipse.elk.spacing.portsSurrounding")
    package static let SPACING_EDGE_NODE = Property<Double>("org.eclipse.elk.spacing.edgeNode", 10.0)
    package static let SPACING_EDGE_LABEL = Property<Double>("org.eclipse.elk.spacing.edgeLabel", 2.0)
    package static let SPACING_LABEL_LABEL = Property<Double>("org.eclipse.elk.spacing.labelLabel", 0.0)
    package static let SPACING_LABEL_PORT = Property<Double>("org.eclipse.elk.spacing.labelPort", 5.0)
    package static let SPACING_LABEL_NODE = Property<Double>("org.eclipse.elk.spacing.labelNode", 5.0)
    package static let SPACING_LABEL_PORT_HORIZONTAL = Property<Double>("org.eclipse.elk.spacing.labelPortHorizontal", 1.0)
    package static let SPACING_LABEL_PORT_VERTICAL = Property<Double>("org.eclipse.elk.spacing.labelPortVertical", 1.0)
    package static let SPACING_EDGE_EDGE_BETWEEN_LAYERS = Property<Double>("org.eclipse.elk.layered.spacing.edgeEdgeBetweenLayers", 10.0)
    package static let SPACING_EDGE_NODE_BETWEEN_LAYERS = Property<Double>("org.eclipse.elk.layered.spacing.edgeNodeBetweenLayers", 10.0)
    package static let SPACING_NODE_NODE_BETWEEN_LAYERS = Property<Double>("org.eclipse.elk.layered.spacing.nodeNodeBetweenLayers", 20.0)
    package static let SPACING_COMMENT_COMMENT = Property<Double>("org.eclipse.elk.spacing.commentComment", 10.0)
    package static let SPACING_COMMENT_NODE = Property<Double>("org.eclipse.elk.spacing.commentNode", 10.0)
    package static let SPACING_COMPONENT_COMPONENT = Property<Double>("org.eclipse.elk.spacing.componentComponent", 20.0)
    package static let SPACING_BASE_VALUE = Property<Double>("org.eclipse.elk.spacing.baseValue", 0.0)

    // Priority options
    package static let PRIORITY = Property<Int>("org.eclipse.elk.priority")
    package static let PRIORITY_DIRECTION = Property<Int>("org.eclipse.elk.layered.priority.direction")
    package static let PRIORITY_SHORTNESS = Property<Int>("org.eclipse.elk.layered.priority.shortness")
    package static let PRIORITY_STRAIGHTNESS = Property<Int>("org.eclipse.elk.layered.priority.straightness")

    package static let INTERACTIVE_REFERENCE_POINT = Property<Any>("org.eclipse.elk.layered.interactiveReferencePoint")

    // Node placement options
    package static let NODE_PLACEMENT_FAVOR_STRAIGHT_EDGES = Property<Bool>("org.eclipse.elk.layered.nodePlacement.favorStraightEdges")
    package static let NODE_PLACEMENT_BK_EDGE_STRAIGHTENING = Property<Any>("org.eclipse.elk.layered.nodePlacement.bk.edgeStraightening")
    package static let NODE_PLACEMENT_BK_FIXED_ALIGNMENT = Property<Any>("org.eclipse.elk.layered.nodePlacement.bk.fixedAlignment")
    package static let NODE_PLACEMENT_LINEAR_SEGMENTS_DEFLECTION_DAMPENING = Property<Double>("org.eclipse.elk.layered.nodePlacement.linearSegments.deflectionDampening")
    package static let NODE_PLACEMENT_STRATEGY = Property<Any>("org.eclipse.elk.layered.nodePlacement.strategy")

    // Model-order group options
    package static let CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CYCLE_BREAKING_ID = Property<Any>("org.eclipse.elk.layered.considerModelOrder.groupModelOrder.cycleBreakingId")
    package static let CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CROSSING_MINIMIZATION_ID = Property<Any>("org.eclipse.elk.layered.considerModelOrder.groupModelOrder.crossingMinimizationId")
    package static let CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_COMPONENT_GROUP_ID = Property<Any>("org.eclipse.elk.layered.considerModelOrder.groupModelOrder.componentGroupId")
    package static let CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CB_GROUP_ORDER_STRATEGY = Property<Any>("org.eclipse.elk.layered.considerModelOrder.groupModelOrder.cbGroupOrderStrategy")
    package static let CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CM_GROUP_ORDER_STRATEGY = Property<Any>("org.eclipse.elk.layered.considerModelOrder.groupModelOrder.cmGroupOrderStrategy")
    package static let CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CM_ENFORCED_GROUP_ORDERS = Property<Any>("org.eclipse.elk.layered.considerModelOrder.groupModelOrder.cmEnforcedGroupOrders")
    package static let CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CB_PREFERRED_SOURCE_ID = Property<Any>("org.eclipse.elk.layered.considerModelOrder.groupModelOrder.cbPreferredSourceId")
    package static let CONSIDER_MODEL_ORDER_GROUP_MODEL_ORDER_CB_PREFERRED_TARGET_ID = Property<Any>("org.eclipse.elk.layered.considerModelOrder.groupModelOrder.cbPreferredTargetId")

    // Core options delegated from CoreOptions
    package static let DIRECTION = Property<Direction>("org.eclipse.elk.direction")
    package static let LAYERING_LAYER_ID = Property<Int>("org.eclipse.elk.layered.layering.layerId")
    package static let CROSSING_MINIMIZATION_IN_LAYER_PRED_OF = Property<Any>("org.eclipse.elk.layered.crossingMinimization.inLayerPredOf")
    package static let CROSSING_MINIMIZATION_IN_LAYER_SUCC_OF = Property<Any>("org.eclipse.elk.layered.crossingMinimization.inLayerSuccOf")

    // Core options
    package static let NODE_SIZE_CONSTRAINTS = Property<Any>("org.eclipse.elk.nodeSize.constraints")
    package static let NODE_SIZE_OPTIONS = Property<Any>("org.eclipse.elk.nodeSize.options")
    package static let NODE_SIZE_MINIMUM = Property<Any>("org.eclipse.elk.nodeSize.minimum")
    package static let NODE_SIZE_FIXED_GRAPH_SIZE = Property<Bool>("org.eclipse.elk.nodeSize.fixedGraphSize")
    package static let NO_LAYOUT = Property<Bool>("org.eclipse.elk.noLayout")
    package static let LAYERING_LAYER_CHOICE_CONSTRAINT = Property<Int>("org.eclipse.elk.layered.layering.layerChoiceConstraint")
    package static let PORT_LABELS_PLACEMENT = Property<Any>("org.eclipse.elk.portLabels.placement")
    package static let PORT_LABELS_NEXT_TO_PORT_IF_POSSIBLE = Property<Bool>("org.eclipse.elk.portLabels.nextToPortIfPossible")
    package static let PORT_ALIGNMENT_DEFAULT = Property<Any>("org.eclipse.elk.portAlignment.default")
    package static let PORT_SIDE = Property<Any>("org.eclipse.elk.port.side")
    package static let PORT_BORDER_OFFSET = Property<Double>("org.eclipse.elk.port.borderOffset")
    package static let PORT_ANCHOR = Property<KVector>("org.eclipse.elk.port.anchor")
    package static let PORT_INDEX = Property<Int>("org.eclipse.elk.port.index")
    package static let PADDING = Property<Any>("org.eclipse.elk.padding")
    package static let ALIGNMENT = Property<Any>("org.eclipse.elk.alignment")
    package static let NODE_LABELS_PADDING = Property<Any>("org.eclipse.elk.nodeLabels.padding")
    package static let ASPECT_RATIO = Property<Double>("org.eclipse.elk.aspectRatio")
    package static let POSITION = Property<Any>("org.eclipse.elk.position")
    package static let DESIRED_POSITION = Property<Any>("org.eclipse.elk.position")
    package static let INSIDE_SELF_LOOPS_ACTIVATE = Property<Bool>("org.eclipse.elk.insideSelfLoops.activate")
    package static let INSIDE_SELF_LOOPS_YO = Property<Bool>("org.eclipse.elk.insideSelfLoops.yo")
    package static let SEPARATE_CONNECTED_COMPONENTS = Property<Bool>("org.eclipse.elk.separateConnectedComponents")
    package static let CONTENT_ALIGNMENT = Property<Any>("org.eclipse.elk.contentAlignment")
    package static let EDGE_ROUTING = Property<Any>("org.eclipse.elk.edgeRouting")
    package static let EDGE_ROUTING_SPLINES_MODE = Property<Any>("org.eclipse.elk.edgeRouting.splines.mode")
    package static let EDGE_ROUTING_SELF_LOOP_DISTRIBUTION = Property<SelfLoopDistributionStrategy>("org.eclipse.elk.layered.edgeRouting.selfLoopDistribution", SelfLoopDistributionStrategy.NORTH)
    package static let EDGE_ROUTING_SELF_LOOP_ORDERING = Property<SelfLoopOrderingStrategy>("org.eclipse.elk.layered.edgeRouting.selfLoopOrdering", SelfLoopOrderingStrategy.STACKED)
    package static let SPACING_NODE_SELF_LOOP = Property<Double>("org.eclipse.elk.layered.spacing.nodeSelfLoop", 10.0)
    package static let EDGE_ROUTING_POLYLINE_SLOPED_EDGE_ZONE_WIDTH = Property<Double>("org.eclipse.elk.layered.edgeRouting.polyline.slopedEdgeZoneWidth")
    package static let EDGE_THICKNESS = Property<Double>("org.eclipse.elk.edge.thickness", 1.0)
    package static let JUNCTION_POINTS = Property<KVectorChain>("org.eclipse.elk.junctionPoints")
    package static let COMMENT_BOX = Property<Bool>("org.eclipse.elk.commentBox")
    package static let HYPERNODE = Property<Bool>("org.eclipse.elk.hypernode")
    package static let HIERARCHY_HANDLING = Property<Any>("org.eclipse.elk.hierarchyHandling")
    package static let INTERACTIVE_LAYOUT = Property<Bool>("org.eclipse.elk.interactive")
    package static let EDGE_LABELS_SIDE_SELECTION = Property<Any>("org.eclipse.elk.layered.edgeLabels.sideSelection")
    package static let EDGE_LABELS_INLINE = Property<Bool>("org.eclipse.elk.edgeLabels.inline")
    package static let UNNECESSARY_BENDPOINTS = Property<Bool>("org.eclipse.elk.layered.unnecessaryBendpoints")
    package static let DIRECTION_CONGRUENCY = Property<Any>("org.eclipse.elk.layered.directionCongruency")
    package static let FEEDBACK_EDGES = Property<Bool>("org.eclipse.elk.layered.feedbackEdges")
    package static let MERGE_EDGES = Property<Bool>("org.eclipse.elk.layered.mergeEdges")
    package static let MERGE_HIERARCHY_EDGES = Property<Bool>("org.eclipse.elk.layered.mergeHierarchyEdges")
    package static let RANDOM_SEED = Property<Int>("org.eclipse.elk.randomSeed")
    package static let MIN_WIDTH = Property<Double>("org.eclipse.elk.layered.minWidth")
    package static let MIN_HEIGHT = Property<Double>("org.eclipse.elk.layered.minHeight")

    // Crossing minimization options
    package static let CROSSING_MINIMIZATION_STRATEGY = Property<Any>("org.eclipse.elk.layered.crossingMinimization.strategy")
    package static let CROSSING_MINIMIZATION_GREEDY_SWITCH_ACTIVATION_THRESHOLD = Property<Int>("org.eclipse.elk.layered.crossingMinimization.greedySwitchActivationThreshold")
    package static let CROSSING_MINIMIZATION_GREEDY_SWITCH_TYPE = Property<Any>("org.eclipse.elk.layered.crossingMinimization.greedySwitchType")
    package static let CROSSING_MINIMIZATION_GREEDY_SWITCH_HIERARCHICAL_TYPE = Property<Any>("org.eclipse.elk.layered.crossingMinimization.greedySwitchHierarchicalType")
    package static let CROSSING_MINIMIZATION_SEMI_INTERACTIVE = Property<Bool>("org.eclipse.elk.layered.crossingMinimization.semiInteractive")
    package static let CROSSING_MINIMIZATION_FORCE_NODE_MODEL_ORDER = Property<Bool>("org.eclipse.elk.layered.crossingMinimization.forceNodeModelOrder")
    package static let CROSSING_MINIMIZATION_HIERARCHICAL_SWEEPINESS = Property<Double>("org.eclipse.elk.layered.crossingMinimization.hierarchicalSweepiness")
    package static let CROSSING_MINIMIZATION_POSITION_CHOICE_CONSTRAINT = Property<Int>("org.eclipse.elk.layered.crossingMinimization.positionChoiceConstraint")
    package static let CROSSING_MINIMIZATION_POSITION_ID = Property<Int>("org.eclipse.elk.layered.crossingMinimization.positionId")

    // Model order options
    package static let CONSIDER_MODEL_ORDER_STRATEGY = Property<Any>("org.eclipse.elk.layered.considerModelOrder.strategy")
    package static let CONSIDER_MODEL_ORDER_CROSSING_COUNTER_NODE_INFLUENCE = Property<Double>("org.eclipse.elk.layered.considerModelOrder.crossingCounterNodeInfluence")
    package static let CONSIDER_MODEL_ORDER_CROSSING_COUNTER_PORT_INFLUENCE = Property<Double>("org.eclipse.elk.layered.considerModelOrder.crossingCounterPortInfluence")
    package static let CONSIDER_MODEL_ORDER_NO_MODEL_ORDER = Property<Bool>("org.eclipse.elk.layered.considerModelOrder.noModelOrder")
    package static let CONSIDER_MODEL_ORDER_COMPONENTS = Property<Any>("org.eclipse.elk.layered.considerModelOrder.components")
    package static let CONSIDER_MODEL_ORDER_LONG_EDGE_STRATEGY = Property<Any>("org.eclipse.elk.layered.considerModelOrder.longEdgeStrategy")

    // Layering options
    package static let LAYERING_STRATEGY = Property<Any>("org.eclipse.elk.layered.layering.strategy")
    package static let LAYERING_NODE_PROMOTION_STRATEGY = Property<Any>("org.eclipse.elk.layered.layering.nodePromotion.strategy")
    package static let LAYERING_COFFMAN_GRAHAM_LAYER_BOUND = Property<Int>("org.eclipse.elk.layered.layering.coffmanGraham.layerBound")
    package static let LAYER_UNZIPPING_STRATEGY = Property<Any>("org.eclipse.elk.layered.layerUnzippingStrategy")

    // Cycle breaking
    package static let CYCLE_BREAKING_STRATEGY = Property<Any>("org.eclipse.elk.layered.cycleBreaking.strategy")

    // Allow non-flow ports to switch sides (default false)
    package static let ALLOW_NON_FLOW_PORTS_TO_SWITCH_SIDES = Property<Bool>("org.eclipse.elk.layered.allowNonFlowPortsToSwitchSides")

    // Compaction options
    package static let COMPACTION_POST_COMPACTION_STRATEGY = Property<Any>("org.eclipse.elk.layered.compaction.postCompaction.strategy")
    package static let COMPACTION_POST_COMPACTION_CONSTRAINTS = Property<Any>("org.eclipse.elk.layered.compaction.postCompaction.constraints")
    package static let COMPACTION_CONNECTED_COMPONENTS = Property<Bool>("org.eclipse.elk.layered.compaction.connectedComponents")

    // High degree node options
    package static let HIGH_DEGREE_NODES_TREATMENT = Property<Bool>("org.eclipse.elk.layered.highDegreeNodes.treatment")
    package static let HIGH_DEGREE_NODES_THRESHOLD = Property<Int>("org.eclipse.elk.layered.highDegreeNodes.threshold")
    package static let HIGH_DEGREE_NODES_TREE_HEIGHT = Property<Int>("org.eclipse.elk.layered.highDegreeNodes.treeHeight")

    // Partitioning
    package static let PARTITIONING_ACTIVATE = Property<Bool>("org.eclipse.elk.partitioning.activate")

    // Generate IDs
    package static let GENERATE_POSITION_AND_LAYER_IDS = Property<Bool>("org.eclipse.elk.layered.generatePositionAndLayerIds")
    package static let PORT_SORTING_STRATEGY = Property<Any>("org.eclipse.elk.layered.portSortingStrategy")
    package static let EDGE_LABELS_CENTER_LABEL_PLACEMENT_STRATEGY = Property<Any>("org.eclipse.elk.layered.edgeLabels.centerLabelPlacementStrategy")

    // Wrapping options
    package static let WRAPPING_STRATEGY = Property<Any>("org.eclipse.elk.layered.wrapping.strategy")
    package static let WRAPPING_ADDITIONAL_EDGE_SPACING = Property<Double>("org.eclipse.elk.layered.wrapping.additionalEdgeSpacing")
    package static let WRAPPING_CORRECTION_FACTOR = Property<Double>("org.eclipse.elk.layered.wrapping.correctionFactor")
    package static let WRAPPING_CUTTING_STRATEGY = Property<Any>("org.eclipse.elk.layered.wrapping.cutting.strategy")
    package static let WRAPPING_CUTTING_CUTS = Property<Any>("org.eclipse.elk.layered.wrapping.cutting.cuts")
    package static let WRAPPING_CUTTING_CUTS_MSD_FREEDOM = Property<Int>("org.eclipse.elk.layered.wrapping.cutting.msd.freedom")
    package static let WRAPPING_VALIDIFY_STRATEGY = Property<Any>("org.eclipse.elk.layered.wrapping.validify.strategy")
    package static let WRAPPING_VALIDIFY_FORBID_SELF_CROSSING_REDUCE_COUNTER = Property<Int>("org.eclipse.elk.layered.wrapping.validify.forbiddenIndices")
    package static let WRAPPING_MULTI_EDGE_IMPROVE_CUTS = Property<Bool>("org.eclipse.elk.layered.wrapping.multiEdge.improveCuts")
    package static let WRAPPING_MULTI_EDGE_IMPROVE_WRAPPED_EDGES = Property<Bool>("org.eclipse.elk.layered.wrapping.multiEdge.improveWrappedEdges")
    package static let WRAPPING_MULTI_EDGE_DISTANCE_PENALTY = Property<Double>("org.eclipse.elk.layered.wrapping.multiEdge.distancePenalty")

    package init() {}
}
