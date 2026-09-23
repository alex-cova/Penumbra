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
    static func deterministicPageOrder(_ pageIDs: [UInt32]) -> [UInt32] {
        pageIDs.sorted()
    }

    private struct GPUFragment {
        var frame: CGRect
        var lineID: DocumentLineNodeID
        var cacheKey: GlyphExtractCacheKey?
        var glyphs: [GlyphInstance]
        var alignedGlyphs: [GlyphInstance]?
        var colorSamples: [GlyphColorSample]
        var decorations: MetalDecorationGeometry
        var decorationKey: DecorationBuildKey?
        var decorationNeedsRetry = false
    }

    private struct DecorationBuildKey: Equatable {
        var frame: CGRect
        var lineRevision: UInt64
        var decorations: LineFragmentDecorations
        var scale: CGFloat
        var appearanceName: NSAppearance.Name?
        var usesDisplayP3: Bool
    }

    /// Triple-buffered per-atlas-page glyph instances.
    private final class PageBucket: @unchecked Sendable {
        var buffers: [GlyphInstanceBuffer]
        var cursor = 0
        private let slotCondition = NSCondition()
        private var inFlightCounts = [0, 0, 0]

        init(buffers: [GlyphInstanceBuffer]) {
            self.buffers = buffers
        }

        var current: GlyphInstanceBuffer {
            buffers[cursor]
        }

        func advanceForWrite() {
            slotCondition.lock()
            defer { slotCondition.unlock() }
            while true {
                for offset in 1...buffers.count {
                    let candidate = (cursor + offset) % buffers.count
                    if inFlightCounts[candidate] == 0 {
                        cursor = candidate
                        return
                    }
                }
                slotCondition.wait()
            }
        }

        func markCurrentInFlight(on commandBuffer: MTLCommandBuffer) {
            let slot = cursor
            slotCondition.lock()
            inFlightCounts[slot] += 1
            slotCondition.unlock()
            commandBuffer.addCompletedHandler { [slotCondition] _ in
                slotCondition.lock()
                self.inFlightCounts[slot] -= 1
                slotCondition.broadcast()
                slotCondition.unlock()
            }
        }
    }

    /// Triple-buffered raw struct array (`SolidInstance` or `DecorationVertex`).
    private final class DecorationBuffer: @unchecked Sendable {
        private let device: MTLDevice
        private let stride: Int
        private var buffers: [MTLBuffer?] = [nil, nil, nil]
        private var capacities = [0, 0, 0]
        private var cursor = 0
        private let slotCondition = NSCondition()
        private var inFlightCounts = [0, 0, 0]
        private(set) var count = 0

        init(device: MTLDevice, stride: Int) {
            self.device = device
            self.stride = stride
        }

        var current: MTLBuffer? {
            buffers[cursor]
        }

        func write<T>(_ items: [T]) {
            advanceForWrite()
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

        func markCurrentInFlight(on commandBuffer: MTLCommandBuffer) {
            guard count > 0, current != nil else {
                return
            }
            let slot = cursor
            slotCondition.lock()
            inFlightCounts[slot] += 1
            slotCondition.unlock()
            commandBuffer.addCompletedHandler { [slotCondition] _ in
                slotCondition.lock()
                self.inFlightCounts[slot] -= 1
                slotCondition.broadcast()
                slotCondition.unlock()
            }
        }

        private func advanceForWrite() {
            slotCondition.lock()
            defer { slotCondition.unlock() }
            while true {
                for offset in 1...buffers.count {
                    let candidate = (cursor + offset) % buffers.count
                    if inFlightCounts[candidate] == 0 {
                        cursor = candidate
                        return
                    }
                }
                slotCondition.wait()
            }
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
    private var needsGlyphBufferRebuild = false
    private var needsDecorationBufferRebuild = false
    /// Fragment IDs whose contribution changed since the last encode. This is the boundary used
    /// by the partial-update path; keeping it explicit avoids turning every invalidation into an
    /// implicit whole-viewport dirty state.
    private var dirtyFragmentIDs = Set<LineFragmentID>()
    private var dirtyPageIDs = Set<UInt32>()
    private var textPageContributions: [UInt32: [LineFragmentID: [GlyphInstance]]] = [:]
    private var overlayPageContributions: [UInt32: [LineFragmentID: [GlyphInstance]]] = [:]
    private var canvasUnderlaySolids: [SolidInstance] = []
    private var needsFullGlyphRebuild = false
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
    private var renderColorSpace: NSColorSpace = .sRGB

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
        var rasterCapSkipCount = 0
        var instanceRebuildNanos = 0
        var decorationBuildCount = 0
        var glyphBufferRebuildCount = 0
        var solidBufferRebuildCount = 0
        var atlasCoverageNonZeroTexels = 0
        var atlasCoverageTexelCount = 0
        var atlasCoveragePages = 0
        var atlasReadbackFailed = false
    }

    private var recentDrawNanos: [UInt64] = []
    private var lastInstanceCounts = (glyphs: 0, solids: 0)
    private var rasterCapSkipCount = 0
    private var lastInstanceRebuildNanos = 0
    private var decorationBuildCount = 0
    private var glyphBufferRebuildCount = 0
    private var solidBufferRebuildCount = 0

    var debugStats: DebugStats {
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
            rasterCapSkipCount: rasterCapSkipCount,
            instanceRebuildNanos: lastInstanceRebuildNanos,
            decorationBuildCount: decorationBuildCount,
            glyphBufferRebuildCount: glyphBufferRebuildCount,
            solidBufferRebuildCount: solidBufferRebuildCount
        )
    }

    /// Explicitly performs the expensive GPU readback used by atlas diagnostics. This is kept out
    /// of `debugStats` because every individual metric accessor may request that snapshot.
    func atlasCensus() -> (nonzero: Int, total: Int, pages: Int)? {
        atlas.debugCoverageTexelCensus()
    }

    /// Glyph instance colors currently held for `lineID` (all fragments of that line), or every
    /// fragment's colors when `lineID` is `nil`. Debug/test only — used to assert the white-flash
    /// regression directly instead of inferring it from pixel counts.
    func debugGlyphColors(forLineID lineID: DocumentLineNodeID? = nil) -> [SIMD4<Float>] {
        fragments.values
            .filter { lineID == nil || $0.lineID == lineID }
            .flatMap { $0.glyphs.map(\.color) }
    }

    func debugGlyphOrigins(forLineID lineID: DocumentLineNodeID? = nil) -> [SIMD2<Float>] {
        fragments.values
            .filter { lineID == nil || $0.lineID == lineID }
            .flatMap { $0.glyphs.map(\.origin) }
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
                                               vertexFunction: "penumbra_glyph_vertex",
                                               fragmentFunction: "penumbra_glyph_coverage_fragment"),
              let color = Self.makePipeline(device: device, library: library,
                                            vertexFunction: "penumbra_glyph_vertex",
                                            fragmentFunction: "penumbra_glyph_color_fragment"),
              let solid = Self.makePipeline(device: device, library: library,
                                            vertexFunction: "penumbra_solid_vertex",
                                            fragmentFunction: "penumbra_solid_fragment"),
              let line = Self.makePipeline(device: device, library: library,
                                           vertexFunction: "penumbra_decoration_line_vertex",
                                           fragmentFunction: "penumbra_decoration_line_fragment") else {
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
            alignedGlyphs: nil,
            colorSamples: [],
            decorations: MetalDecorationGeometry(),
            decorationKey: nil
        )
        // `LayoutManager` re-upserts every visible fragment on every layout pass (it's how
        // display-only invalidation — marked text, invisibles — gets a fresh spec; see the design
        // notes on "no ID-only decoration invalidate"), so most calls here are for fragments whose
        // rendered output hasn't actually changed. Compare before/after and only pay for a full
        // viewport instance-buffer rebuild (`rebuildInstanceBuffers`, below) when this fragment's
        // glyphs or decorations actually differ — not merely because it was touched again.
        let previousGlyphs = fragment.glyphs
        let previousDecorations = fragment.decorations
        let previousFrame = fragment.frame
        let frameChanged = previousFrame != spec.frame
        fragment.frame = spec.frame
        fragment.lineID = spec.lineID
        let shouldExtract = GlyphExtractCacheKey.shouldRebuild(
            previous: fragment.cacheKey,
            revision: spec.lineRevision,
            emitRect: emitRect,
            isPending: spec.isSyntaxHighlightPending
        ) || (spec.isSyntaxHighlightPending && previousFrame != spec.frame)
        if shouldExtract {
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
                appearance: spec.appearance,
                colorSpace: spec.colorSpace,
                previousColors: spec.isSyntaxHighlightPending ? fragment.colorSamples : []
            )
            let result = GlyphRunExtractor.extract(request, atlas: atlas, budget: &rasterBudget)
            fragment.glyphs = result.instances
            if result.skips.contains(where: { $0.reason == .rasterCap }) {
                rasterCapSkipCount += 1
                // Budget ran out mid-fragment; leave the cache key unset so the next layout pass
                // re-extracts with a fresh budget and fills in the rest.
                fragment.cacheKey = nil
                pendingRasterRetry = true
            } else {
                fragment.cacheKey = GlyphExtractCacheKey(
                    revision: spec.lineRevision,
                    emitRect: emitRect,
                    isPending: spec.isSyntaxHighlightPending
                )
            }
            if !spec.isSyntaxHighlightPending {
                fragment.colorSamples = result.glyphs.map {
                    GlyphColorSample(stringIndex: $0.stringIndex, color: $0.instance.color)
                }
            }
        } else if frameChanged, previousFrame != .zero {
            // Return at end-of-line does not change the following line's CTLine, so extract is
            // skipped. Origins were baked with the old fragmentFrame and must move with it.
            let delta = SIMD2(
                Float(spec.frame.minX - previousFrame.minX),
                Float(spec.frame.minY - previousFrame.minY)
            )
            if delta != .zero {
                fragment.glyphs = fragment.glyphs.map { instance in
                    var moved = instance
                    moved.origin += delta
                    return moved
                }
            }
        }
        if fragment.alignedGlyphs == nil
            || fragment.glyphs != previousGlyphs
            || previousFrame != spec.frame {
            fragment.alignedGlyphs = fragment.glyphs.map { instance in
                var aligned = instance
                aligned.origin = MetalProjection.pixelAligned(
                    instance.origin,
                    canvasFrame: canvasFrame,
                    scale: scale
                )
                return aligned
            }
        }
        let decorationKey = DecorationBuildKey(
            frame: spec.frame,
            lineRevision: spec.lineRevision,
            decorations: spec.decorations,
            scale: scale,
            appearanceName: spec.appearance?.name,
            usesDisplayP3: spec.colorSpace == .displayP3
        )
        if fragment.decorationKey != decorationKey
            || (fragment.decorationNeedsRetry && rasterBudget.hasRemaining) {
            decorationBuildCount += 1
            fragment.decorations = MetalDecorationBuilder.build(
                spec: spec,
                atlas: atlas,
                scale: scale,
                budget: &rasterBudget
            )
            fragment.decorationKey = decorationKey
            fragment.decorationNeedsRetry = rasterBudget.remaining == 0
        }
        let glyphsChanged = fragment.glyphs != previousGlyphs
        let decorationsChanged = fragment.decorations != previousDecorations
        let glyphPageContributionChanged = glyphsChanged || frameChanged
        if glyphPageContributionChanged || decorationsChanged {
            needsGlyphBufferRebuild = true
            dirtyFragmentIDs.insert(spec.id)
        }
        if decorationsChanged {
            needsDecorationBufferRebuild = true
            canvasView?.setNeedsDisplay()
        }
        if glyphPageContributionChanged {
            canvasView?.setNeedsDisplay()
        }
        fragments[spec.id] = fragment
        if glyphPageContributionChanged || decorationsChanged {
            updatePageContributions(for: spec.id, fragment: fragment)
        }
    }

    func removeFragments(ids: Set<LineFragmentID>) {
        guard !ids.isEmpty else {
            return
        }
        for id in ids {
            fragments.removeValue(forKey: id)
            dirtyFragmentIDs.insert(id)
            removePageContributions(for: id)
        }
        needsGlyphBufferRebuild = true
        needsDecorationBufferRebuild = true
        canvasView?.setNeedsDisplay()
    }

    func invalidateGlyphs(forLineIDs ids: Set<DocumentLineNodeID>) {
        guard !ids.isEmpty else {
            return
        }
        // Only drop the cache key, keeping `glyphs` in place. `upsertFragment`'s hold-previous
        // policy relies on these being the last *fully highlighted* glyphs so the frame between
        // this invalidation and the next highlighted re-upsert still presents real syntax colors
        // instead of a blank gap or `theme.textColor` (the white flash).
        for (fragmentID, fragment) in fragments where ids.contains(fragment.lineID) {
            fragments[fragmentID]?.cacheKey = nil
        }
        needsGlyphBufferRebuild = true
        needsDecorationBufferRebuild = true
        // Do not `setNeedsDisplay` here — a deferred present would encode this pass's stale
        // frame/decorations before layout/upsert rebuilds them.
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
                fragments[id]?.alignedGlyphs = nil
            }
        needsFullGlyphRebuild = true
            needsGlyphBufferRebuild = true
            needsDecorationBufferRebuild = true
            dirtyFragmentIDs.formUnion(fragments.keys)
        }
        canvasView?.setNeedsDisplay()
    }

    func setCanvasPaintSpec(_ spec: CanvasPaintSpec) {
        let colorSpaceChanged = renderColorSpace != spec.colorSpace
        renderColorSpace = spec.colorSpace
        if colorSpaceChanged {
            for id in fragments.keys {
                fragments[id]?.cacheKey = nil
                fragments[id]?.decorationKey = nil
            }
            needsFullGlyphRebuild = true
            needsGlyphBufferRebuild = true
            needsDecorationBufferRebuild = true
        }
        canvasView?.setOpaqueBackgroundColor(
            spec.backgroundColor,
            appearance: spec.appearance,
            colorSpace: spec.colorSpace
        )
        func solid(_ rect: CGRect, _ color: UIColor) -> SolidInstance {
            SolidInstance(
                origin: SIMD2(Float(rect.minX), Float(rect.minY)),
                size: SIMD2(Float(rect.width), Float(rect.height)),
                fillColor: MetalColor.premultiplied(
                    color,
                    appearance: spec.appearance,
                    colorSpace: spec.colorSpace
                ),
                strokeColor: SolidInstance.noColor,
                cornerRadius: 0,
                strokeWidth: 0,
                roundedCornersMask: 0
            )
        }
        var updated = [solid(spec.frame, spec.backgroundColor)]
        if let frame = spec.pageGuideFrame {
            let hairlineWidth = min(max(spec.pageGuideHairlineWidth, 0), frame.width)
            if spec.showsPageGuideShading, frame.width > hairlineWidth {
                updated.append(solid(
                    CGRect(
                        x: frame.minX + hairlineWidth,
                        y: frame.minY,
                        width: frame.width - hairlineWidth,
                        height: frame.height
                    ),
                    spec.pageGuideShadingColor
                ))
            }
            if hairlineWidth > 0 {
                updated.append(solid(
                    CGRect(x: frame.minX, y: frame.minY, width: hairlineWidth, height: frame.height),
                    spec.pageGuideHairlineColor
                ))
            }
        }
        if let lineSelectionRect = spec.lineSelectionRect {
            updated.append(solid(lineSelectionRect, spec.lineSelectionColor))
        }
        // Same stroke as the page-guide hairline, drawn across the text column.
        for frame in spec.methodSeparatorFrames where frame.width > 0 && frame.height > 0 {
            updated.append(solid(frame, spec.methodSeparatorColor))
        }
        guard updated != canvasUnderlaySolids else {
            return
        }
        canvasUnderlaySolids = updated
        needsDecorationBufferRebuild = true
        canvasView?.setNeedsDisplay()
    }

    func setNeedsDisplay() {
        canvasView?.setNeedsDisplay()
    }

    func invalidateForLineStructureChange() {
        needsFullGlyphRebuild = true
        needsGlyphBufferRebuild = true
        needsDecorationBufferRebuild = true
        dirtyFragmentIDs.formUnion(fragments.keys)
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
        needsFullGlyphRebuild = true
        needsGlyphBufferRebuild = true
        needsDecorationBufferRebuild = true
    }

    // MARK: - MetalCanvasGlyphEncoding

    func encode(
        into encoder: MTLRenderCommandEncoder,
        commandBuffer: MTLCommandBuffer,
        drawableSize: CGSize
    ) {
        let start = DispatchTime.now().uptimeNanoseconds
        var didDraw = false
        PenumbraSignposts.interval("MetalRenderer.draw") {
            if needsGlyphBufferRebuild || needsDecorationBufferRebuild {
                let rebuildStart = DispatchTime.now().uptimeNanoseconds
                rebuildInstanceBuffers(
                    rebuildGlyphs: needsGlyphBufferRebuild,
                    rebuildSolids: needsDecorationBufferRebuild
                )
                lastInstanceRebuildNanos = Int(DispatchTime.now().uptimeNanoseconds &- rebuildStart)
            }
            guard canvasFrame.width > 0, canvasFrame.height > 0 else {
                return
            }
            var uniforms = MetalProjection.uniforms(canvasFrame: canvasFrame, scale: scale)
            drawSolids(underlaySolidBuffer, encoder: encoder, commandBuffer: commandBuffer, uniforms: &uniforms)
            drawLines(underlayLineBuffer, encoder: encoder, commandBuffer: commandBuffer, uniforms: &uniforms)
            drawGlyphBuckets(
                textPageBuckets,
                order: textPageOrder,
                encoder: encoder,
                commandBuffer: commandBuffer,
                uniforms: &uniforms
            )
            drawSolids(overlaySolidBuffer, encoder: encoder, commandBuffer: commandBuffer, uniforms: &uniforms)
            drawGlyphBuckets(
                overlayPageBuckets,
                order: overlayPageOrder,
                encoder: encoder,
                commandBuffer: commandBuffer,
                uniforms: &uniforms
            )
            didDraw = true
        }
        recordDrawNanos(DispatchTime.now().uptimeNanoseconds &- start)
        if didDraw {
            needsGlyphBufferRebuild = false
            needsDecorationBufferRebuild = false
            dirtyFragmentIDs.removeAll(keepingCapacity: true)
            dirtyPageIDs.removeAll(keepingCapacity: true)
            needsFullGlyphRebuild = false
            rasterBudget = GlyphRasterBudget()
        }
    }

    func encodeForCapture(
        into encoder: MTLRenderCommandEncoder,
        commandBuffer: MTLCommandBuffer,
        drawableSize: CGSize
    ) {
        needsGlyphBufferRebuild = true
        needsDecorationBufferRebuild = true
        encode(into: encoder, commandBuffer: commandBuffer, drawableSize: drawableSize)
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
        PenumbraSignposts.event("MetalRenderer.skippedOffscreen")
        compactInstanceBuffers()
    }

    /// `theme.font` changed: drop the old face's shared-atlas tiles and force a re-extract of every
    /// visible fragment (the layout pass that follows re-typesets with the new font).
    func handleThemeFontChange(previousFont: CTFont) {
        atlas.invalidate(for: previousFont)
        for id in fragments.keys {
            fragments[id]?.cacheKey = nil
        }
        needsFullGlyphRebuild = true
        needsGlyphBufferRebuild = true
        needsDecorationBufferRebuild = true
        canvasView?.setNeedsDisplay()
    }
}

