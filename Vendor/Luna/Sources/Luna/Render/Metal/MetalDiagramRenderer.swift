import Foundation
import CoreGraphics
import Metal

/// Metal vector renderer for Luna's flowchart/state graphs: walks the same
/// `PositionedGraph` the CoreGraphics `_drawFlowOrState` path consumes and
/// emits identical geometry (same insets, radii, arrowhead dimensions, label
/// placement math) as GPU triangles plus cached label quads.
///
/// Produces a resolved BGRA texture (and, on demand, a `CGImage` readback in
/// the preview tile pixel format). Any failure throws `MetalDiagramError`;
/// callers fall back to CoreGraphics.
///
/// Thread-safe: pipeline creation is locked, the label cache and backend
/// carry their own locks, and per-render state is stack-local, so one shared
/// instance can serve concurrent off-main renders.
public final class MetalDiagramRenderer: @unchecked Sendable {
    private let backend: MetalDiagramBackend
    private let labelCache: MetalLabelCache?
    private let pipelineLock = NSLock()
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?

    public init(backend: MetalDiagramBackend = .shared) {
        self.backend = backend
        self.labelCache = backend.device.flatMap { MetalLabelCache(device: $0) }
    }

    public var isAvailable: Bool {
        backend.isAvailable && labelCache != nil
    }

    /// Renders `positioned` (point space, y-down) at `scale` into a resolved
    /// texture. Throws on any Metal failure (caller falls back to CG).
    public func renderFlowchart(
        _ positioned: PositionedGraph,
        theme: DiagramTheme,
        config: RenderConfig = RenderConfig(),
        scale: CGFloat
    ) throws -> MTLTexture {
        try backend.withLibrary { device, queue, library in
            guard let labelCache else {
                throw MetalDiagramError.unavailable("label cache unavailable")
            }
            let width = max(1, Int(positioned.width * scale))
            let height = max(1, Int(positioned.height * scale))
            guard MetalDiagramBackend.canAllocate(width: width, height: height) else {
                throw MetalDiagramError.allocationFailed("diagram \(width)x\(height) exceeds texture budget")
            }
            var encoder = FlowchartEncoder(
                theme: theme, config: config, scale: scale, labels: labelCache)
            try encoder.encode(positioned)
            return try self.submit(
                device: device, queue: queue, library: library,
                solid: encoder.solid.floats,
                textured: encoder.texturedLayers,
                width: width, height: height,
                background: theme.transparent ? nil : theme.background)
        }
    }

    /// sRGB components of a theme color (BMColor is NSColor/UIColor here).
    static func rgba(_ c: BMColor) -> SIMD4<Float> {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
    }

    /// Dispatching render: flowchart content uses the flowchart encoder,
    /// anything with an extra scene uses the extras encoder. Throws for
    /// unknown content (caller falls back to CoreGraphics).
    public func renderCGImage(
        _ positioned: PositionedGraph,
        theme: DiagramTheme,
        config: RenderConfig = RenderConfig(),
        scale: CGFloat
    ) throws -> CGImage {
        switch positioned.content {
        case .flowchart:
            return try renderFlowchartCGImage(positioned, theme: theme, config: config, scale: scale)
        case .sequenceDiagram:
            return try renderSequenceCGImage(positioned, theme: theme, config: config, scale: scale)
        case .classDiagram:
            return try renderClassCGImage(positioned, theme: theme, config: config, scale: scale)
        case .erDiagram:
            return try renderERCGImage(positioned, theme: theme, config: config, scale: scale)
        case .xyChart:
            return try renderXYCGImage(positioned, theme: theme, config: config, scale: scale)
        default:
            guard let scene = positioned.extraScene else {
                throw MetalDiagramError.encodeFailed("Metal renderer needs flowchart or extra content")
            }
            return try renderExtraCGImage(scene, theme: theme, config: config, scale: scale)
        }
    }

    /// Renders an `ExtraScene` display list at `scale` into a resolved texture.
    public func renderExtra(
        _ scene: ExtraScene,
        theme: DiagramTheme,
        config: RenderConfig = RenderConfig(),
        scale: CGFloat
    ) throws -> MTLTexture {
        try backend.withLibrary { device, queue, library in
            guard let labelCache else {
                throw MetalDiagramError.unavailable("label cache unavailable")
            }
            let width = max(1, Int(scene.width * scale))
            let height = max(1, Int(scene.height * scale))
            guard MetalDiagramBackend.canAllocate(width: width, height: height) else {
                throw MetalDiagramError.allocationFailed("diagram \(width)x\(height) exceeds texture budget")
            }
            var encoder = MetalExtraEncoder(ctx: MetalEncodeContext(
                theme: theme, config: config, scale: scale, labels: labelCache))
            try encoder.encode(scene: scene)
            return try self.submit(
                device: device, queue: queue, library: library,
                solid: encoder.ctx.solid.floats,
                textured: encoder.ctx.texturedLayers,
                width: width, height: height,
                background: theme.transparent ? nil : theme.background)
        }
    }

