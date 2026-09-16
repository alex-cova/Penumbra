// Concrete implementations of the ELK graph model protocols.
// These replace the excluded graph/impl classes with simple,
// array-backed implementations suitable for JSON import/export.

import Foundation

// MARK: - Base Property Holder

package class ElkPropertyHolder: EObject, IPropertyHolder {
    package var propertyMap: [String: Any]?

    package init() {}

    @discardableResult
    package func setProperty(_ property: IProperty, _ value: Any?) -> Self {
        if let value = value {
            var map = propertyMap ?? [:]
            map[property.id] = value
            propertyMap = map
        } else {
            propertyMap?.removeValue(forKey: property.id)
        }
        return self
    }

    package func getProperty(_ property: IProperty) -> Any? {
        if let value = propertyMap?[property.id] {
            return value
        }
        return property.defaultValue
    }

    package func hasProperty(_ property: IProperty) -> Bool {
        return propertyMap?[property.id] != nil
    }

    @discardableResult
    package func copyProperties(_ holder: IPropertyHolder) -> Self {
        let other = holder.getAllProperties()
        if !other.isEmpty {
            var map = propertyMap ?? [:]
            map.merge(other) { _, new in new }
            propertyMap = map
        }
        return self
    }

    package func getAllProperties() -> [String: Any] {
        return propertyMap ?? [:]
    }

    // String-key overloads
    @discardableResult
    package func setProperty(_ key: String, _ value: Any?) -> Self {
        if let value = value {
            var map = propertyMap ?? [:]
            map[key] = value
            propertyMap = map
        } else {
            propertyMap?.removeValue(forKey: key)
        }
        return self
    }

    package func getProperty(_ key: String) -> Any? {
        return propertyMap?[key]
    }

    package func hasProperty(_ key: String) -> Bool {
        return propertyMap?[key] != nil
    }
}

// MARK: - Graph Element

package class ElkGraphElementBase: ElkPropertyHolder, EMapPropertyHolder, ElkGraphElement {
    package var properties: [String: Any] { return propertyMap ?? [:] }
    package var labels: [ElkLabel] = []
    package var identifier: String?
}

// MARK: - Shape

package class ElkShapeBase: ElkGraphElementBase, ElkShape {
    package var x: Double = 0
    package var y: Double = 0
    package var width: Double = 0
    package var height: Double = 0

    package func setDimensions(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    package func setLocation(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

// MARK: - Connectable Shape

package class ElkConnectableShapeBase: ElkShapeBase, ElkConnectableShape {
    package var outgoingEdges: [ElkEdge] = []
    package var incomingEdges: [ElkEdge] = []
}

// MARK: - Node

package final class ElkNodeImpl2: ElkConnectableShapeBase, ElkNode {
    package var ports: [ElkPort] = []
    package var children: [ElkNode] = []
    package weak var _parent: AnyObject?
    package var parent: ElkNode? {
        get { return _parent as? ElkNode }
        set { _parent = newValue as AnyObject? }
    }
    package var containedEdges: [ElkEdge] = []

    package func isHierarchical() -> Bool {
        return !children.isEmpty
    }
}

// MARK: - Port

package final class ElkPortImpl2: ElkConnectableShapeBase, ElkPort {
    package weak var _parent: AnyObject?
    package var parent: ElkNode? {
        get { return _parent as? ElkNode }
        set { _parent = newValue as AnyObject? }
    }
}

// MARK: - Label

package final class ElkLabelImpl2: ElkShapeBase, ElkLabel {
    package weak var _parent: AnyObject?
    package var parent: ElkGraphElement? {
        get { return _parent as? ElkGraphElement }
        set { _parent = newValue as AnyObject? }
    }
    package var text: String = ""
}

// MARK: - Edge

package final class ElkEdgeImpl2: ElkGraphElementBase, ElkEdge {
    package weak var _containingNode: AnyObject?
    package var containingNode: ElkNode? {
        get { return _containingNode as? ElkNode }
        set { _containingNode = newValue as AnyObject? }
    }
    package var sources: [ElkConnectableShape] = []
    package var targets: [ElkConnectableShape] = []
    package var sections: [ElkEdgeSection] = []

    package func isHyperedge() -> Bool {
        return sources.count > 1 || targets.count > 1
    }

    package func isHierarchical() -> Bool {
        guard let containingNode = containingNode else { return false }
        for source in sources {
            let sourceNode = (source as? ElkNode) ?? (source as? ElkPort)?.parent
            if sourceNode === containingNode { return true }
            if sourceNode?.parent !== containingNode { return true }
        }
        for target in targets {
            let targetNode = (target as? ElkNode) ?? (target as? ElkPort)?.parent
            if targetNode === containingNode { return true }
            if targetNode?.parent !== containingNode { return true }
        }
        return false
    }

    package func isSelfloop() -> Bool {
        if sources.isEmpty || targets.isEmpty { return false }
        let sourceNodes = Set(sources.map { ObjectIdentifier(($0 as? ElkNode) ?? (($0 as? ElkPort)?.parent ?? $0) as AnyObject) })
        let targetNodes = Set(targets.map { ObjectIdentifier(($0 as? ElkNode) ?? (($0 as? ElkPort)?.parent ?? $0) as AnyObject) })
        return sourceNodes == targetNodes
    }

    package func isConnected() -> Bool {
        return !sources.isEmpty && !targets.isEmpty
    }
}

// MARK: - Edge Section

package final class ElkEdgeSectionImpl2: ElkPropertyHolder, EMapPropertyHolder, ElkEdgeSection {
    package var properties: [String: Any] { return propertyMap ?? [:] }
    package var startX: Double = 0
    package var startY: Double = 0
    package var endX: Double = 0
    package var endY: Double = 0
    package var bendPoints: [ElkBendPoint] = []
    package weak var _parent: AnyObject?
    package var parent: ElkEdge? {
        get { return _parent as? ElkEdge }
        set { _parent = newValue as AnyObject? }
    }
    package var outgoingShape: ElkConnectableShape?
    package var incomingShape: ElkConnectableShape?
    package var outgoingSections: [ElkEdgeSection] = []
    package var incomingSections: [ElkEdgeSection] = []
    package var identifier: String?

    package func setStartLocation(x: Double, y: Double) {
        self.startX = x
        self.startY = y
    }

    package func setEndLocation(x: Double, y: Double) {
        self.endX = x
        self.endY = y
    }
}

// MARK: - Bend Point

package final class ElkBendPointImpl2: EObject {
    package var x: Double = 0
    package var y: Double = 0

    package init() {}
    package init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

extension ElkBendPointImpl2: ElkBendPoint {
    package func set(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
