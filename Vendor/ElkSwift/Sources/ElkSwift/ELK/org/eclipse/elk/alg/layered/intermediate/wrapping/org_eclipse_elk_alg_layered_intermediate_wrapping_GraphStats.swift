// Ported from elk-source/plugins/org.eclipse.elk.alg.layered/src/org/eclipse/elk/alg/layered/intermediate/wrapping/GraphStats.java

import Foundation

/// Collects (lazily) some information about a layered graph.
/// For instance: longest path and maximum width and height of a layer.
package class org_eclipse_elk_alg_layered_intermediate_wrapping_GraphStats {

    // MARK: - Property keys
    package static let DIRECTION_KEY = "org.eclipse.elk.direction"
    package static let ASPECT_RATIO_KEY = "org.eclipse.elk.aspectRatio"
    package static let WRAPPING_CORRECTION_FACTOR_KEY = "org.eclipse.elk.layered.wrapping.correctionFactor"
    package static let SPACING_NODE_NODE_BETWEEN_LAYERS_KEY = "org.eclipse.elk.layered.spacing.nodeNodeBetweenLayers"
    package static let SPACING_NODE_NODE_KEY = "org.eclipse.elk.spacing.nodeNode"
    package static let WRAPPING_VALIDIFY_FORBIDDEN_INDICES_KEY = "org.eclipse.elk.layered.wrapping.validify.forbiddenIndices"

    // MARK: - Public fields (computed during instantiation)
    package let graph: LGraph
    package let dar: Double
    package let longestPath: Int

    // MARK: - Private fields
    package var spacing: Double = 0
    package var inLayerSpacing: Double = 0

    // Computed on demand
    package var maxWidth: Double?
    package var maxHeight: Double?
    package var sumWidth: Double?

    package var _widths: [Double]?
    package var _heights: [Double]?

    package var cutsAllowed: [Bool]?

    // MARK: - Initializer

    package init(_ graph: LGraph) {
        self.graph = graph

        // Since the graph direction may be horizontal (default) or vertical,
        // the desired aspect ratio must be adjusted correspondingly.
        let dir = graph.getProperty(Self.DIRECTION_KEY) as? Direction ?? .UNDEFINED
        let aspectRatio = graph.getProperty(Self.ASPECT_RATIO_KEY) as? Double ?? 1.6
        let correction = graph.getProperty(Self.WRAPPING_CORRECTION_FACTOR_KEY) as? Double ?? 1.0
        if dir == .LEFT || dir == .RIGHT || dir == .UNDEFINED {
            self.dar = aspectRatio * correction
        } else {
            self.dar = 1.0 / (aspectRatio * correction)
        }

        self.spacing = graph.getProperty(Self.SPACING_NODE_NODE_BETWEEN_LAYERS_KEY) as? Double ?? 20.0
        self.inLayerSpacing = graph.getProperty(Self.SPACING_NODE_NODE_KEY) as? Double ?? 20.0

        self.longestPath = graph.getLayers().count
    }

    // MARK: - Approximations

    /// Returns the max width of any node of the layer.
    package func getApproximateLayerWidth(_ l: Layer) -> Double {
        return determineLayerWidth(l)
    }

    /// Returns the approximate width of the current layering (the sum of each layer's width).
    package func getApproximateLayeringWidth() -> Double {
        return getSumWidth()
    }

    /// Returns the approximate width of the new layering that would be created if the cuts were applied.
    package func getApproximateChunkBasedLayeringWidth(_ cuts: [Int]) -> Double {
        if cuts.isEmpty {
            return getApproximateLayeringWidth()
        }
        var width: Double = 0
        var lowIdx = 0
        for highIdx in cuts {
            width = max(width, determineChunkWidth(lowIdx, highIdx))
            lowIdx = highIdx
        }
        width = max(width, determineChunkWidth(lowIdx, graph.getLayers().count))
        return width
    }

    /// Returns the sum of the layer's node heights.
    package func getApproximateLayerHeight(_ l: Layer) -> Double {
        return determineLayerHeight(l)
    }

    /// Returns the approximate height of the current layering (the max height of any layer).
    package func getApproximateLayeringHeight() -> Double {
        return getMaxHeight()
    }

    /// Returns the approximate height of the new layering that would be created if the cuts were applied.
    package func getApproximateChunkBasedLayeringHeight(_ cuts: [Int]) -> Double {
        if cuts.isEmpty {
            return 0
        }
        var height: Double = 0
        var lowIdx = 0
        for highIdx in cuts {
            height += determineChunkHeight(lowIdx, highIdx)
            lowIdx = highIdx
        }
        height += determineChunkHeight(lowIdx, graph.getLayers().count)
        return height
    }

    // MARK: - Widths

    package func getMaxWidth() -> Double {
        if let cached = maxWidth { return cached }
        let computed = determineWidth { a, b in max(a, b) }
        maxWidth = computed
        return computed
    }

    package func getSumWidth() -> Double {
        if let cached = sumWidth { return cached }
        let computed = determineWidth { a, b in a + b }
        sumWidth = computed
        return computed
    }

    package func getWidths() -> [Double] {
        if let cached = _widths { return cached }
        initWidthsAndHeights()
        let computed = _widths ?? []
        return computed
    }

    // MARK: - Heights

    package func getMaxHeight() -> Double {
        if let cached = maxHeight { return cached }
        let computed = determineHeight { a, b in max(a, b) }
        maxHeight = computed
        return computed
    }

    package func getHeights() -> [Double] {
        if let cached = _heights { return cached }
        initWidthsAndHeights()
        let computed = _heights ?? []
        return computed
    }

    // MARK: - Cutting allowed

    /// Returns whether it is allowed to cut before the given layerIndex.
    package func isCutAllowed(_ layerIndex: Int) -> Bool {
        if cutsAllowed == nil {
            initCutAllowed()
        }
        let cached = cutsAllowed ?? []
        return cached[layerIndex]
    }

    package func getCutsAllowed() -> [Bool] {
        if cutsAllowed == nil {
            initCutAllowed()
        }
        let cached = cutsAllowed ?? []
        return cached
    }

    // MARK: - Private helpers

    package func initWidthsAndHeights() {
        let n = longestPath
        var widths = [Double](repeating: 0, count: n)
        var heights = [Double](repeating: 0, count: n)

        let layers = graph.getLayers()
        for i in 0..<n {
            let l = layers[i]
            widths[i] = determineLayerWidth(l)
            heights[i] = determineLayerHeight(l)
        }

        self._widths = widths
        self._heights = heights
    }

    package func determineWidth(_ fun: (Double, Double) -> Double) -> Double {
        let layers = graph.getLayers()
        guard let first = layers.first else { return 0 }
        var result = determineLayerWidth(first)
        for i in 1..<layers.count {
            result = fun(result, determineLayerWidth(layers[i]))
        }
        return result
    }

    /// Returns max of any node width in the layer plus spacing.
    package func determineLayerWidth(_ l: Layer) -> Double {
        var maxW: Double = 0
        for n in l.getNodes() {
            let nW = n.getSize().x + n.getMargin().right + n.getMargin().left + spacing
            maxW = max(maxW, nW)
        }
        return maxW
    }

    /// Returns the sum of layer widths between lowIdx (inclusive) and highIdx (exclusive).
    package func determineChunkWidth(_ lowIdx: Int, _ highIdx: Int) -> Double {
        let layers = graph.getLayers()
        var sum: Double = 0
        for i in lowIdx..<highIdx {
            sum += determineLayerWidth(layers[i])
        }
        return sum
    }

    package func determineHeight(_ fun: (Double, Double) -> Double) -> Double {
        let layers = graph.getLayers()
        guard let first = layers.first else { return 0 }
        var result = determineLayerHeight(first)
        for i in 1..<layers.count {
            result = fun(result, determineLayerHeight(layers[i]))
        }
        return result
    }

    package func determineLayerHeight(_ layer: Layer) -> Double {
        var lH: Double = 0
        for n in layer.getNodes() {
            lH += n.getSize().y + n.getMargin().bottom + n.getMargin().top + inLayerSpacing

            for inc in n.getIncomingEdges() {
                if let srcNode = inc.getSource()?.getNode(),
                   srcNode.getType() == .NORTH_SOUTH_PORT {
                    let originAny: Any? = srcNode.getProperty(
                        InternalProperties.ORIGIN
                    )
                    if let origin = originAny as? LNode {
                        lH += origin.getSize().y + origin.getMargin().bottom + origin.getMargin().top
                    }
                }
            }
        }
        return lH
    }

    /// Returns the maximum layer height between lowIdx (inclusive) and highIdx (exclusive).
    package func determineChunkHeight(_ lowIdx: Int, _ highIdx: Int) -> Double {
        let layers = graph.getLayers()
        var maxH: Double = 0
        for i in lowIdx..<highIdx {
            maxH = max(maxH, determineLayerHeight(layers[i]))
        }
        return maxH
    }

    package func initCutAllowed() {
        guard cutsAllowed == nil else { return }

        let layerCount = graph.getLayers().count
        var allowed = [Bool](repeating: false, count: layerCount)

        if graph.hasProperty(Self.WRAPPING_VALIDIFY_FORBIDDEN_INDICES_KEY) {
            // User-specified forbidden indices
            let forbiddenAny: Any? = graph.getProperty(Self.WRAPPING_VALIDIFY_FORBIDDEN_INDICES_KEY)
            if let forbidden = forbiddenAny as? [Int] {
                // Start with all true except index 0
                for i in 1..<allowed.count {
                    allowed[i] = true
                }
                for f in forbidden {
                    if f > 0 && f < allowed.count {
                        allowed[f] = false
                    }
                }
            }
        } else {
            // 'default' behavior
            let layers = graph.getLayers()
            // Skip the first layer (index 0 stays false)
            for i in 1..<layers.count {
                allowed[i] = isCutAllowedForLayer(layers[i])
            }
        }

        self.cutsAllowed = allowed
    }

    /// Returns whether it is allowed to cut before the given layer.
    package func isCutAllowedForLayer(_ layer: Layer) -> Bool {
        // We only allow to cut between a pair of layers
        // if there is only one pair of nodes that is connected by 1 or more edges
        var cutAllowed = true
        var n1: LNode? = nil
        var n2: LNode? = nil

        outer:
        for tgt in layer.getNodes() {
            for e in tgt.getIncomingEdges() {
                // Check for different target
                if n1 != nil && n1 !== tgt {
                    cutAllowed = false
                    break outer
                }
                n1 = tgt
                // Check for different source
                if let src = e.getSource()?.getNode() {
                    if n2 != nil && n2 !== src {
                        cutAllowed = false
                        break outer
                    }
                    n2 = src
                }
            }
        }
        return cutAllowed
    }
}