    /// Renders positioned sequence content at `scale` into a resolved texture.
    public func renderSequence(
        _ positioned: PositionedGraph,
        theme: DiagramTheme,
        config: RenderConfig = RenderConfig(),
        scale: CGFloat
    ) throws -> MTLTexture {
        try backend.withLibrary { device, queue, library in
            guard let labelCache else {
                throw MetalDiagramError.unavailable("label cache unavailable")
            }
            let width = max(1, Int(positioned.width * scale))
            let height = max(1, Int(positioned.height * scale))
            guard MetalDiagramBackend.canAllocate(width: width, height: height) else {
                throw MetalDiagramError.allocationFailed("diagram \(width)x\(height) exceeds texture budget")
            }
            var encoder = MetalSequenceEncoder(ctx: MetalEncodeContext(
                theme: theme, config: config, scale: scale, labels: labelCache))
            try encoder.encode(positioned: positioned)
            return try self.submit(
                device: device, queue: queue, library: library,
                solid: encoder.ctx.solid.floats,
                textured: encoder.ctx.texturedLayers,
                width: width, height: height,
                background: theme.transparent ? nil : theme.background)
        }
    }

    /// Convenience for snapshot tests and CG-compatible consumers.
    public func renderSequenceCGImage(
        _ positioned: PositionedGraph,
        theme: DiagramTheme,
        config: RenderConfig = RenderConfig(),
        scale: CGFloat
    ) throws -> CGImage {
        let texture = try renderSequence(positioned, theme: theme, config: config, scale: scale)
        return try MetalDiagramRenderer.readback(texture: texture)
    }

    /// Shared submit path for positioned (non-display-list) content.
    private func renderPositioned(
        _ positioned: PositionedGraph,
        theme: DiagramTheme,
        config: RenderConfig,
        scale: CGFloat,
        encode: (inout MetalEncodeContext) throws -> Void
    ) throws -> MTLTexture {
        try backend.withLibrary { device, queue, library in
            guard let labelCache else {
                throw MetalDiagramError.unavailable("label cache unavailable")
            }
            let width = max(1, Int(positioned.width * scale))
            let height = max(1, Int(positioned.height * scale))
            guard MetalDiagramBackend.canAllocate(width: width, height: height) else {
                throw MetalDiagramError.allocationFailed("diagram \(width)x\(height) exceeds texture budget")
            }
            var encoderCtx = MetalEncodeContext(
                theme: theme, config: config, scale: scale, labels: labelCache)
            try encode(&encoderCtx)
            return try self.submit(
                device: device, queue: queue, library: library,
                solid: encoderCtx.solid.floats,
                textured: encoderCtx.texturedLayers,
                width: width, height: height,
                background: theme.transparent ? nil : theme.background)
        }
    }

    /// Renders positioned class content at `scale` into a resolved texture.
    public func renderClass(
        _ positioned: PositionedGraph,
        theme: DiagramTheme,
        config: RenderConfig = RenderConfig(),
        scale: CGFloat
    ) throws -> MTLTexture {
        try renderPositioned(positioned, theme: theme, config: config, scale: scale) {
            var encoder = MetalClassEncoder(ctx: $0)
            try encoder.encode(positioned: positioned)
            $0 = encoder.ctx
        }
    }

    /// Convenience for snapshot tests and CG-compatible consumers.
    public func renderClassCGImage(
        _ positioned: PositionedGraph,
        theme: DiagramTheme,
        config: RenderConfig = RenderConfig(),
        scale: CGFloat
    ) throws -> CGImage {
        let texture = try renderClass(positioned, theme: theme, config: config, scale: scale)
        return try MetalDiagramRenderer.readback(texture: texture)
    }

    /// Renders positioned ER content at `scale` into a resolved texture.
    public func renderER(
        _ positioned: PositionedGraph,
        theme: DiagramTheme,
        config: RenderConfig = RenderConfig(),
        scale: CGFloat
    ) throws -> MTLTexture {
        try renderPositioned(positioned, theme: theme, config: config, scale: scale) {
            var encoder = MetalEREncoder(ctx: $0)
            try encoder.encode(positioned: positioned)
            $0 = encoder.ctx
        }
    }

    /// Convenience for snapshot tests and CG-compatible consumers.
    public func renderERCGImage(
        _ positioned: PositionedGraph,
        theme: DiagramTheme,
        config: RenderConfig = RenderConfig(),
        scale: CGFloat
    ) throws -> CGImage {
        let texture = try renderER(positioned, theme: theme, config: config, scale: scale)
        return try MetalDiagramRenderer.readback(texture: texture)
    }

