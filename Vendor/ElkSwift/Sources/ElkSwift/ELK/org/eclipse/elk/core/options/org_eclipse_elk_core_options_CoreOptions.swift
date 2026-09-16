// Copyright (c) 2015, 2020 Kiel University and others.
//
// This program and the accompanying materials are made available under the
// terms of the Eclipse Public License 2.0 which is available at
// http://www.eclipse.org/legal/epl-2.0.
//
// SPDX-License-Identifier: EPL-2.0

import Foundation

/**
 * Core layout options provided by ELK. These are the canonical definitions of all built-in
 * layout options that can be set on graph elements.
 */
package final class org_eclipse_elk_core_options_CoreOptions {

    // MARK: - General Options

    /// Identifier of the layout algorithm to use for the graph.
    package static let ALGORITHM = Property<String>(
        "org.eclipse.elk.algorithm")

    /// The resolved layout algorithm data (set internally by the framework).
    package static let RESOLVED_ALGORITHM = Property<LayoutAlgorithmData>(
        "org.eclipse.elk.resolvedAlgorithm")

    /// Overall direction of edges.
    package static let DIRECTION = Property<Direction>(
        "org.eclipse.elk.direction", Direction.UNDEFINED)

    /// Alignment of a node inside its layer.
    package static let ALIGNMENT = Property<Alignment>(
        "org.eclipse.elk.alignment", Alignment.automatic)

    /// Desired aspect ratio of the drawing.
    package static let ASPECT_RATIO = Property<Double>(
        "org.eclipse.elk.aspectRatio", 0.0)

    /// Whether the node should be excluded from the layout.
    package static let NO_LAYOUT = Property<Bool>(
        "org.eclipse.elk.noLayout", false)

    /// Global scaling factor applied to the laid-out graph.
    package static let SCALE_FACTOR = Property<Double>(
        "org.eclipse.elk.scaleFactor", 1.0)

    /// Whether the graph should be animated during layout.
    package static let ANIMATE = Property<Bool>(
        "org.eclipse.elk.animate", true)

    /// Whether a progress bar should be displayed.
    package static let PROGRESS_BAR = Property<Bool>(
        "org.eclipse.elk.progressBar", false)

    /// Whether to zoom to fit the diagram after layout.
    package static let ZOOM_TO_FIT = Property<Bool>(
        "org.eclipse.elk.zoomToFit", false)

    /// Whether ancestors should be included in the layout.
    package static let LAYOUT_ANCESTORS = Property<Bool>(
        "org.eclipse.elk.layoutAncestors", false)

    /// Whether interactive layout mode is enabled.
    package static let INTERACTIVE_LAYOUT = Property<Bool>(
        "org.eclipse.elk.interactive", false)

    // MARK: - Hierarchy

    /// How hierarchy is handled during layout.
    package static let HIERARCHY_HANDLING = Property<HierarchyHandling>(
        "org.eclipse.elk.hierarchyHandling", HierarchyHandling.inherit)

    /// Whether to separately lay out connected components.
    package static let SEPARATE_CONNECTED_COMPONENTS = Property<Bool>(
        "org.eclipse.elk.separateConnectedComponents", true)

    // MARK: - Padding & Spacing

    /// Padding around the content of compound nodes.
    package static let PADDING = Property<ElkPadding>(
        "org.eclipse.elk.padding", ElkPadding())

    /// Spacing between pairs of nodes.
    package static let SPACING_NODE_NODE = Property<Double>(
        "org.eclipse.elk.spacing.nodeNode", 20.0)

    /// Spacing between edges.
    package static let SPACING_EDGE_EDGE = Property<Double>(
        "org.eclipse.elk.spacing.edgeEdge", 10.0)

    /// Spacing between edges and nodes.
    package static let SPACING_EDGE_NODE = Property<Double>(
        "org.eclipse.elk.spacing.edgeNode", 10.0)

    /// Spacing between ports.
    package static let SPACING_PORT_PORT = Property<Double>(
        "org.eclipse.elk.spacing.portPort", 10.0)

    /// Spacing between labels.
    package static let SPACING_LABEL_LABEL = Property<Double>(
        "org.eclipse.elk.spacing.labelLabel", 0.0)

    /// Spacing between labels and nodes.
    package static let SPACING_LABEL_NODE = Property<Double>(
        "org.eclipse.elk.spacing.labelNode", 5.0)

    /// Horizontal spacing between labels and ports.
    package static let SPACING_LABEL_PORT_HORIZONTAL = Property<Double>(
        "org.eclipse.elk.spacing.labelPortHorizontal", 1.0)

    /// Vertical spacing between labels and ports.
    package static let SPACING_LABEL_PORT_VERTICAL = Property<Double>(
        "org.eclipse.elk.spacing.labelPortVertical", 1.0)

    /// Spacing around the ports on each side of a node.
    package static let SPACING_PORTS_SURROUNDING = Property<ElkMargin>(
        "org.eclipse.elk.spacing.portsSurrounding")

    /// Individual spacing overrides per element.
    package static let SPACING_INDIVIDUAL = Property<Any>(
        "org.eclipse.elk.spacing.individual")

    // MARK: - Node Size

    /// Constraints on the size of a node.
    package static let NODE_SIZE_CONSTRAINTS = Property<SizeConstraint>(
        "org.eclipse.elk.nodeSize.constraints", SizeConstraint())

    /// Minimum size of a node.
    package static let NODE_SIZE_MINIMUM = Property<KVector>(
        "org.eclipse.elk.nodeSize.minimum", KVector())

    /// Options that modify how size constraints are applied.
    package static let NODE_SIZE_OPTIONS = Property<SizeOptions>(
        "org.eclipse.elk.nodeSize.options", SizeOptions.defaultMinimumSize)

    /// Whether the node size is fixed for the entire graph.
    package static let NODE_SIZE_FIXED_GRAPH_SIZE = Property<Bool>(
        "org.eclipse.elk.nodeSize.fixedGraphSize", false)

    // MARK: - Node Labels

    /// How node labels are placed.
    package static let NODE_LABELS_PLACEMENT = Property<NodeLabelPlacement>(
        "org.eclipse.elk.nodeLabels.placement", NodeLabelPlacement())

    /// Padding around node labels.
    package static let NODE_LABELS_PADDING = Property<ElkPadding>(
        "org.eclipse.elk.nodeLabels.padding", ElkPadding(5.0))

    // MARK: - Port Options

    /// Constraints on port positions.
    package static let PORT_CONSTRAINTS = Property<PortConstraints>(
        "org.eclipse.elk.portConstraints", PortConstraints.UNDEFINED)

    /// The side of a node on which a port is situated.
    package static let PORT_SIDE = Property<PortSide>(
        "org.eclipse.elk.port.side", PortSide.UNDEFINED)

    /// Offset of ports on the node border.
    package static let PORT_BORDER_OFFSET = Property<Double>(
        "org.eclipse.elk.port.borderOffset", 0.0)

    /// Index to determine port ordering.
    package static let PORT_INDEX = Property<Int>(
        "org.eclipse.elk.port.index", 0)

    /// Anchor point of the port for edge attachment.
    package static let PORT_ANCHOR = Property<KVector>(
        "org.eclipse.elk.port.anchor")

    // MARK: - Port Labels

    /// How port labels are placed.
    package static let PORT_LABELS_PLACEMENT = Property<PortLabelPlacement>(
        "org.eclipse.elk.portLabels.placement", PortLabelPlacement())

    /// Whether port labels should be placed next to the port if possible.
    package static let PORT_LABELS_NEXT_TO_PORT_IF_POSSIBLE = Property<Bool>(
        "org.eclipse.elk.portLabels.nextToPortIfPossible", false)

    /// Whether port labels should be treated as a group.
    package static let PORT_LABELS_TREAT_AS_GROUP = Property<Bool>(
        "org.eclipse.elk.portLabels.treatAsGroup", true)

    // MARK: - Port Alignment

    /// Default port alignment on all sides.
    package static let PORT_ALIGNMENT_DEFAULT = Property<PortAlignment>(
        "org.eclipse.elk.portAlignment.default", PortAlignment.distributed)

    /// Port alignment on the north side.
    package static let PORT_ALIGNMENT_NORTH = Property<PortAlignment>(
        "org.eclipse.elk.portAlignment.north")

    /// Port alignment on the south side.
    package static let PORT_ALIGNMENT_SOUTH = Property<PortAlignment>(
        "org.eclipse.elk.portAlignment.south")

    /// Port alignment on the east side.
    package static let PORT_ALIGNMENT_EAST = Property<PortAlignment>(
        "org.eclipse.elk.portAlignment.east")

    /// Port alignment on the west side.
    package static let PORT_ALIGNMENT_WEST = Property<PortAlignment>(
        "org.eclipse.elk.portAlignment.west")

    // MARK: - Edge Options

    /// How edges are routed.
    package static let EDGE_ROUTING = Property<EdgeRouting>(
        "org.eclipse.elk.edgeRouting", EdgeRouting.UNDEFINED)

    /// The type of an edge (directed, undirected, etc.).
    package static let EDGE_TYPE = Property<EdgeType>(
        "org.eclipse.elk.edgeType", EdgeType.none)

    /// Placement of edge labels.
    package static let EDGE_LABELS_PLACEMENT = Property<EdgeLabelPlacement>(
        "org.eclipse.elk.edgeLabels.placement", EdgeLabelPlacement.center)

    /// Whether edge labels should be placed inline.
    package static let EDGE_LABELS_INLINE = Property<Bool>(
        "org.eclipse.elk.edgeLabels.inline", false)

    /// Junction points of hyperedges.
    package static let JUNCTION_POINTS = Property<KVectorChain>(
        "org.eclipse.elk.junctionPoints")

    // MARK: - Comment & Hypernode

    /// Whether the node is a comment box.
    package static let COMMENT_BOX = Property<Bool>(
        "org.eclipse.elk.commentBox", false)

    /// Whether the node is a hypernode.
    package static let HYPERNODE = Property<Bool>(
        "org.eclipse.elk.hypernode", false)

    // MARK: - Margins

    /// Margins around a node.
    package static let MARGINS = Property<ElkMargin>(
        "org.eclipse.elk.margins", ElkMargin())

    // MARK: - Self Loops

    /// Whether inside self loops are activated.
    package static let INSIDE_SELF_LOOPS_ACTIVATE = Property<Bool>(
        "org.eclipse.elk.insideSelfLoops.activate", false)

    /// Whether inside self loops should be placed using the yo strategy.
    package static let INSIDE_SELF_LOOPS_YO = Property<Bool>(
        "org.eclipse.elk.insideSelfLoops.yo", false)

    // MARK: - Content Alignment

    /// How content of compound nodes is aligned if the node is larger than the content.
    package static let CONTENT_ALIGNMENT = Property<ContentAlignment>(
        "org.eclipse.elk.contentAlignment", ContentAlignment())

    // MARK: - JSON Output Options

    /// Coordinate system for edge coordinates in JSON output.
    package static let JSON_EDGE_COORDS = Property<EdgeCoords>(
        "org.eclipse.elk.json.edgeCoords")

    /// Coordinate system for shape coordinates in JSON output.
    package static let JSON_SHAPE_COORDS = Property<ShapeCoords>(
        "org.eclipse.elk.json.shapeCoords")

    // MARK: - Topdown Layout

    /// Whether topdown layout is enabled.
    package static let TOPDOWN_LAYOUT = Property<Bool>(
        "org.eclipse.elk.topdownLayout", false)

    /// The type of the node in a topdown layout.
    package static let TOPDOWN_NODE_TYPE = Property<TopdownNodeTypes>(
        "org.eclipse.elk.topdown.nodeType")

    /// Scaling factor for topdown layout.
    package static let TOPDOWN_SCALE_FACTOR = Property<Double>(
        "org.eclipse.elk.topdown.scaleFactor", 1.0)

    /// Scale cap for topdown layout.
    package static let TOPDOWN_SCALE_CAP = Property<Double>(
        "org.eclipse.elk.topdown.scaleCap", Double.greatestFiniteMagnitude)

    /// Hierarchical node width for topdown layout.
    package static let TOPDOWN_HIERARCHICAL_NODE_WIDTH = Property<Double>(
        "org.eclipse.elk.topdown.hierarchicalNodeWidth", 200.0)

    /// Aspect ratio for hierarchical nodes in topdown layout.
    package static let TOPDOWN_HIERARCHICAL_NODE_ASPECT_RATIO = Property<Double>(
        "org.eclipse.elk.topdown.hierarchicalNodeAspectRatio", 1.4142135623730951)

    /// The size approximator for topdown layout.
    package static let TOPDOWN_SIZE_APPROXIMATOR = Property<Any>(
        "org.eclipse.elk.topdown.sizeApproximator")

    /// Number of size categories for topdown layout.
    package static let TOPDOWN_SIZE_CATEGORIES = Property<Int>(
        "org.eclipse.elk.topdown.sizeCategories", 4)

    /// Weight for the hierarchical node size category in topdown layout.
    package static let TOPDOWN_SIZE_CATEGORIES_HIERARCHICAL_NODE_WEIGHT = Property<Int>(
        "org.eclipse.elk.topdown.sizeCategories.hierarchicalNodeWeight", 50)

    // MARK: - Child Area (Internal)

    /// Width of the child area (set internally).
    package static let CHILD_AREA_WIDTH = Property<Double>(
        "org.eclipse.elk.childAreaWidth", 0.0)

    /// Height of the child area (set internally).
    package static let CHILD_AREA_HEIGHT = Property<Double>(
        "org.eclipse.elk.childAreaHeight", 0.0)

    private init() {
        // Prevent instantiation
    }
}
