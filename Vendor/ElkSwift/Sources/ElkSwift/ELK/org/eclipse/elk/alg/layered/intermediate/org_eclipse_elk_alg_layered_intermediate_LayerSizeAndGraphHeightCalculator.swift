// Generated from ELK Java source
// Source of truth: elk-source (Java)
// DO NOT EDIT MANUALLY. Regenerate instead.

// Java source: plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/LayerSizeAndGraphHeightCalculator.java

import Foundation

package final class org_eclipse_elk_alg_layered_intermediate_LayerSizeAndGraphHeightCalculator {
    package init() {}

    package func process(_ layeredGraph: LGraph, _ monitor: IElkProgressMonitor) {
        monitor.begin("Layer size calculation", 1)

        var minY = Double.infinity
        var maxY = -Double.infinity

        var foundNodes = false
        for layer in layeredGraph.getLayers() {
            let layerSize = layer.getSize()
            layerSize.x = 0.0
            layerSize.y = 0.0

            if layer.getNodes().isEmpty {
                continue
            }

            foundNodes = true

            for node in layer.getNodes() {
                let nodeSize = node.getSize()
                let nodeMargin = node.getMargin()
                layerSize.x = max(layerSize.x, nodeSize.x + nodeMargin.left + nodeMargin.right)
            }

            let firstNode = layer.getNodes()[0]
            var top = firstNode.getPosition().y - firstNode.getMargin().top
            if firstNode.type == .externalPort {
                if let surrounding = layeredGraph.getProperty(LayeredOptions.SPACING_PORTS_SURROUNDING) as? ElkMargin {
                    top -= surrounding.getTop()
                }
            }
            let lastNode = layer.getNodes()[layer.getNodes().count - 1]
            var bottom = lastNode.getPosition().y + lastNode.getSize().y + lastNode.getMargin().bottom
            if lastNode.type == .externalPort {
                if let surrounding = layeredGraph.getProperty(LayeredOptions.SPACING_PORTS_SURROUNDING) as? ElkMargin {
                    bottom += surrounding.getBottom()
                }
            }
            layerSize.y = bottom - top

            minY = min(minY, top)
            maxY = max(maxY, bottom)
        }

        if !foundNodes {
            minY = 0
            maxY = 0
        }

        layeredGraph.getSize().y = maxY - minY
        layeredGraph.getOffset().y -= minY

        monitor.done()
    }
}
