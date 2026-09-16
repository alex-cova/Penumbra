// JsonImporter: Converts [String: Any] JSON dictionaries into an ElkNode graph.
// This replaces the excluded org.eclipse.elk.graph.json.JsonImporter.

import Foundation

package class JsonImporter {

    /// Map of element IDs to their ElkConnectableShape (nodes and ports).
    private var shapeIndex: [String: ElkConnectableShape] = [:]

    /// Deferred edge descriptors to resolve after all nodes/ports are created.
    private var deferredEdges: [(dict: [String: Any], parent: ElkNode)] = []

    package init() {}

    /// Transform a JSON dictionary into an ElkNode graph.
    package func transform(_ jsonGraph: [String: Any]) -> ElkNode {
        shapeIndex.removeAll()
        deferredEdges.removeAll()

        let root = importNode(jsonGraph, parent: nil)

        // Resolve deferred edges now that all nodes/ports are indexed.
        for (edgeDict, parent) in deferredEdges {
            importEdge(edgeDict, containingNode: parent)
        }

        return root
    }

    // MARK: - Node Import

    private func importNode(_ dict: [String: Any], parent: ElkNode?) -> ElkNode {
        let node = ElkNodeImpl2()
        node.parent = parent

        if let id = dict["id"] as? String {
            node.identifier = id
            shapeIndex[id] = node
        }

        node.x = asDouble(dict["x"])
        node.y = asDouble(dict["y"])
        node.width = asDouble(dict["width"])
        node.height = asDouble(dict["height"])

        // Layout options
        if let layoutOptions = dict["layoutOptions"] as? [String: Any] {
            applyLayoutOptions(layoutOptions, to: node)
        }
        // Also support "properties" key
        if let properties = dict["properties"] as? [String: Any] {
            applyLayoutOptions(properties, to: node)
        }

        // Labels
        if let labelsArray = dict["labels"] as? [[String: Any]] {
            for labelDict in labelsArray {
                let label = importLabel(labelDict)
                label.parent = node
                node.labels.append(label)
            }
        }

        // Ports
        if let portsArray = dict["ports"] as? [[String: Any]] {
            for portDict in portsArray {
                let port = importPort(portDict, parent: node)
                node.ports.append(port)
            }
        }

        // Children (recursive)
        if let childrenArray = dict["children"] as? [[String: Any]] {
            for childDict in childrenArray {
                let child = importNode(childDict, parent: node)
                node.children.append(child)
            }
        }

        // Edges (defer resolution until all shapes are indexed)
        if let edgesArray = dict["edges"] as? [[String: Any]] {
            for edgeDict in edgesArray {
                deferredEdges.append((edgeDict, node))
            }
        }

        return node
    }

    // MARK: - Port Import

    private func importPort(_ dict: [String: Any], parent: ElkNode) -> ElkPort {
        let port = ElkPortImpl2()
        port.parent = parent

        if let id = dict["id"] as? String {
            port.identifier = id
            shapeIndex[id] = port
        }

        port.x = asDouble(dict["x"])
        port.y = asDouble(dict["y"])
        port.width = asDouble(dict["width"])
        port.height = asDouble(dict["height"])

        if let layoutOptions = dict["layoutOptions"] as? [String: Any] {
            applyLayoutOptions(layoutOptions, to: port)
        }
        if let properties = dict["properties"] as? [String: Any] {
            applyLayoutOptions(properties, to: port)
        }

        if let labelsArray = dict["labels"] as? [[String: Any]] {
            for labelDict in labelsArray {
                let label = importLabel(labelDict)
                label.parent = port
                port.labels.append(label)
            }
        }

        return port
    }

    // MARK: - Label Import

    private func importLabel(_ dict: [String: Any]) -> ElkLabelImpl2 {
        let label = ElkLabelImpl2()

        if let id = dict["id"] as? String {
            label.identifier = id
        }
        if let text = dict["text"] as? String {
            label.text = text
        }

        label.x = asDouble(dict["x"])
        label.y = asDouble(dict["y"])
        label.width = asDouble(dict["width"])
        label.height = asDouble(dict["height"])

        if let layoutOptions = dict["layoutOptions"] as? [String: Any] {
            applyLayoutOptions(layoutOptions, to: label)
        }

        return label
    }

    // MARK: - Edge Import

    private func importEdge(_ dict: [String: Any], containingNode: ElkNode) {
        let edge = ElkEdgeImpl2()
        edge.containingNode = containingNode

        if let id = dict["id"] as? String {
            edge.identifier = id
        }

        // Resolve sources
        if let sourcesArray = dict["sources"] as? [String] {
            for sourceId in sourcesArray {
                if let shape = shapeIndex[sourceId] {
                    edge.sources.append(shape)
                    shape.outgoingEdges.append(edge)
                }
            }
        }

        // Resolve targets
        if let targetsArray = dict["targets"] as? [String] {
            for targetId in targetsArray {
                if let shape = shapeIndex[targetId] {
                    edge.targets.append(shape)
                    shape.incomingEdges.append(edge)
                }
            }
        }

        // Labels
        if let labelsArray = dict["labels"] as? [[String: Any]] {
            for labelDict in labelsArray {
                let label = importLabel(labelDict)
                label.parent = edge
                edge.labels.append(label)
            }
        }

        if let layoutOptions = dict["layoutOptions"] as? [String: Any] {
            applyLayoutOptions(layoutOptions, to: edge)
        }
        if let properties = dict["properties"] as? [String: Any] {
            applyLayoutOptions(properties, to: edge)
        }

        containingNode.containedEdges.append(edge)
    }

    // MARK: - Layout Options

    /// Normalize short ELK option keys (e.g. "elk.direction") to their full
    /// canonical form ("org.eclipse.elk.direction").
    private static func canonicalKey(_ key: String) -> String {
        if key.hasPrefix("elk.") {
            return "org.eclipse." + key
        }
        return key
    }

    /// Best-effort parse of a layout option value to the correct Swift type.
    private static func parseOptionValue(_ key: String, _ value: Any) -> Any {
        if value is Double || value is Int || value is Bool {
            return value
        }
        guard let s = value as? String else { return value }

        // Booleans
        if s == "true" || s == "TRUE" { return true }
        if s == "false" || s == "FALSE" { return false }

        // Doubles (spacing, etc.)
        if let d = Double(s) { return d }

        // Direction enum
        if let dir = Direction(rawValue: s) { return dir }

        // EdgeRouting enum
        if let er = EdgeRouting(rawValue: s) { return er }

        // HierarchyHandling enum
        switch s {
        case "INHERIT": return HierarchyHandling.INHERIT
        case "INCLUDE_CHILDREN": return HierarchyHandling.INCLUDE_CHILDREN
        case "SEPARATE_CHILDREN": return HierarchyHandling.SEPARATE_CHILDREN
        default: break
        }

        // OrderingStrategy enum
        if let os = OrderingStrategy(rawValue: s) { return os }

        // FixedAlignment enum
        if let fa = FixedAlignment(rawValue: s) { return fa }

        // EdgeLabelPlacement enum
        switch s.uppercased() {
        case "CENTER": return EdgeLabelPlacement.center
        case "HEAD": return EdgeLabelPlacement.head
        case "TAIL": return EdgeLabelPlacement.tail
        default: break
        }

        // EdgeLabelSideSelection enum
        switch s.uppercased() {
        case "ALWAYS_UP": return EdgeLabelSideSelection.ALWAYS_UP
        case "ALWAYS_DOWN": return EdgeLabelSideSelection.ALWAYS_DOWN
        case "DIRECTION_UP": return EdgeLabelSideSelection.DIRECTION_UP
        case "DIRECTION_DOWN": return EdgeLabelSideSelection.DIRECTION_DOWN
        case "SMART_UP": return EdgeLabelSideSelection.SMART_UP
        case "SMART_DOWN": return EdgeLabelSideSelection.SMART_DOWN
        default: break
        }

        // ContentAlignment — OptionSet parsed from space-separated flags
        if s.contains("H_") || s.contains("V_") {
            var alignment = ContentAlignment()
            for part in s.split(separator: " ") {
                switch part {
                case "H_LEFT": alignment.insert(.hLeft)
                case "H_CENTER": alignment.insert(.hCenter)
                case "H_RIGHT": alignment.insert(.hRight)
                case "V_TOP": alignment.insert(.vTop)
                case "V_CENTER": alignment.insert(.vCenter)
                case "V_BOTTOM": alignment.insert(.vBottom)
                default: break
                }
            }
            if !alignment.isEmpty { return alignment }
        }

        // GraphCompactionStrategy enum (no RawRepresentable)
        switch s {
        case "NONE": return GraphCompactionStrategy.NONE
        case "LEFT": return GraphCompactionStrategy.LEFT
        case "RIGHT": return GraphCompactionStrategy.RIGHT
        case "LEFT_RIGHT_CONSTRAINT_LOCKING": return GraphCompactionStrategy.LEFT_RIGHT_CONSTRAINT_LOCKING
        case "LEFT_RIGHT_CONNECTION_LOCKING": return GraphCompactionStrategy.LEFT_RIGHT_CONNECTION_LOCKING
        case "EDGE_LENGTH": return GraphCompactionStrategy.EDGE_LENGTH
        default: break
        }

        // WrappingStrategy enum (no RawRepresentable)
        switch s {
        case "OFF": return WrappingStrategy.OFF
        case "SINGLE_EDGE": return WrappingStrategy.SINGLE_EDGE
        case "MULTI_EDGE": return WrappingStrategy.MULTI_EDGE
        default: break
        }

        // ElkPadding — format: "[top=T,left=L,bottom=B,right=R]"
        if s.hasPrefix("[") && s.contains("top=") {
            var top = 0.0, right = 0.0, bottom = 0.0, left = 0.0
            let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            for part in trimmed.split(separator: ",") {
                let kv = part.split(separator: "=", maxSplits: 1)
                guard kv.count == 2, let val = Double(kv[1].trimmingCharacters(in: .whitespaces)) else { continue }
                switch kv[0].trimmingCharacters(in: .whitespaces).lowercased() {
                case "top": top = val
                case "right": right = val
                case "bottom": bottom = val
                case "left": left = val
                default: break
                }
            }
            return ElkPadding(top, right, bottom, left)
        }

        return value
    }

    private func applyLayoutOptions(_ options: [String: Any], to holder: IPropertyHolder) {
        let service = LayoutMetaDataService.getInstance()
        for (key, value) in options {
            let fullKey = Self.canonicalKey(key)
            // Try to resolve the option to get proper typing via metadata
            if let optionData = service.getOptionData(fullKey) ?? service.getOptionData(by: fullKey) {
                let stringValue = "\(value)"
                if let parsed = optionData.parseValue(stringValue) {
                    holder.setProperty(optionData, parsed)
                } else {
                    holder.setProperty(optionData, value)
                }
            } else {
                // No metadata — store parsed value with canonical key
                let parsed = Self.parseOptionValue(fullKey, value)
                holder.setProperty(fullKey, parsed)
            }
        }
    }

    // MARK: - Helpers

    private func asDouble(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s) { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        return 0
    }

}
