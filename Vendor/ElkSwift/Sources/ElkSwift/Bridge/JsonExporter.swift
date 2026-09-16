// JsonExporter: Converts an ElkNode graph back to [String: Any] JSON dictionaries.
// This replaces the excluded org.eclipse.elk.graph.json.JsonExporter.

import Foundation

package class JsonExporter {

    package init() {}

    /// Export an ElkNode graph to a JSON-compatible dictionary.
    package func export(_ graph: ElkNode) -> [String: Any] {
        return exportNode(graph)
    }

    // MARK: - Node Export

    private func exportNode(_ node: ElkNode) -> [String: Any] {
        var dict: [String: Any] = [:]

        if let id = node.identifier {
            dict["id"] = id
        }

        dict["x"] = node.x
        dict["y"] = node.y
        dict["width"] = node.width
        dict["height"] = node.height

        // Labels
        if !node.labels.isEmpty {
            dict["labels"] = node.labels.map { exportLabel($0) }
        }

        // Ports
        if !node.ports.isEmpty {
            dict["ports"] = node.ports.map { exportPort($0) }
        }

        // Children (recursive)
        if !node.children.isEmpty {
            dict["children"] = node.children.map { exportNode($0) }
        }

        // Edges
        if !node.containedEdges.isEmpty {
            dict["edges"] = node.containedEdges.map { exportEdge($0) }
        }

        // Layout options
        let props = exportLayoutOptions(node)
        if !props.isEmpty {
            dict["layoutOptions"] = props
        }

        return dict
    }

    // MARK: - Port Export

    private func exportPort(_ port: ElkPort) -> [String: Any] {
        var dict: [String: Any] = [:]

        if let id = port.identifier {
            dict["id"] = id
        }

        dict["x"] = port.x
        dict["y"] = port.y
        dict["width"] = port.width
        dict["height"] = port.height

        if !port.labels.isEmpty {
            dict["labels"] = port.labels.map { exportLabel($0) }
        }

        let props = exportLayoutOptions(port)
        if !props.isEmpty {
            dict["layoutOptions"] = props
        }

        return dict
    }

    // MARK: - Label Export

    private func exportLabel(_ label: ElkLabel) -> [String: Any] {
        var dict: [String: Any] = [:]

        if let id = label.identifier {
            dict["id"] = id
        }

        dict["text"] = label.text
        dict["x"] = label.x
        dict["y"] = label.y
        dict["width"] = label.width
        dict["height"] = label.height

        return dict
    }

    // MARK: - Edge Export

    private func exportEdge(_ edge: ElkEdge) -> [String: Any] {
        var dict: [String: Any] = [:]

        if let id = edge.identifier {
            dict["id"] = id
        }

        // Sources and targets as ID arrays
        dict["sources"] = edge.sources.compactMap { shapeId($0) }
        dict["targets"] = edge.targets.compactMap { shapeId($0) }

        // Sections (routing information)
        if !edge.sections.isEmpty {
            dict["sections"] = edge.sections.map { exportSection($0) }
        }

        // Labels
        if !edge.labels.isEmpty {
            dict["labels"] = edge.labels.map { exportLabel($0) }
        }

        let props = exportLayoutOptions(edge)
        if !props.isEmpty {
            dict["layoutOptions"] = props
        }

        return dict
    }

    // MARK: - Section Export

    private func exportSection(_ section: ElkEdgeSection) -> [String: Any] {
        var dict: [String: Any] = [:]

        if let id = section.identifier {
            dict["id"] = id
        }

        dict["startPoint"] = ["x": section.startX, "y": section.startY]
        dict["endPoint"] = ["x": section.endX, "y": section.endY]

        if !section.bendPoints.isEmpty {
            dict["bendPoints"] = section.bendPoints.map { bp -> [String: Any] in
                ["x": bp.x, "y": bp.y]
            }
        }

        return dict
    }

    // MARK: - Helpers

    private func shapeId(_ shape: ElkConnectableShape) -> String? {
        if let node = shape as? ElkNode {
            return node.identifier
        } else if let port = shape as? ElkPort {
            return port.identifier
        }
        return nil
    }

    private func exportLayoutOptions(_ holder: IPropertyHolder) -> [String: Any] {
        let allProps = holder.getAllProperties()
        var result: [String: Any] = [:]
        for (key, value) in allProps {
            // Only export string-representable values
            if let s = value as? String {
                result[key] = s
            } else if let n = value as? Double {
                result[key] = n
            } else if let n = value as? Int {
                result[key] = n
            } else if let b = value as? Bool {
                result[key] = b
            }
            // Skip complex objects (LayoutAlgorithmData, etc.)
        }
        return result
    }
}
