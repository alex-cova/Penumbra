import Foundation

/**
 * Graph features used for automatic recognition of the suitability of layout algorithms.
 * 
 * <p><em>Note:</em>
 * Originally, this enumeration was to be found in the {@code properties} package of the core plug-in. However,
 * the meta data compiler needs access to this enumeration. Making it depend on the core plug-in introduces an
 * unfortunate cyclic dependency: to compile the meta-data compiler, we need to compile the core plug-in. To
 * compile the core plug-in, we need the meta-data compiler.</p>
 *
 * @author msp
 * @author cds
 */
package enum GraphFeature {
    
    /// Edges connecting a node with itself.
    case selfLoops
    /// Self-loops routed through a node instead of around it.
    case insideSelfLoops
    /// Multiple edges with the same source and target node.
    case multiEdges
    /// Labels that are associated with edges.
    case edgeLabels
    /// Edges are connected to nodes over ports.
    case ports
    /// Edges that connect nodes from different hierarchy levels and are incident to compound nodes.
    /// - SeeAlso: LayoutOptions.LAYOUT_HIERARCHY
    case compound
    /// Edges that connect nodes from different clusters, but not the cluster parent nodes.
    case clusters
    /// Multiple connected components.
    case disconnected

    /**
     * Returns the description of the graph feature.
     *
     * @return the description
     */
    package func getDescription() -> String {
        return GraphFeature.descriptions[self] ?? ""
    }

    // MARK: - Descriptions

    package static let descriptions: [GraphFeature: String] = [
        .selfLoops: "Edges connecting a node with itself.",
        .insideSelfLoops: "Self-loops routed through a node instead of around it.",
        .multiEdges: "Multiple edges with the same source and target node.",
        .edgeLabels: "Labels that are associated with edges.",
        .ports: "Edges are connected to nodes over ports.",
        .compound: "Edges that connect nodes from different hierarchy levels and are incident to compound nodes.",
        .clusters: "Edges that connect nodes from different clusters, but not the cluster parent nodes.",
        .disconnected: "Multiple connected components."
    ]
    
    // MARK: - Custom String Conversion
    
    package var localizedDescription: String {
        return GraphFeature.descriptions[self] ?? ""
    }
}

// MARK: - Convenience Initializers

extension GraphFeature {
    
    /// Initialize with a raw string value (case-insensitive matching)
    package init?(rawValue: String) {
        let lowerRaw = rawValue.lowercased()
        switch lowerRaw {
        case "selfloops", "self_loops":
            self = .selfLoops
        case "insideselfloops", "inside_self_loops":
            self = .insideSelfLoops
        case "multiedges", "multi_edges":
            self = .multiEdges
        case "edgelabels", "edge_labels":
            self = .edgeLabels
        case "ports":
            self = .ports
        case "compound":
            self = .compound
        case "clusters":
            self = .clusters
        case "disconnected":
            self = .disconnected
        default:
            return nil
        }
    }
    
    /// Raw value representation of the enum case
    package var rawValue: String {
        switch self {
        case .selfLoops: return "selfLoops"
        case .insideSelfLoops: return "insideSelfLoops"
        case .multiEdges: return "multiEdges"
        case .edgeLabels: return "edgeLabels"
        case .ports: return "ports"
        case .compound: return "compound"
        case .clusters: return "clusters"
        case .disconnected: return "disconnected"
        }
    }
}

// MARK: - CustomStringConvertible

extension GraphFeature: CustomStringConvertible {
    package var description: String {
        return rawValue
    }
}

// MARK: - Equatable

extension GraphFeature: Equatable {}
extension GraphFeature: Hashable {}