private extension MetalRenderer {
    private func updatePageContributions(for id: LineFragmentID, fragment: GPUFragment) {
        removePageContributions(for: id)
        var text: [UInt32: [GlyphInstance]] = [:]
        for instance in (fragment.alignedGlyphs ?? fragment.glyphs) where instance.atlasPage != 0 {
            text[instance.atlasPage, default: []].append(instance)
        }
        for instance in fragment.decorations.symbolGlyphs where instance.atlasPage != 0 {
            let aligned = pixelAligned(instance)
            text[aligned.atlasPage, default: []].append(aligned)
        }
        for (page, instances) in text {
            textPageContributions[page, default: [:]][id] = instances
            dirtyPageIDs.insert(page)
        }
        var overlay: [UInt32: [GlyphInstance]] = [:]
        for instance in fragment.decorations.overlayGlyphs where instance.atlasPage != 0 {
            let aligned = pixelAligned(instance)
            overlay[aligned.atlasPage, default: []].append(aligned)
        }
        for (page, instances) in overlay {
            overlayPageContributions[page, default: [:]][id] = instances
            dirtyPageIDs.insert(page)
        }
    }

    private func removePageContributions(for id: LineFragmentID) {
        for page in textPageContributions.keys {
            if textPageContributions[page]?.removeValue(forKey: id) != nil {
                dirtyPageIDs.insert(page)
            }
        }
        for page in overlayPageContributions.keys {
            if overlayPageContributions[page]?.removeValue(forKey: id) != nil {
                dirtyPageIDs.insert(page)
            }
        }
    }

