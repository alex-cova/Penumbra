import Foundation

/// Container for spacing values used by the layered algorithm.
/// Pre-calculates spacing options for every pair of node types.
package final class org_eclipse_elk_alg_layered_options_Spacings {

    private let graph: LGraph
    private let n: Int
    private var nodeTypeSpacingOptionsHorizontal: [IProperty?]
    private var nodeTypeSpacingOptionsVertical: [IProperty?]

    // NodeType ordinal mapping (must match Java's enum order)
    private static func ordinal(_ type: NodeType) -> Int {
        switch type {
        case .normal: return 0
        case .longEdge: return 1
        case .externalPort: return 2
        case .northSouthPort: return 3
        case .label: return 4
        case .breakingPoint: return 5
        case .placeholder: return 6
        case .nonShiftingPlaceholder: return 7
        }
    }

    private static let nodeTypeCount = 8

    package init(_ graph: LGraph) {
        self.graph = graph
        self.n = Self.nodeTypeCount
        self.nodeTypeSpacingOptionsHorizontal = Array(repeating: nil, count: n * n)
        self.nodeTypeSpacingOptionsVertical = Array(repeating: nil, count: n * n)
        precalculateNodeTypeSpacings()
    }

    /// No-arg init for fallback — returns defaults from the graph
    package init() {
        self.graph = LGraph()
        self.n = Self.nodeTypeCount
        self.nodeTypeSpacingOptionsHorizontal = Array(repeating: nil, count: n * n)
        self.nodeTypeSpacingOptionsVertical = Array(repeating: nil, count: n * n)
        precalculateNodeTypeSpacings()
    }

    // MARK: - Precalculate

    private func precalculateNodeTypeSpacings() {
        // normal
        nodeTypeSpacing(.NORMAL,
            LayeredOptions.SPACING_NODE_NODE,
            LayeredOptions.SPACING_NODE_NODE_BETWEEN_LAYERS)
        nodeTypeSpacing(.NORMAL, .LONG_EDGE,
            LayeredOptions.SPACING_EDGE_NODE,
            LayeredOptions.SPACING_EDGE_NODE_BETWEEN_LAYERS)
        nodeTypeSpacing(.NORMAL, .NORTH_SOUTH_PORT,
            LayeredOptions.SPACING_EDGE_NODE)
        nodeTypeSpacing(.NORMAL, .EXTERNAL_PORT,
            LayeredOptions.SPACING_EDGE_NODE)
        nodeTypeSpacing(.NORMAL, .LABEL,
            LayeredOptions.SPACING_NODE_NODE,
            LayeredOptions.SPACING_NODE_NODE_BETWEEN_LAYERS)

        // long edge
        nodeTypeSpacing(.LONG_EDGE,
            LayeredOptions.SPACING_EDGE_EDGE,
            LayeredOptions.SPACING_EDGE_EDGE_BETWEEN_LAYERS)
        nodeTypeSpacing(.LONG_EDGE, .NORTH_SOUTH_PORT,
            LayeredOptions.SPACING_EDGE_EDGE)
        nodeTypeSpacing(.LONG_EDGE, .EXTERNAL_PORT,
            LayeredOptions.SPACING_EDGE_EDGE)
        nodeTypeSpacing(.LONG_EDGE, .LABEL,
            LayeredOptions.SPACING_EDGE_NODE,
            LayeredOptions.SPACING_EDGE_NODE_BETWEEN_LAYERS)

        // north-south
        nodeTypeSpacing(.NORTH_SOUTH_PORT,
            LayeredOptions.SPACING_EDGE_EDGE)
        nodeTypeSpacing(.NORTH_SOUTH_PORT, .EXTERNAL_PORT,
            LayeredOptions.SPACING_EDGE_EDGE)
        nodeTypeSpacing(.NORTH_SOUTH_PORT, .LABEL,
            LayeredOptions.SPACING_LABEL_NODE)

        // external
        nodeTypeSpacing(.EXTERNAL_PORT,
            LayeredOptions.SPACING_PORT_PORT)
        nodeTypeSpacing(.EXTERNAL_PORT, .LABEL,
            LayeredOptions.SPACING_LABEL_PORT_VERTICAL,
            LayeredOptions.SPACING_LABEL_PORT_HORIZONTAL)

        // label
        nodeTypeSpacing(.LABEL,
            LayeredOptions.SPACING_EDGE_EDGE,
            LayeredOptions.SPACING_EDGE_EDGE)

        // breaking points
        nodeTypeSpacing(.BREAKING_POINT,
            LayeredOptions.SPACING_EDGE_EDGE,
            LayeredOptions.SPACING_EDGE_EDGE_BETWEEN_LAYERS)
        nodeTypeSpacing(.BREAKING_POINT, .NORMAL,
            LayeredOptions.SPACING_EDGE_NODE,
            LayeredOptions.SPACING_EDGE_NODE_BETWEEN_LAYERS)
        nodeTypeSpacing(.BREAKING_POINT, .LABEL,
            LayeredOptions.SPACING_EDGE_NODE,
            LayeredOptions.SPACING_EDGE_NODE_BETWEEN_LAYERS)
        nodeTypeSpacing(.BREAKING_POINT, .LONG_EDGE,
            LayeredOptions.SPACING_EDGE_NODE,
            LayeredOptions.SPACING_EDGE_NODE_BETWEEN_LAYERS)
    }

    // MARK: - nodeTypeSpacing helpers

    private func idx(_ t1: Int, _ t2: Int) -> Int { t1 * n + t2 }

    private func nodeTypeSpacing(_ nt: NodeType, _ spacing: IProperty) {
        let o = Self.ordinal(nt)
        nodeTypeSpacingOptionsVertical[idx(o, o)] = spacing
    }

    private func nodeTypeSpacing(_ nt: NodeType, _ spacingVert: IProperty, _ spacingHorz: IProperty) {
        let o = Self.ordinal(nt)
        nodeTypeSpacingOptionsVertical[idx(o, o)] = spacingVert
        nodeTypeSpacingOptionsHorizontal[idx(o, o)] = spacingHorz
    }

    private func nodeTypeSpacing(_ n1: NodeType, _ n2: NodeType, _ spacing: IProperty) {
        let o1 = Self.ordinal(n1), o2 = Self.ordinal(n2)
        nodeTypeSpacingOptionsVertical[idx(o1, o2)] = spacing
        nodeTypeSpacingOptionsVertical[idx(o2, o1)] = spacing
    }

    private func nodeTypeSpacing(_ n1: NodeType, _ n2: NodeType, _ spacingVert: IProperty, _ spacingHorz: IProperty) {
        let o1 = Self.ordinal(n1), o2 = Self.ordinal(n2)
        nodeTypeSpacingOptionsVertical[idx(o1, o2)] = spacingVert
        nodeTypeSpacingOptionsVertical[idx(o2, o1)] = spacingVert
        nodeTypeSpacingOptionsHorizontal[idx(o1, o2)] = spacingHorz
        nodeTypeSpacingOptionsHorizontal[idx(o2, o1)] = spacingHorz
    }

    // MARK: - Public API

    package func getHorizontalSpacing(_ e1: LGraphElement, _ e2: LGraphElement) -> Double {
        if let n1 = e1 as? LNode, let n2 = e2 as? LNode {
            return getHorizontalSpacing(n1, n2)
        }
        return 0.0
    }

    package func getHorizontalSpacing(_ n1: LNode, _ n2: LNode) -> Double {
        return getLocalSpacing(n1, n2, nodeTypeSpacingOptionsHorizontal)
    }

    package func getHorizontalSpacing(_ nt1: NodeType, _ nt2: NodeType) -> Double {
        return getLocalSpacing(nt1, nt2, nodeTypeSpacingOptionsHorizontal)
    }

    package func getVerticalSpacing(_ n1: LNode, _ n2: LNode) -> Double {
        return getLocalSpacing(n1, n2, nodeTypeSpacingOptionsVertical)
    }

    package func getVerticalSpacing(_ nt1: NodeType, _ nt2: NodeType) -> Double {
        return getLocalSpacing(nt1, nt2, nodeTypeSpacingOptionsVertical)
    }

    // MARK: - Private

    private func getLocalSpacing(_ n1: LNode, _ n2: LNode, _ mapping: [IProperty?]) -> Double {
        let t1 = n1.type, t2 = n2.type
        let i = idx(Self.ordinal(t1), Self.ordinal(t2))
        guard i >= 0 && i < mapping.count, let layoutOption = mapping[i] else { return 0.0 }
        let s1 = Self.getIndividualOrDefault(n1, layoutOption)
        let s2 = Self.getIndividualOrDefault(n2, layoutOption)
        return max(s1, s2)
    }

    private func getLocalSpacing(_ nt1: NodeType, _ nt2: NodeType, _ mapping: [IProperty?]) -> Double {
        let i = idx(Self.ordinal(nt1), Self.ordinal(nt2))
        guard i >= 0 && i < mapping.count, let layoutOption = mapping[i] else { return 0.0 }
        return Self.asDouble(graph.getProperty(layoutOption))
    }

    /// Returns the individual override for the property or the default from the graph.
    package static func getIndividualOrDefault(_ node: LNode, _ property: IProperty) -> Double {
        // check for individual value
        if node.hasProperty(CoreOptions.SPACING_INDIVIDUAL) {
            if let individualSpacings = node.getProperty(CoreOptions.SPACING_INDIVIDUAL) as? IPropertyHolder {
                if individualSpacings.hasProperty(property) {
                    return asDouble(individualSpacings.getProperty(property))
                }
            }
        }
        // use the common value from the graph
        return asDouble(node.getGraph()?.getProperty(property))
    }

    /// Convert Any? to Double, handling both numeric and string values.
    private static func asDouble(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s) { return d }
        return 0.0
    }
}
