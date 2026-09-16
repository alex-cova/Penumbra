// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/options/InternalProperties.java

import Foundation

package final class org_eclipse_elk_alg_layered_options_InternalProperties {

    // Origin and bendpoints
    package static let ORIGIN = Property<Any>("origin")
    package static let ORIGINAL_BENDPOINTS = Property<Any>("originalBendpoints")
    package static let ORIGINAL_DUMMY_NODE_POSITION = Property<Any>("originalDummyNodePosition")
    package static let ORIGINAL_PORT_CONSTRAINTS = Property<Any>("originalPortConstraints")

    // Long edge properties
    package static let LONG_EDGE_SOURCE = Property<Any>("longEdgeSource")
    package static let LONG_EDGE_TARGET = Property<Any>("longEdgeTarget")
    package static let LONG_EDGE_TARGET_NODE = Property<Any>("longEdgeTargetNode")
    package static let LONG_EDGE_HAS_LABEL_DUMMIES = Property<Any>("longEdgeHasLabelDummies")

    // In-layer properties
    package static let IN_LAYER_LAYOUT_UNIT = Property<Any>("inLayerLayoutUnit")
    package static let IN_LAYER_SUCCESSOR_CONSTRAINTS = Property<Any>("inLayerSuccessorConstraint")
    package static let IN_LAYER_CONSTRAINT = Property<Any>("inLayerConstraint")

    // Graph properties
    package static let GRAPH_PROPERTIES = Property<Any>("graphProperties")
    package static let BARYCENTER_ASSOCIATES = Property<Any>("barycenterAssociates")

    // Model order
    package static let MODEL_ORDER = Property<Int>("modelOrder")
    package static let MAX_MODEL_ORDER_NODES = Property<Int>("modelOrder.maximum")
    package static let CB_NUM_MODEL_ORDER_GROUPS = Property<Int>("modelOrderGroups.cb.number")
    package static let TARGET_NODE_MODEL_ORDER = Property<Int>("targetNode.modelOrder")

    // Cycle properties
    package static let CYCLIC = Property<Bool>("cyclic")
    package static let REVERSED = Property<Bool>("reversed")
    package static let IS_PART_OF_CYCLE = Property<Bool>("isPartOfCycle")

    // Collect properties
    package static let INPUT_COLLECT = Property<Bool>("inputCollect")
    package static let OUTPUT_COLLECT = Property<Bool>("outputCollect")

    // Spacing and layout
    package static let SPACINGS = Property<Any>("spacings")
    package static let PORT_DUMMY = Property<Any>("portDummy")

    // Processor configuration
    package static let PROCESSORS = Property<[AnyGraphProcessor]>("processors")

    // Tarjan's algorithm properties
    package static let TARJAN_LOWLINK = Property<Int>("tarjan.lowlink")
    package static let TARJAN_ID = Property<Int>("tarjan.id")
    package static let TARJAN_ON_STACK = Property<Bool>("tarjan.onStack")

    // External port properties
    package static let EXT_PORT_SIDE = Property<PortSide>("extPort.side")
    package static let EXT_PORT_CONNECTIONS = Property<Set<PortSide>>("extPort.connections")
    package static let EXT_PORT_SIZE = Property<Any>("extPort.size")

    // End label properties
    package static let END_LABEL_EDGE = Property<Any>("endLabel.edge")
    package static let END_LABELS = Property<Any>("endLabels")

    // Edge constraint
    package static let EDGE_CONSTRAINT = Property<Any>("edgeConstraint")

    // Fuzziness for overlap checks
    package static let FUZZINESS: Double = 0.0001

    // Comment properties
    package static let TOP_COMMENTS = Property<Any>("topComments")
    package static let BOTTOM_COMMENTS = Property<Any>("bottomComments")
    package static let COMMENT_CONN_PORT = Property<Any>("commentConnPort")

    // Spline routing properties
    package static let SPLINE_ROUTE_START = Property<Any>("spline.route.start")
    package static let SPLINE_EDGE_CHAIN = Property<Any>("spline.edgeChain")
    package static let SPLINE_NS_PORT_Y_COORD = Property<Double>("spline.nsPortY")
    package static let SPLINE_SURVIVING_EDGE = Property<Any>("spline.survivingEdge")

    // Dummy node type
    package static let DUMMY = Property<Bool>("dummy")

    // Compound / hierarchy properties
    package static let COMPOUND_NODE = Property<Bool>("compoundNode")
    package static let CROSS_HIERARCHY_MAP = Property<Any>("crossHierarchyMap")
    package static let INSIDE_CONNECTIONS = Property<Bool>("insideConnections")

    // Coordinate system
    package static let COORDINATE_SYSTEM_ORIGIN = Property<Any>("coordinateSystemOrigin")

    // Bounding box (used in force layout)
    package static let BB_UPLEFT = Property<Any>("bb.upLeft")
    package static let BB_LOWRIGHT = Property<Any>("bb.lowRight")

    // Random number generator
    package static let RANDOM = Property<Any>("random")

    // Label side
    package static let LABEL_SIDE = Property<Any>("labelSide")

    // Max edge thickness
    package static let MAX_EDGE_THICKNESS = Property<Double>("maxEdgeThickness")

    // Port ratio or position
    package static let PORT_RATIO_OR_POSITION = Property<Double>("portRatioOrPosition")

    // Target offset
    package static let TARGET_OFFSET = Property<Any>("targetOffset")

    // Unnecessary bendpoints (compound graph processing)
    package static let UNNECESSARY_BENDPOINTS = Property<Bool>("unnecessaryBendpoints")

    // Original label edge (compound graph processing)
    package static let ORIGINAL_LABEL_EDGE = Property<Any>("originalLabelEdge")

    // Represented labels (center label dummies)
    package static let REPRESENTED_LABELS = Property<Any>("representedLabels")

    // Hidden nodes (layer constraint preprocessing)
    package static let HIDDEN_NODES = Property<Any>("hiddenNodes")

    // Original opposite port (layer constraint preprocessing)
    package static let ORIGINAL_OPPOSITE_PORT = Property<Any>("originalOppositePort")

    // Long edge before label dummy
    package static let LONG_EDGE_BEFORE_LABEL_DUMMY = Property<Bool>("longEdgeBeforeLabelDummy")

    // External port replaced dummies (hierarchical port constraint processing)
    package static let EXT_PORT_REPLACED_DUMMIES = Property<[LNode]>("extPort.replacedDummies")
    package static let EXT_PORT_REPLACED_DUMMY = Property<LNode>("extPort.replacedDummy")

    // Crossing hint (used by NorthSouthPortPreprocessor)
    package static let CROSSING_HINT = Property<Int>("crossingHint")

    // Self loop properties
    package static let SELF_LOOP_HOLDER = Property<Any>("selfLoopHolder")

    package init() {}
}