    private func rebuildDirtyGlyphPages() {
        for pageID in dirtyPageIDs {
            let textInstances = sortedPageInstances(textPageContributions[pageID])
            let overlayInstances = sortedPageInstances(overlayPageContributions[pageID])
            writeGlyphPage(pageID, instances: textInstances, buckets: &textPageBuckets, order: &textPageOrder)
            writeGlyphPage(pageID, instances: overlayInstances, buckets: &overlayPageBuckets, order: &overlayPageOrder)
        }
        textPageOrder = textPageContributions.keys.sorted()
        overlayPageOrder = overlayPageContributions.keys.sorted()
        lastInstanceCounts.glyphs = textPageContributions.values.reduce(0) { pageTotal, contributions in
            pageTotal + contributions.values.reduce(0) { $0 + $1.count }
        } + overlayPageContributions.values.reduce(0) { pageTotal, contributions in
            pageTotal + contributions.values.reduce(0) { $0 + $1.count }
        }
    }

    private func sortedPageInstances(
        _ contributions: [LineFragmentID: [GlyphInstance]]?
    ) -> [GlyphInstance] {
        (contributions ?? [:])
            .sorted { lhs, rhs in lhs.key.id < rhs.key.id }
            .flatMap(\.value)
    }

    private func writeGlyphPage(
        _ pageID: UInt32,
        instances: [GlyphInstance],
        buckets: inout [UInt32: PageBucket],
        order: inout [UInt32]
    ) {
        guard let texture = atlas.pageTexture(id: pageID) else {
            buckets.removeValue(forKey: pageID)
            return
        }
        let bucket: PageBucket
        if let existing = buckets[pageID] {
            bucket = existing
        } else if let created = makeBucket() {
            buckets[pageID] = created
            bucket = created
        } else {
            return
        }
        bucket.advanceForWrite()
        bucket.current.write(instances)
        _ = texture
        if instances.isEmpty {
            order.removeAll { $0 == pageID }
        } else if !order.contains(pageID) {
            order.append(pageID)
            order.sort()
        }
    }

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

