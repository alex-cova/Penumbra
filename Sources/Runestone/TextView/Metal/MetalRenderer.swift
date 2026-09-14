@preconcurrency import AppKit
import CoreText
import Foundation
import Metal
import simd

/// `LinePaintBackend` that paints visible line fragments with a `CAMetalLayer` instead of one
/// layer-backed `LineFragmentView` per fragment.
///
/// `LayoutManager` drives it exactly like the CG backend: `upsertFragment` per visible fragment,
/// `removeFragments` for the ones that scrolled out, `setViewport` once per layout pass.
///
/// Per fragment it keeps:
/// - text glyph instances from `GlyphRunExtractor` (re-extracted only when the `CTLine` identity or
///   the cull rect changed), and
/// - decoration geometry from `MetalDecorationBuilder` (rebuilt every upsert): rounded/stroked
///   `SolidInstance`s, squiggle `DecorationVertex` triangles, and invisible-character / fold-text
///   glyphs.
///
/// `encode(into:)` draws one pass, in Core Graphics order: highlight & marked fills, squiggles,
/// text + invisibles, then warning borders / fold chips / fold text on top.
@MainActor
final class MetalRenderer: LinePaintBackend, MetalCanvasGlyphEncoding {
    private struct GPUFragment {
        var frame: CGRect
        var lineID: DocumentLineNodeID
        var cacheKey: GlyphExtractCacheKey?
        var glyphs: [GlyphInstance]
        var decorations: MetalDecorationGeometry
    }

    /// Triple-buffered per-atlas-page glyph instances.
    private final class PageBucket {
        var buffers: [GlyphInstanceBuffer]
        var cursor = 0

        init(buffers: [GlyphInstanceBuffer]) {
            self.buffers = buffers
        }

        var current: GlyphInstanceBuffer {
            buffers[cursor]
        }

        func advance() {
            cursor = (cursor + 1) % buffers.count
        }
    }

    /// Triple-buffered raw struct array (`SolidInstance` or `DecorationVertex`).
    private final class DecorationBuffer {
        private let device: MTLDevice
        private let stride: Int
        private var buffers: [MTLBuffer?] = [nil, nil, nil]
        private var capacities = [0, 0, 0]
        private var cursor = 0
        private(set) var count = 0

        init(device: MTLDevice, stride: Int) {
            self.device = device
            self.stride = stride
        }

        var current: MTLBuffer? {
            buffers[cursor]
        }

