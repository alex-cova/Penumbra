import Foundation

/**
 * A layered graph has a set of layers that contain the nodes, as well as a
 * list of nodes that are not yet assigned to a layer.
 */
package final class LGraph: LGraphElement {

    package var size = KVector()
    package var padding = LPadding()
    package var offset = KVector()
    package var layerlessNodes = [LNode]()
    package var layers = [Layer]()
    package var parentNode: LNode?

    package func getSize() -> KVector {
        return size
    }

    package func getActualSize() -> KVector {
        return KVector(
            size.x + padding.left + padding.right,
            size.y + padding.top + padding.bottom
        )
    }

    package func getPadding() -> LPadding {
        return padding
    }

    package func getOffset() -> KVector {
        return offset
    }

    package func getLayerlessNodes() -> [LNode] {
        return layerlessNodes
    }

    package func getLayers() -> [Layer] {
        return layers
    }

    package func getParentNode() -> LNode? {
        return parentNode
    }

    package func setParentNode(_ parentNode: LNode?) {
        self.parentNode = parentNode
    }

    /// Creates a new Layer, appends it to the layers list, and sets its graph reference.
    @discardableResult
    package func addLayer() -> Layer {
        let layer = Layer(self)
        layers.append(layer)
        return layer
    }

    /// Removes the given layer from this graph's layers list.
    package func removeLayer(_ layer: Layer) {
        layers.removeAll { $0 === layer }
    }

    /// Removes the given node from the layerless nodes list.
    package func removeLayerlessNode(_ node: LNode) {
        layerlessNodes.removeAll { $0 === node }
    }

    package func toNodeArray() -> [[LNode]] {
        return layers.map { $0.getNodes() }
    }

    package func toString() -> String {
        if layers.isEmpty {
            return "G-unlayered\(layerlessNodes)"
        } else if layerlessNodes.isEmpty {
            return "G-layered\(layers)"
        }
        return "G[layerless\(layerlessNodes), layers\(layers)]"
    }
}

// Java's LGraph implements Iterable<Layer>, so support for-in over layers.
extension LGraph: Sequence {
    package typealias Element = Layer
    package func makeIterator() -> IndexingIterator<[Layer]> {
        return layers.makeIterator()
    }
}