    private func rebuildInstanceBuffers(rebuildGlyphs: Bool, rebuildSolids: Bool) {
        if rebuildGlyphs, !needsFullGlyphRebuild, !dirtyPageIDs.isEmpty {
            rebuildDirtyGlyphPages()
            if !rebuildSolids {
                return
            }
        }
        var textByPage: [UInt32: [GlyphInstance]] = [:]
        var overlayByPage: [UInt32: [GlyphInstance]] = [:]
        var underlaySolids = canvasUnderlaySolids
        var overlaySolids: [SolidInstance] = []
        var underlayLines: [DecorationVertex] = []
        let orderedFragments = fragments.sorted {
            if $0.value.frame.minY != $1.value.frame.minY {
                return $0.value.frame.minY < $1.value.frame.minY
            }
            if $0.value.frame.minX != $1.value.frame.minX {
                return $0.value.frame.minX < $1.value.frame.minX
            }
            return $0.key.id < $1.key.id
        }.map(\.value)
        for fragment in orderedFragments {
            if rebuildGlyphs {
                for instance in (fragment.alignedGlyphs ?? fragment.glyphs) where instance.atlasPage != 0 {
                    textByPage[instance.atlasPage, default: []].append(instance)
                }
                for instance in fragment.decorations.symbolGlyphs where instance.atlasPage != 0 {
                    let aligned = pixelAligned(instance)
                    textByPage[aligned.atlasPage, default: []].append(aligned)
                }
                for instance in fragment.decorations.overlayGlyphs where instance.atlasPage != 0 {
                    let aligned = pixelAligned(instance)
                    overlayByPage[aligned.atlasPage, default: []].append(aligned)
                }
            }
            if rebuildSolids {
                underlaySolids.append(contentsOf: fragment.decorations.underlaySolids)
                overlaySolids.append(contentsOf: fragment.decorations.overlaySolids)
                underlayLines.append(contentsOf: fragment.decorations.underlayTriangles)
            }
        }
        if rebuildGlyphs {
            glyphBufferRebuildCount += 1
            rebuildGlyphBuckets(from: textByPage, buckets: &textPageBuckets, order: &textPageOrder)
            rebuildGlyphBuckets(from: overlayByPage, buckets: &overlayPageBuckets, order: &overlayPageOrder)
            let glyphCount = textByPage.values.reduce(0) { $0 + $1.count }
                + overlayByPage.values.reduce(0) { $0 + $1.count }
            lastInstanceCounts.glyphs = glyphCount
        }
        if rebuildSolids {
            solidBufferRebuildCount += 1
            underlaySolidBuffer.write(underlaySolids)
            overlaySolidBuffer.write(overlaySolids)
            underlayLineBuffer.write(underlayLines)
            lastInstanceCounts.solids = underlaySolids.count + overlaySolids.count
        }
        PenumbraSignposts.event("MetalRenderer.instanceCount")
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
                bucket.advanceForWrite()
                bucket.current.write([])
            }
        }
        order = []
        for pageID in Self.deterministicPageOrder(Array(instancesByPage.keys)) {
            guard let instances = instancesByPage[pageID] else {
                continue
            }
            let bucket: PageBucket
            if let existing = buckets[pageID] {
                bucket = existing
            } else if let created = makeBucket() {
                buckets[pageID] = created
                bucket = created
            } else {
                continue
            }
            bucket.advanceForWrite()
            bucket.current.write(instances)
            order.append(pageID)
        }
    }

    private func pixelAligned(_ instance: GlyphInstance) -> GlyphInstance {
        var aligned = instance
        aligned.origin = MetalProjection.pixelAligned(
            instance.origin,
            canvasFrame: canvasFrame,
            scale: scale
        )
        return aligned
    }

    private func drawGlyphBuckets(
        _ buckets: [UInt32: PageBucket],
        order: [UInt32],
        encoder: MTLRenderCommandEncoder,
        commandBuffer: MTLCommandBuffer,
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
            bucket.markCurrentInFlight(on: commandBuffer)
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
        commandBuffer: MTLCommandBuffer,
        uniforms: inout MetalProjectionUniforms
    ) {
        guard buffer.count > 0, let mtlBuffer = buffer.current else {
            return
        }
        buffer.markCurrentInFlight(on: commandBuffer)
        encoder.setRenderPipelineState(solidPipeline)
        encoder.setVertexBuffer(mtlBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalProjectionUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: buffer.count)
    }

    private func drawLines(
        _ buffer: DecorationBuffer,
        encoder: MTLRenderCommandEncoder,
        commandBuffer: MTLCommandBuffer,
        uniforms: inout MetalProjectionUniforms
    ) {
        guard buffer.count > 0, let mtlBuffer = buffer.current else {
            return
        }
        buffer.markCurrentInFlight(on: commandBuffer)
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