        func write<T>(_ items: [T]) {
            cursor = (cursor + 1) % buffers.count
            count = items.count
            guard !items.isEmpty else {
                return
            }
            let needed = items.count * stride
            if capacities[cursor] < needed {
                let capacity = max(needed, 4096)
                if let buffer = device.makeBuffer(length: capacity, options: .storageModeShared) {
                    buffers[cursor] = buffer
                    capacities[cursor] = capacity
                } else {
                    buffers[cursor] = nil
                    capacities[cursor] = 0
                }
            }
            guard let buffer = buffers[cursor] else {
                count = 0
                return
            }
            items.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    buffer.contents().copyMemory(from: base, byteCount: needed)
                }
            }
        }

        func compact() {
            buffers = [nil, nil, nil]
            capacities = [0, 0, 0]
            count = 0
        }
    }

    private weak var canvasView: MetalTextCanvasView?
    private let device: MTLDevice
    private let atlas: GlyphAtlas
    private let coveragePipeline: MTLRenderPipelineState
    private let colorPipeline: MTLRenderPipelineState
    private let solidPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private var fragments: [LineFragmentID: GPUFragment] = [:]
    private var textPageBuckets: [UInt32: PageBucket] = [:]
    private var textPageOrder: [UInt32] = []
    private var overlayPageBuckets: [UInt32: PageBucket] = [:]
    private var overlayPageOrder: [UInt32] = []
    private lazy var underlaySolidBuffer = DecorationBuffer(device: device, stride: MemoryLayout<SolidInstance>.stride)
    private lazy var overlaySolidBuffer = DecorationBuffer(device: device, stride: MemoryLayout<SolidInstance>.stride)
    private lazy var underlayLineBuffer = DecorationBuffer(device: device, stride: MemoryLayout<DecorationVertex>.stride)
    private var needsInstanceRebuild = false
    private var rasterBudget = GlyphRasterBudget()
    /// `true` when the last extract hit the per-pass raster cap — some emit-band glyphs are not yet
    /// on screen. `LayoutManager` re-drives layout (bounded) so they fill in over a few passes.
    private(set) var pendingRasterRetry = false
    /// Set by `LayoutManager`; invoked after an async atlas pre-warm finishes so a relayout picks up
    /// the now-resident tiles.
    var onAtlasWarmed: (() -> Void)?
    private var didPrewarm = Set<UInt64>()

    private var viewport: CGRect = .zero
    private var canvasFrame: CGRect = .zero
    private var scale: CGFloat = 2

    /// Debug/PerfHarness snapshot (see `TextView.metal*` accessors and Observability in the design).
    struct DebugStats {
        var fragmentCount = 0
        var glyphInstanceCount = 0
        var solidInstanceCount = 0
        var coverageAtlasBytes = 0
        var colorAtlasBytes = 0
        var drawNanosP95: Double = 0
        var glyphInstanceSize = 0
        var glyphInstanceStride = 0
        var glyphInstanceAlignment = 0
        var solidInstanceStride = 0
        var atlasCoverageNonZeroTexels = 0
        var atlasCoverageTexelCount = 0
        var atlasCoveragePages = 0
        var atlasReadbackFailed = false
    }

    private var recentDrawNanos: [UInt64] = []
    private var lastInstanceCounts = (glyphs: 0, solids: 0)

    var debugStats: DebugStats {
        let census = atlas.debugCoverageTexelCensus()
        return DebugStats(
            fragmentCount: fragments.count,
            glyphInstanceCount: lastInstanceCounts.glyphs,
            solidInstanceCount: lastInstanceCounts.solids,
            coverageAtlasBytes: atlas.coverageBytes,
            colorAtlasBytes: atlas.colorBytes,
            drawNanosP95: percentile(recentDrawNanos, 0.95),
            glyphInstanceSize: MemoryLayout<GlyphInstance>.size,
            glyphInstanceStride: MemoryLayout<GlyphInstance>.stride,
            glyphInstanceAlignment: MemoryLayout<GlyphInstance>.alignment,
            solidInstanceStride: MemoryLayout<SolidInstance>.stride,
            atlasCoverageNonZeroTexels: census?.nonzero ?? 0,
            atlasCoverageTexelCount: census?.total ?? 0,
            atlasCoveragePages: census?.pages ?? 0,
            atlasReadbackFailed: census == nil
        )
    }

    init?(canvasView: MetalTextCanvasView, context: MetalContext = .shared, atlas: GlyphAtlas? = nil) {
        guard context.isAvailable,
              let device = context.device,
              let library = context.library else {
            return nil
        }
        // Process-wide shared atlas (one budget across every `TextView`); tests may inject one.
        guard let providedAtlas = atlas ?? context.glyphAtlas else {
            return nil
        }
        guard let coverage = Self.makePipeline(device: device, library: library,
                                               vertexFunction: "runestone_glyph_vertex",
                                               fragmentFunction: "runestone_glyph_coverage_fragment"),
              let color = Self.makePipeline(device: device, library: library,
                                            vertexFunction: "runestone_glyph_vertex",
                                            fragmentFunction: "runestone_glyph_color_fragment"),
              let solid = Self.makePipeline(device: device, library: library,
                                            vertexFunction: "runestone_solid_vertex",
                                            fragmentFunction: "runestone_solid_fragment"),
              let line = Self.makePipeline(device: device, library: library,
                                           vertexFunction: "runestone_decoration_line_vertex",
                                           fragmentFunction: "runestone_decoration_line_fragment") else {
            return nil
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        // Atlas texels map 1:1 to device pixels. Linear filtering would blur Core Text's
        // already-antialiased coverage mask, especially at small editor font sizes.
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            return nil
        }
        self.canvasView = canvasView
        self.device = device
        self.atlas = providedAtlas
        self.coveragePipeline = coverage
        self.colorPipeline = color
        self.solidPipeline = solid
        self.linePipeline = line
        self.sampler = sampler
        canvasView.glyphEncoder = self
    }

    // MARK: - LinePaintBackend

    var trackedFragmentIDs: Set<LineFragmentID> {
        Set(fragments.keys)
    }

    func upsertFragment(_ spec: LineFragmentPaintSpec) {
        let emitRect = MetalProjection.emitRect(canvasFrame: canvasFrame)
        var fragment = fragments[spec.id] ?? GPUFragment(
            frame: spec.frame,
            lineID: spec.lineID,
            cacheKey: nil,
            glyphs: [],
            decorations: MetalDecorationGeometry()
        )
        fragment.frame = spec.frame
        fragment.lineID = spec.lineID
        if GlyphExtractCacheKey.shouldRebuild(previous: fragment.cacheKey, line: spec.line, emitRect: emitRect) {
            let request = GlyphExtractRequest(
                line: spec.line,
                fragmentFrame: spec.frame,
                descent: spec.descent,
                baseSize: spec.baseSize,
                scaledSize: spec.scaledSize,
                unfocusedAlpha: spec.decorations.unfocusedAlpha,
                focusedRanges: spec.decorations.focusedRanges,
                scale: scale,
                emitRect: emitRect,
                atlasWarmRect: MetalProjection.atlasWarmRect(canvasFrame: canvasFrame),
                fallbackFont: spec.fallbackFont,
                fallbackColor: spec.fallbackColor,
                appearance: spec.appearance
            )
            let result = GlyphRunExtractor.extract(request, atlas: atlas, budget: &rasterBudget)
            fragment.glyphs = result.instances
            if result.skips.contains(where: { $0.reason == .rasterCap }) {
                // Budget ran out mid-fragment; leave the cache key unset so the next layout pass
                // re-extracts with a fresh budget and fills in the rest.
                fragment.cacheKey = nil
                pendingRasterRetry = true
            } else {
                fragment.cacheKey = GlyphExtractCacheKey(line: spec.line, emitRect: emitRect)
            }
        }
        // Decorations rebuild every upsert (display-only invalidation re-upserts a fresh spec).
        fragment.decorations = MetalDecorationBuilder.build(
            spec: spec,
            atlas: atlas,
            scale: scale,
            budget: &rasterBudget
        )
        fragments[spec.id] = fragment
        needsInstanceRebuild = true
        canvasView?.setNeedsDisplay()
    }

    func removeFragments(ids: Set<LineFragmentID>) {
        guard !ids.isEmpty else {
            return
        }
        for id in ids {
            fragments.removeValue(forKey: id)
        }
        needsInstanceRebuild = true
        canvasView?.setNeedsDisplay()
    }

    func invalidateGlyphs(forLineIDs ids: Set<DocumentLineNodeID>) {
        guard !ids.isEmpty else {
            return
        }
        for (fragmentID, fragment) in fragments where ids.contains(fragment.lineID) {
            fragments[fragmentID]?.cacheKey = nil
        }
        needsInstanceRebuild = true
        canvasView?.setNeedsDisplay()
    }

    func setViewport(_ viewport: CGRect, canvasFrame: CGRect, scale: CGFloat) {
        let scaleChanged = abs(scale - self.scale) > 0.001
        self.viewport = viewport
        self.canvasFrame = canvasFrame
        self.scale = max(scale, 0.001)
        // `setViewport` runs once at the top of every `layoutLinesInViewport`, before any
        // `upsertFragment`. Reset the per-pass raster budget here so glyph extraction makes
        // progress even when no on-screen `draw(_:)` (which also resets it) has happened yet.
        rasterBudget = GlyphRasterBudget()
        if scaleChanged {
            // `GlyphKey` embeds the scale bucket, so a scale change only means this view must
            // re-extract at the new keys; the old-scale tiles age out via the shared atlas's LRU.
            // Never `removeAll()` here — other `TextView`s may still need those pages.
            for id in fragments.keys {
                fragments[id]?.cacheKey = nil
            }
            needsInstanceRebuild = true
        }
        canvasView?.setNeedsDisplay()
    }

    func setNeedsDisplay() {
        canvasView?.setNeedsDisplay()
    }

    func compactInstanceBuffers() {
        for bucket in textPageBuckets.values {
            bucket.buffers.forEach { $0.compact() }
        }
        for bucket in overlayPageBuckets.values {
            bucket.buffers.forEach { $0.compact() }
        }
        underlaySolidBuffer.compact()
        overlaySolidBuffer.compact()
        underlayLineBuffer.compact()
    }

    // MARK: - MetalCanvasGlyphEncoding

    func encode(into encoder: MTLRenderCommandEncoder, drawableSize: CGSize) {
        let start = DispatchTime.now().uptimeNanoseconds
        var didDraw = false
        RunestoneSignposts.interval("MetalRenderer.draw") {
            if needsInstanceRebuild {
                rebuildInstanceBuffers()
            }
            guard canvasFrame.width > 0, canvasFrame.height > 0 else {
                return
            }
            var uniforms = MetalProjection.uniforms(canvasFrame: canvasFrame, scale: scale)
            drawSolids(underlaySolidBuffer, encoder: encoder, uniforms: &uniforms)
            drawLines(underlayLineBuffer, encoder: encoder, uniforms: &uniforms)
            drawGlyphBuckets(textPageBuckets, order: textPageOrder, encoder: encoder, uniforms: &uniforms)
            drawSolids(overlaySolidBuffer, encoder: encoder, uniforms: &uniforms)
            drawGlyphBuckets(overlayPageBuckets, order: overlayPageOrder, encoder: encoder, uniforms: &uniforms)
            didDraw = true
        }
        recordDrawNanos(DispatchTime.now().uptimeNanoseconds &- start)
        if didDraw {
            needsInstanceRebuild = false
            rasterBudget = GlyphRasterBudget()
        }
    }

    func encodeForCapture(into encoder: MTLRenderCommandEncoder, drawableSize: CGSize) {
        needsInstanceRebuild = true
        encode(into: encoder, drawableSize: drawableSize)
    }

    /// `true` (once) when the last extract capped and needs another layout pass to finish.
    func consumePendingRasterRetry() -> Bool {
        defer { pendingRasterRetry = false }
        return pendingRasterRetry
    }

    /// Pre-rasterize Latin-1 + digits for `font` at `scale` so ASCII code never misses at extract
    /// time (idempotent per font/scale). Runs the raster off-main, uploads + relayouts on main.
    func prewarm(font: CTFont, scale: CGFloat) {
        let key = GlyphKey.matrixHash(fontMatrix: CTFontGetMatrix(font), runMatrix: .identity)
            ^ UInt64(bitPattern: Int64(CTFontGetSize(font) * scale * 64))
        guard didPrewarm.insert(key).inserted else {
            return
        }
        atlas.prewarm(font: font, scale: scale) { [weak self] in
            self?.pendingRasterRetry = true
            self?.onAtlasWarmed?()
        }
    }

    /// Called by `MetalTextCanvasView` when it leaves the window: give the grown instance buffers
    /// back so `EditorHostCache`'s off-screen hosts do not each pin ~24 MB.
    func hostDidLeaveWindow() {
        RunestoneSignposts.event("MetalRenderer.skippedOffscreen")
        compactInstanceBuffers()
    }

    /// `theme.font` changed: drop the old face's shared-atlas tiles and force a re-extract of every
    /// visible fragment (the layout pass that follows re-typesets with the new font).
    func handleThemeFontChange(previousFont: CTFont) {
        atlas.invalidate(for: previousFont)
        for id in fragments.keys {
            fragments[id]?.cacheKey = nil
        }
        needsInstanceRebuild = true
        canvasView?.setNeedsDisplay()
    }
}