    /// Renders positioned XY content at `scale` into a resolved texture.
    public func renderXY(
        _ positioned: PositionedGraph,
        theme: DiagramTheme,
        config: RenderConfig = RenderConfig(),
        scale: CGFloat
    ) throws -> MTLTexture {
        try renderPositioned(positioned, theme: theme, config: config, scale: scale) {
            var encoder = MetalXYEncoder(ctx: $0)
            try encoder.encode(positioned: positioned)
            $0 = encoder.ctx
        }
    }

    /// Convenience for snapshot tests and CG-compatible consumers.
    public func renderXYCGImage(
        _ positioned: PositionedGraph,
        theme: DiagramTheme,
        config: RenderConfig = RenderConfig(),
        scale: CGFloat
    ) throws -> CGImage {
        let texture = try renderXY(positioned, theme: theme, config: config, scale: scale)
        return try MetalDiagramRenderer.readback(texture: texture)
    }

    /// Convenience for snapshot tests and CG-compatible consumers.
    public func renderExtraCGImage(
        _ scene: ExtraScene,
        theme: DiagramTheme,
        config: RenderConfig = RenderConfig(),
        scale: CGFloat
    ) throws -> CGImage {
        let texture = try renderExtra(scene, theme: theme, config: config, scale: scale)
        return try MetalDiagramRenderer.readback(texture: texture)
    }

    /// Convenience for snapshot tests and CG-compatible consumers.
    public func renderFlowchartCGImage(
        _ positioned: PositionedGraph,
        theme: DiagramTheme,
        config: RenderConfig = RenderConfig(),
        scale: CGFloat
    ) throws -> CGImage {
        let texture = try renderFlowchart(positioned, theme: theme, config: config, scale: scale)
        return try MetalDiagramRenderer.readback(texture: texture)
    }