private extension MetalRenderer {
    static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexFunction: String,
        fragmentFunction: String
    ) -> MTLRenderPipelineState? {
        guard let vertex = library.makeFunction(name: vertexFunction),
              let fragment = library.makeFunction(name: fragmentFunction) else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]
        attachment?.pixelFormat = .bgra8Unorm
        attachment?.isBlendingEnabled = true
        attachment?.rgbBlendOperation = .add
        attachment?.alphaBlendOperation = .add
        // Premultiplied source-over.
        attachment?.sourceRGBBlendFactor = .one
        attachment?.sourceAlphaBlendFactor = .one
        attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func rebuildInstanceBuffers() {
        var textByPage: [UInt32: [GlyphInstance]] = [:]
        var overlayByPage: [UInt32: [GlyphInstance]] = [:]
        var underlaySolids: [SolidInstance] = []
        var overlaySolids: [SolidInstance] = []
        var underlayLines: [DecorationVertex] = []
        for fragment in fragments.values {
            for instance in fragment.glyphs where instance.atlasPage != 0 {
                textByPage[instance.atlasPage, default: []].append(instance)
            }
            for instance in fragment.decorations.symbolGlyphs where instance.atlasPage != 0 {
                textByPage[instance.atlasPage, default: []].append(instance)
            }
            for instance in fragment.decorations.overlayGlyphs where instance.atlasPage != 0 {
                overlayByPage[instance.atlasPage, default: []].append(instance)
            }
            underlaySolids.append(contentsOf: fragment.decorations.underlaySolids)
            overlaySolids.append(contentsOf: fragment.decorations.overlaySolids)
            underlayLines.append(contentsOf: fragment.decorations.underlayTriangles)
        }
        rebuildGlyphBuckets(from: textByPage, buckets: &textPageBuckets, order: &textPageOrder)
        rebuildGlyphBuckets(from: overlayByPage, buckets: &overlayPageBuckets, order: &overlayPageOrder)
        underlaySolidBuffer.write(underlaySolids)
        overlaySolidBuffer.write(overlaySolids)
        underlayLineBuffer.write(underlayLines)
        let glyphCount = textByPage.values.reduce(0) { $0 + $1.count } + overlayByPage.values.reduce(0) { $0 + $1.count }
        lastInstanceCounts = (glyphs: glyphCount, solids: underlaySolids.count + overlaySolids.count)
        RunestoneSignposts.event("MetalRenderer.instanceCount")
    }

    private func recordDrawNanos(_ nanos: UInt64) {
        recentDrawNanos.append(nanos)
        if recentDrawNanos.count > 120 {
            recentDrawNanos.removeFirst(recentDrawNanos.count - 120)
        }
    }

    private func percentile(_ samples: [UInt64], _ fraction: Double) -> Double {
        guard !samples.isEmpty else {
            return 0
        }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return Double(sorted[index])
    }

    private func rebuildGlyphBuckets(
        from instancesByPage: [UInt32: [GlyphInstance]],
        buckets: inout [UInt32: PageBucket],
        order: inout [UInt32]
    ) {
        for pageID in Array(buckets.keys) {
            guard let bucket = buckets[pageID] else {
                continue
            }
            if atlas.pageTexture(id: pageID) == nil {
                buckets.removeValue(forKey: pageID)
            } else if instancesByPage[pageID] == nil {
                bucket.advance()
                bucket.current.write([])
            }
        }
        order = []
        for (pageID, instances) in instancesByPage {
            let bucket: PageBucket
            if let existing = buckets[pageID] {
                bucket = existing
            } else if let created = makeBucket() {
                buckets[pageID] = created
                bucket = created
            } else {
                continue
            }
            bucket.advance()
            let pixelAlignedInstances = instances.map { instance in
                var aligned = instance
                aligned.origin = MetalProjection.pixelAligned(
                    instance.origin,
                    canvasFrame: canvasFrame,
                    scale: scale
                )
                return aligned
            }
            bucket.current.write(pixelAlignedInstances)
            order.append(pageID)
        }
    }

    private func drawGlyphBuckets(
        _ buckets: [UInt32: PageBucket],
        order: [UInt32],
        encoder: MTLRenderCommandEncoder,
        uniforms: inout MetalProjectionUniforms
    ) {
        let stride = MemoryLayout<GlyphInstance>.stride
        for pageID in order {
            guard let bucket = buckets[pageID], let texture = atlas.pageTexture(id: pageID) else {
                continue
            }
            let buffer = bucket.current
            guard buffer.primaryCount > 0 || !buffer.overflowBuffers.isEmpty else {
                continue
            }
            encoder.setRenderPipelineState(atlas.isColorPage(id: pageID) ? colorPipeline : coveragePipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalProjectionUniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            if buffer.primaryCount > 0 {
                encoder.setVertexBuffer(buffer.metalBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: buffer.primaryCount)
            }
            for overflow in buffer.overflowBuffers {
                let overflowCount = overflow.length / stride
                guard overflowCount > 0 else {
                    continue
                }
                encoder.setVertexBuffer(overflow, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: overflowCount)
            }
        }
    }

    private func drawSolids(
        _ buffer: DecorationBuffer,
        encoder: MTLRenderCommandEncoder,
        uniforms: inout MetalProjectionUniforms
    ) {
        guard buffer.count > 0, let mtlBuffer = buffer.current else {
            return
        }
        encoder.setRenderPipelineState(solidPipeline)
        encoder.setVertexBuffer(mtlBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalProjectionUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: buffer.count)
    }

    private func drawLines(
        _ buffer: DecorationBuffer,
        encoder: MTLRenderCommandEncoder,
        uniforms: inout MetalProjectionUniforms
    ) {
        guard buffer.count > 0, let mtlBuffer = buffer.current else {
            return
        }
        encoder.setRenderPipelineState(linePipeline)
        encoder.setVertexBuffer(mtlBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalProjectionUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: buffer.count)
    }

    private func makeBucket() -> PageBucket? {
        var buffers: [GlyphInstanceBuffer] = []
        buffers.reserveCapacity(3)
        for _ in 0..<3 {
            guard let buffer = GlyphInstanceBuffer(device: device) else {
                return nil
            }
            buffers.append(buffer)
        }
        return PageBucket(buffers: buffers)
    }
}