    private func pipelineState(device: MTLDevice, library: MTLLibrary, sampleCount: Int) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "diagram_vs")
        descriptor.fragmentFunction = library.makeFunction(name: "diagram_fs")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func submit(
        device: MTLDevice,
        queue: MTLCommandQueue,
        library: MTLLibrary,
        solid: [Float],
        textured: [(texture: MTLTexture, floats: [Float])],
        width: Int,
        height: Int,
        background: BMColor?
    ) throws -> MTLTexture {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        if pipeline == nil {
            pipeline = try pipelineState(device: device, library: library, sampleCount: 4)
            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            samplerDescriptor.sAddressMode = .clampToEdge
            samplerDescriptor.tAddressMode = .clampToEdge
            sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        }
        guard let pipeline, let sampler else {
            throw MetalDiagramError.encodeFailed("pipeline unavailable")
        }
        // Resolve target (shared so the CPU can read pixels back).
        let resolveDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        resolveDescriptor.usage = [.renderTarget, .shaderRead]
        resolveDescriptor.storageMode = .shared
        guard let resolve = device.makeTexture(descriptor: resolveDescriptor) else {
            throw MetalDiagramError.allocationFailed("resolve texture \(width)x\(height)")
        }
        // MSAA target when the device provides one; otherwise render direct.
        var msaa: MTLTexture?
        var activePipeline = pipeline
        let msaaDescriptor = MTLTextureDescriptor()
        msaaDescriptor.textureType = .type2DMultisample
        msaaDescriptor.pixelFormat = .bgra8Unorm
        msaaDescriptor.width = width
        msaaDescriptor.height = height
        msaaDescriptor.sampleCount = 4
        msaaDescriptor.storageMode = .private
        msaaDescriptor.usage = [.renderTarget]
        if let target = device.makeTexture(descriptor: msaaDescriptor) {
            msaa = target
        } else {
            activePipeline = try pipelineState(device: device, library: library, sampleCount: 1)
        }
        // Single vertex buffer: solid first, then one range per label texture.
        var floats = solid
        struct Range { var texture: MTLTexture?; var start: Int; var count: Int }
        var ranges: [Range] = []
        if !solid.isEmpty {
            ranges.append(Range(texture: nil, start: 0, count: solid.count / MetalTessellator.floatsPerVertex))
        }
        for layer in textured where !layer.floats.isEmpty {
            ranges.append(Range(texture: layer.texture, start: floats.count / MetalTessellator.floatsPerVertex, count: layer.floats.count / MetalTessellator.floatsPerVertex))
            floats.append(contentsOf: layer.floats)
        }
        guard !floats.isEmpty else {
            // Nothing to draw: clear the resolve target and return it.
            guard let commandBuffer = queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeBlitCommandEncoder() else {
                throw MetalDiagramError.encodeFailed("command setup failed")
            }
            encoder.fill(buffer: device.makeBuffer(length: 4, options: [])!,
                range: 0..<4, value: 0)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return resolve
        }
        guard let buffer = device.makeBuffer(bytes: floats,
            length: floats.count * MemoryLayout<Float>.size, options: []) else {
            throw MetalDiagramError.allocationFailed("vertex buffer")
        }
        // 1x1 white dummy for the untextured pass (fragment always samples).
        let dummyDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        dummyDescriptor.usage = [.shaderRead]
        dummyDescriptor.storageMode = .shared
        guard let dummy = device.makeTexture(descriptor: dummyDescriptor) else {
            throw MetalDiagramError.allocationFailed("dummy texture")
        }
        var white: UInt32 = 0xFFFFFFFF
        dummy.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
            withBytes: &white, bytesPerRow: 4)
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw MetalDiagramError.encodeFailed("command buffer unavailable")
        }
        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]
        if let msaa {
            attachment?.texture = msaa
            attachment?.resolveTexture = resolve
            attachment?.storeAction = .multisampleResolve
        } else {
            attachment?.texture = resolve
            attachment?.storeAction = .store
        }
        attachment?.loadAction = .clear
        if let background {
            let bg = MetalDiagramRenderer.rgba(background)
            attachment?.clearColor = MTLClearColorMake(
                Double(bg.x), Double(bg.y), Double(bg.z), Double(bg.w)
            )
        } else {
            attachment?.clearColor = MTLClearColorMake(0, 0, 0, 0)
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw MetalDiagramError.encodeFailed("render encoder unavailable")
        }
        encoder.setRenderPipelineState(activePipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var viewport = SIMD2<Float>(Float(width), Float(height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for range in ranges {
            encoder.setFragmentTexture(range.texture ?? dummy, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: range.start, vertexCount: range.count)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw MetalDiagramError.encodeFailed("command buffer failed: \(error.localizedDescription)")
        }
        return resolve
    }

    // MARK: - Flowchart/state encoder (mirrors _drawFlowOrState)

    /// Encoder state threading tessellation, label cache and style context.
    /// Solid geometry goes to `solid`; each label texture gets its own stream
    /// (the atlas plus rare dedicated oversize textures), drawn back-to-front.
    struct FlowchartEncoder {
        var theme: DiagramTheme
        var config: RenderConfig
        var scale: CGFloat
        var solid = MetalTessellator()
        var streams: [ObjectIdentifier: MetalTessellator] = [:]
        var streamTextures: [ObjectIdentifier: MTLTexture] = [:]
        var labels: MetalLabelCache
        /// Device pixel rects of every emitted label quad, for tests.
        var debugLabelRects: [CGRect] = []

        var texturedLayers: [(texture: MTLTexture, floats: [Float])] {
            streamTextures.compactMap { id, texture in
                guard let stream = streams[id] else { return nil }
                return (texture, stream.floats)
            }
        }

        mutating func withTex(_ texture: MTLTexture, _ body: (inout MetalTessellator) -> Void) {
            let id = ObjectIdentifier(texture)
            if streamTextures[id] == nil { streamTextures[id] = texture }
            var stream = streams[id] ?? MetalTessellator()
            body(&stream)
            streams[id] = stream
        }

        func color(_ c: BMColor) -> SIMD4<Float> {
            MetalDiagramRenderer.rgba(c)
        }

        func R(_ r: CGRect) -> CGRect {
            CGRect(x: r.origin.x * scale, y: r.origin.y * scale,
                width: r.width * scale, height: r.height * scale)
        }

        func P(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * scale, y: p.y * scale)
        }

        // MARK: Text (placement math mirrors LabelRenderer exactly)

        mutating func emitLine(
            placement: MetalLabelCache.Placement,
            line: MetalLabelCache.Block.Line,
            at origin: CGPoint,
            color: BMColor
        ) {
            let s = placement.pixelSize
            let lw = line.size.width * scale
            let lh = line.size.height * scale
            guard lw >= 0.5, lh >= 0.5 else { return }
            let lx = origin.x, ly = origin.y
            // Bitmap row 0 is the block's visual top (verified by atlas
            // readback), matching texture row order: sample V straight down.
            let u0 = placement.uv.minX + (line.origin.x * scale) / s.width * placement.uv.width
            let u1 = u0 + lw / s.width * placement.uv.width
            let vTop = placement.uv.minY + (line.origin.y * scale) / s.height * placement.uv.height
            let vH = lh / s.height * placement.uv.height
            let vv0 = Float(vTop)
            let vv1 = Float(vTop + vH)
            let c = self.color(color)
            let fu0 = Float(u0), fu1 = Float(u1)
            withTex(placement.texture) { tess in
                tess.vertex(x: lx, y: ly, color: c, uvX: fu0, uvY: vv0, mode: 1)
                tess.vertex(x: lx + lw, y: ly, color: c, uvX: fu1, uvY: vv0, mode: 1)
                tess.vertex(x: lx + lw, y: ly + lh, color: c, uvX: fu1, uvY: vv1, mode: 1)
                tess.vertex(x: lx, y: ly, color: c, uvX: fu0, uvY: vv0, mode: 1)
                tess.vertex(x: lx + lw, y: ly + lh, color: c, uvX: fu1, uvY: vv1, mode: 1)
                tess.vertex(x: lx, y: ly + lh, color: c, uvX: fu0, uvY: vv1, mode: 1)
            }
            debugLabelRects.append(CGRect(x: lx, y: ly, width: lw, height: lh))
        }

        mutating func emitBlock(
            _ placement: MetalLabelCache.Placement,
            blockTopLeft: CGPoint,
            color: BMColor
        ) {
            for line in placement.block.lines {
                emitLine(placement: placement, line: line,
                    at: CGPoint(x: blockTopLeft.x + line.origin.x * scale,
                        y: blockTopLeft.y + line.origin.y * scale),
                    color: color)
            }
        }

        /// Mirrors `drawText(at:alignment:)`.
        mutating func emitTextAt(
            _ text: String, point: CGPoint, color: BMColor, font: BMFont, alignment: TextAlignment
        ) throws {
            guard !text.isEmpty else { return }
            let placement = try labels.placement(text: text, font: font, scale: scale)
            if text.contains("\n") {
                let lineHeight = font.pointSize * 1.3
                let top = point.y * scale - CGFloat(placement.block.lines.count) * lineHeight * scale / 2
                var ly = top
                for line in placement.block.lines {
                    let cx = point.x * scale - line.size.width * scale / 2
                    emitLine(placement: placement, line: line, at: CGPoint(x: cx, y: ly), color: color)
                    ly += lineHeight * scale
                }
            } else {
                // Center on the measured line size (like CG), not the ceiled
                // block box: identical glyph placement down to the pixel.
                guard let first = placement.block.lines.first else { return }
                let w = first.size.width * scale, h = first.size.height * scale
                let ox: CGFloat
                switch alignment {
                case .left: ox = point.x * scale
                case .center: ox = point.x * scale - w / 2
                case .right: ox = point.x * scale - w
                }
                emitBlock(placement, blockTopLeft: CGPoint(x: ox, y: point.y * scale - h / 2), color: color)
            }
        }

        /// Mirrors `drawText(in:alignment:)`.
        mutating func emitTextIn(
            _ text: String, rect: CGRect, color: BMColor, font: BMFont, alignment: TextAlignment
        ) throws {
            guard !text.isEmpty else { return }
            let r = R(rect)
            let placement = try labels.placement(text: text, font: font, scale: scale)
            if text.contains("\n") {
                let lineHeight = font.pointSize * 1.3
                let blockH = CGFloat(placement.block.lines.count) * lineHeight * scale
                var ly = r.midY - blockH / 2
                for line in placement.block.lines {
                    let cx = r.midX - line.size.width * scale / 2
                    emitLine(placement: placement, line: line, at: CGPoint(x: cx, y: ly), color: color)
                    ly += lineHeight * scale
                }
            } else {
                // Center on the measured line size (like CG), not the ceiled block box.
                guard let first = placement.block.lines.first else { return }
                let w = first.size.width * scale, h = first.size.height * scale
                let ox: CGFloat
                switch alignment {
                case .left: ox = r.minX
                case .center: ox = r.minX + (r.width - w) / 2
                case .right: ox = r.minX + r.width - w
                }
                let oy = r.minY + (r.height - h) / 2
                emitBlock(placement, blockTopLeft: CGPoint(x: ox, y: oy), color: color)
            }
        }

        // MARK: Graph walk

        mutating func encode(_ positioned: PositionedGraph) throws {
            guard case .flowchart(let nodes, let edges, let groups) = positioned.content else {
                throw MetalDiagramError.encodeFailed("Metal flowchart renderer needs flowchart content")
            }
            try drawSubgraphBackgrounds(groups)
            try drawEdges(edges)
            try drawNodes(nodes)
            try drawNodeLabels(nodes)
            try drawEdgeLabels(edges)
            try drawGroupLabels(groups)
        }

        // MARK: Subgraphs (mirrors _drawSubgraphBackgrounds)

        mutating func drawSubgraphBackgrounds(_ groups: [_PositionedGroupPayload]) throws {
            for group in groups {
                let rect = R(CGRect(x: group.x, y: group.y, width: group.width, height: group.height))
                solid.fillRect(rect, color: color(theme.subgraphBackgroundColor()))
                if group.headerHeight > 0 {
                    let header = CGRect(x: rect.minX, y: rect.minY, width: rect.width,
                        height: group.headerHeight * scale)
                    solid.fillRect(header, color: color(theme.subgraphHeaderColor()))
                    let lineY = rect.minY + group.headerHeight * scale
                    solid.strokePolyline(
                        [CGPoint(x: rect.minX, y: lineY), CGPoint(x: rect.maxX, y: lineY)],
                        width: 1.0 * scale, closed: false,
                        color: color(theme.subgraphHeaderColor()))
                }
                solid.strokePolyline([
                    CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                    CGPoint(x: rect.minX, y: rect.minY),
                ], width: 1.0 * scale, closed: false, color: color(theme.effectiveBorder()))
                try drawSubgraphBackgrounds(group.children)
            }
        }

        // MARK: Edges (mirrors drawEdgePath/drawArrowHeads)

        mutating func drawEdges(_ edges: [_PositionedEdgePayload]) {
            for edge in edges where edge.style.lowercased() != "invisible" {
                let style = EdgeStyleParser.parse(from: edge.style,
                    hasArrowStart: edge.hasArrowStart, hasArrowEnd: edge.hasArrowEnd,
                    startMarker: edge.startMarker, endMarker: edge.endMarker)
                let lineWidth = style.strokeWidth ?? (config.strokeWidthConnector * style.lineStyle.widthMultiplier)
                let pts = edge.points.map { P(CGPoint(x: $0.x, y: $0.y)) }
                guard pts.count >= 2 else { continue }
                let runs: [[CGPoint]]
                if let pattern = style.lineStyle.dashPattern {
                    runs = MetalTessellator.dashRuns(pts, pattern: pattern.map { $0 * scale })
                } else {
                    runs = [pts]
                }
                let c = color(theme.edgeColor(for: style))
                for run in runs {
                    solid.strokePolyline(run, width: lineWidth * scale, closed: false, color: c)
                }
                let arrowColor: BMColor = style.color != nil ? theme.edgeColor(for: style) : theme.effectiveArrow()
                let ac = color(arrowColor)
                if style.targetArrow != .none, pts.count >= 2 {
                    let p1 = pts[pts.count - 1], p0 = pts[pts.count - 2]
                    let angle = atan2(p1.y - p0.y, p1.x - p0.x)
                    drawHead(style.targetArrow, at: p1, angle: angle, lineWidth: lineWidth * scale, color: ac)
                }
                if style.sourceArrow != .none, pts.count >= 2 {
                    let p0 = pts[0], p1 = pts[1]
                    let angle = atan2(p0.y - p1.y, p0.x - p1.x)
                    drawHead(style.sourceArrow, at: p0, angle: angle, lineWidth: lineWidth * scale, color: ac)
                }
            }
        }

        mutating func drawHead(_ head: ArrowHead, at tip: CGPoint, angle: CGFloat, lineWidth: CGFloat, color: SIMD4<Float>) {
            switch head {
            case .none: break
            case .arrow: solid.arrowTriangle(tip: tip, angle: angle, color: color)
            case .open: solid.arrowOpen(tip: tip, angle: angle, color: color, lineWidth: lineWidth)
            case .circle: solid.circleMarker(tip: tip, angle: angle, color: color, lineWidth: lineWidth)
            case .cross: solid.crossMarker(tip: tip, angle: angle, color: color, lineWidth: lineWidth)
            case .diamond: solid.diamondMarker(tip: tip, angle: angle, color: color)
            }
        }

        // MARK: Nodes (mirrors drawShape + drawShapeDetails)

        mutating func drawNodes(_ nodes: [_PositionedNodePayload]) {
            for node in nodes {
                let rect = R(CGRect(x: node.x, y: node.y, width: node.width, height: node.height))
                let styles = node.inlineStyle
                let fill = color(theme.nodeFillColor(for: styles))
                let stroke = color(theme.nodeStrokeColor(for: styles))
                let sw = config.strokeWidthInnerBox * scale
                switch node.shape {
                case "rectangle", "entity", "invisible":
                    solid.fillRect(rect, color: fill)
                    solid.strokePolyline(closedRing(rect), width: sw, closed: true, color: stroke)
                case "rounded", "state-note":
                    solid.fillRoundedRect(rect, radius: 6 * scale, color: fill)
                    solid.strokePolyline(closedRingOfRounded(rect, radius: 6 * scale), width: sw, closed: true, color: stroke)
                case "stadium":
                    solid.fillRoundedRect(rect, radius: rect.height / 2, color: fill)
                    solid.strokePolyline(closedRingOfRounded(rect, radius: rect.height / 2), width: sw, closed: true, color: stroke)
                case "circle", "doublecircle", "state-choice":
                    solid.fillEllipse(rect, color: fill)
                    solid.strokeEllipse(rect, width: sw, color: stroke)
                    if node.shape == "doublecircle" {
                        let gap = config.doubleCircleGap * scale
                        solid.strokeEllipse(rect.insetBy(dx: gap, dy: gap), width: sw, color: stroke)
                    }
                case "state-start":
                    solid.fillEllipse(rect, color: color(theme.foreground))
                case "state-end":
                    let r = min(rect.width, rect.height) / 2 - 2 * scale
                    let c = CGPoint(x: rect.midX, y: rect.midY)
                    solid.strokeEllipse(CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2),
                        width: config.strokeWidthInnerBox * 2 * scale, color: color(theme.foreground))
                    let inner = max(1, r - 4 * scale)
                    solid.fillEllipse(CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2),
                        color: color(theme.foreground))
                case "diamond", "rhombus":
                    let c = CGPoint(x: rect.midX, y: rect.midY)
                    let ring = [
                        CGPoint(x: c.x, y: rect.minY), CGPoint(x: rect.maxX, y: c.y),
                        CGPoint(x: c.x, y: rect.maxY), CGPoint(x: rect.minX, y: c.y),
                    ]
                    solid.fillConvexRing(ring, color: fill)
                    solid.strokePolyline(ring, width: sw, closed: true, color: stroke)
                case "hexagon":
                    let inset = rect.height / 4
                    let ring = [
                        CGPoint(x: rect.minX + inset, y: rect.minY), CGPoint(x: rect.maxX - inset, y: rect.minY),
                        CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX - inset, y: rect.maxY),
                        CGPoint(x: rect.minX + inset, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY),
                    ]
                    solid.fillConvexRing(ring, color: fill)
                    solid.strokePolyline(ring, width: sw, closed: true, color: stroke)
                case "parallelogram":
                    let skew = rect.width * 0.2
                    let ring = [
                        CGPoint(x: rect.minX + skew, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                        CGPoint(x: rect.maxX - skew, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                    ]
                    solid.fillConvexRing(ring, color: fill)
                    solid.strokePolyline(ring, width: sw, closed: true, color: stroke)
                case "parallelogram-alt":
                    let skew = rect.width * 0.2
                    let ring = [
                        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX - skew, y: rect.minY),
                        CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX + skew, y: rect.maxY),
                    ]
                    solid.fillConvexRing(ring, color: fill)
                    solid.strokePolyline(ring, width: sw, closed: true, color: stroke)
                case "trapezoid":
                    let inset = rect.width * 0.15
                    let ring = [
                        CGPoint(x: rect.minX + inset, y: rect.minY), CGPoint(x: rect.maxX - inset, y: rect.minY),
                        CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                    ]
                    solid.fillConvexRing(ring, color: fill)
                    solid.strokePolyline(ring, width: sw, closed: true, color: stroke)
                case "trapezoid-alt":
                    let inset = rect.width * 0.15
                    let ring = [
                        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                        CGPoint(x: rect.maxX - inset, y: rect.maxY), CGPoint(x: rect.minX + inset, y: rect.maxY),
                    ]
                    solid.fillConvexRing(ring, color: fill)
                    solid.strokePolyline(ring, width: sw, closed: true, color: stroke)
                case "cylinder":
                    let ry: CGFloat = config.cylinderEllipseRadius * scale
                    let body = CGRect(x: rect.minX, y: rect.minY + ry, width: rect.width, height: rect.height - 2 * ry)
                    solid.fillRect(body, color: fill)
                    solid.strokePolyline([CGPoint(x: rect.minX, y: rect.minY + ry), CGPoint(x: rect.minX, y: rect.maxY - ry)],
                        width: sw, closed: false, color: stroke)
                    solid.strokePolyline([CGPoint(x: rect.maxX, y: rect.minY + ry), CGPoint(x: rect.maxX, y: rect.maxY - ry)],
                        width: sw, closed: false, color: stroke)
                    solid.fillEllipse(CGRect(x: rect.minX, y: rect.maxY - 2 * ry, width: rect.width, height: 2 * ry), color: fill)
                    solid.strokeEllipse(CGRect(x: rect.minX, y: rect.maxY - 2 * ry, width: rect.width, height: 2 * ry), width: sw, color: stroke)
                    solid.fillEllipse(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2 * ry), color: fill)
                    solid.strokeEllipse(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2 * ry), width: sw, color: stroke)
                case "subroutine":
                    solid.fillRect(rect, color: fill)
                    solid.strokePolyline(closedRing(rect), width: sw, closed: true, color: stroke)
                    let inset: CGFloat = config.subroutineInset * scale
                    solid.strokePolyline([CGPoint(x: rect.minX + inset, y: rect.minY), CGPoint(x: rect.minX + inset, y: rect.maxY)],
                        width: sw, closed: false, color: stroke)
                    solid.strokePolyline([CGPoint(x: rect.maxX - inset, y: rect.minY), CGPoint(x: rect.maxX - inset, y: rect.maxY)],
                        width: sw, closed: false, color: stroke)
                case "asymmetric":
                    let indent: CGFloat = 12 * scale
                    let ring = [
                        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                        CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                        CGPoint(x: rect.minX + indent, y: rect.midY),
                    ]
                    solid.fillConvexRing(ring, color: fill)
                    solid.strokePolyline(ring, width: sw, closed: true, color: stroke)
                case "class-box":
                    solid.fillRoundedRect(rect, radius: 4 * scale, color: fill)
                    solid.strokePolyline(closedRingOfRounded(rect, radius: 4 * scale), width: sw, closed: true, color: stroke)
                default:
                    solid.fillRect(rect, color: fill)
                    solid.strokePolyline(closedRing(rect), width: sw, closed: true, color: stroke)
                }
            }
        }

        func closedRing(_ r: CGRect) -> [CGPoint] {
            [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
             CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
             CGPoint(x: r.minX, y: r.minY)]
        }

        func closedRingOfRounded(_ r: CGRect, radius: CGFloat) -> [CGPoint] {
            var probe = MetalTessellator()
            let ring = probe.roundedRectRing(r, radius: radius)
            return ring + [ring[0]]
        }

        // MARK: Labels

        mutating func drawNodeLabels(_ nodes: [_PositionedNodePayload]) throws {
            let font = config.nodeLabelFont()
            for node in nodes {
                let rect = CGRect(x: node.x, y: node.y, width: node.width, height: node.height)
                let color = theme.nodeTextColor(for: node.inlineStyle)
                if node.label.contains("\n") {
                    let wide = CGRect(x: rect.minX - 500, y: rect.minY, width: rect.width + 1000, height: rect.height)
                    try emitTextIn(node.label, rect: wide, color: color, font: font, alignment: .center)
                } else {
                    try emitTextAt(node.label, point: CGPoint(x: rect.midX, y: rect.midY),
                        color: color, font: font, alignment: .center)
                }
            }
        }

        mutating func drawEdgeLabels(_ edges: [_PositionedEdgePayload]) throws {
            let edgeFont = config.edgeLabelFont()
            for edge in edges {
                guard let label = edge.label, let pos = edge.labelPosition else { continue }
                let attributes: [NSAttributedString.Key: Any] = [.font: edgeFont]
                let size = (label as NSString).size(withAttributes: attributes)
                let padding = config.edgeLabelPadding
                let pill = CGRect(
                    x: pos.x - size.width / 2 - padding,
                    y: pos.y - size.height / 2 - padding / 2,
                    width: size.width + padding * 2,
                    height: size.height + padding)
                let pr = R(pill)
                solid.fillRoundedRect(pr, radius: config.edgeLabelCornerRadius * scale,
                    color: color(theme.background))
                solid.strokePolyline(closedRingOfRounded(pr, radius: config.edgeLabelCornerRadius * scale),
                    width: config.edgeLabelBorderWidth * scale,
                    closed: true, color: color(theme.effectiveInnerStroke()))
                try emitTextAt(label, point: CGPoint(x: pos.x, y: pos.y),
                    color: theme.effectiveTextSecondary(), font: edgeFont, alignment: .center)
            }
        }

        mutating func drawGroupLabels(_ groups: [_PositionedGroupPayload]) throws {
            let headerFont = config.groupHeaderFont()
            for group in groups {
                if group.label.contains("\n") {
                    let rect = CGRect(x: group.x + 8, y: group.y,
                        width: group.width - 16, height: group.headerHeight)
                    try emitTextIn(group.label, rect: rect,
                        color: theme.effectiveTextSecondary(), font: headerFont, alignment: .center)
                } else {
                    let labelPoint = CGPoint(x: group.x + 8, y: group.y + group.headerHeight / 2)
                    try emitTextAt(group.label, point: labelPoint,
                        color: theme.effectiveTextSecondary(), font: headerFont, alignment: .left)
                }
                try drawGroupLabels(group.children)
            }
        }
    }

    // MARK: - Prepared diagram (mirrors PreparedDiagram for the CG path)

    /// Prepared Metal render of one positioned diagram at a fixed scale.
    /// `render()` runs fully on the GPU and reads the texture back; any
    /// Metal failure throws and the caller falls back to CoreGraphics.
    public struct MetalPreparedDiagram {
        var positioned: PositionedGraph
        var theme: DiagramTheme
        var config: RenderConfig
        var scale: CGFloat
        var renderer = MetalDiagramRenderer()

        var bounds: CGRect {
            CGRect(x: 0, y: 0, width: positioned.width, height: positioned.height)
        }

        var pixelSize: CGSize {
            CGSize(width: ceil(bounds.width * scale), height: ceil(bounds.height * scale))
        }

        func render() throws -> CGImage {
            try renderer.renderFlowchartCGImage(positioned, theme: theme, config: config, scale: scale)
        }
    }

    static func readback(texture: MTLTexture) throws -> CGImage {
        let w = texture.width, h = texture.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4,
            from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            throw MetalDiagramError.encodeFailed("readback provider failed")
        }
        guard let image = CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ) else {
            throw MetalDiagramError.encodeFailed("readback image failed")
        }
        return image
    }
}
