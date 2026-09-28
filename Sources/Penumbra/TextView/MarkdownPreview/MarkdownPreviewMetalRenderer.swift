@preconcurrency import AppKit
import Metal
import QuartzCore

/// Guards Metal texture allocation for preview tile rasterization.
enum MetalTextureUpload {
    /// Keeps uploads within typical GPU budgets (matches the mermaid raster cap).
    static let maxPixelCount = 16_777_216 // 4096 × 4096

    /// Conservative limit for Apple GPUs when building against the macOS 12 deployment target.
    static let maxTextureDimension = 16_384

    static func canAllocate(width: Int, height: Int, device: MTLDevice) -> Bool {
        guard width > 0, height > 0 else { return false }
        let maxDimension = maxTextureDimension
        guard width <= maxDimension, height <= maxDimension else { return false }
        guard height <= Int.max / width else { return false }
        return width * height <= maxPixelCount
    }
}

/// Metal paint backend for the markdown preview. The layout is rasterized into a cache of
/// fixed-height vertical tiles (``MarkdownPreviewTileGrid``) with Core Graphics, uploaded to
/// `MTLTexture`s, and blitted into a `CAMetalLayer` sized to the visible viewport — never the
/// full document — so documents of any height stay on the Metal path.
@MainActor
final class MarkdownPreviewMetalRenderer {
    /// Resident tile texture budget. At a typical ~525pt-wide preview, 2× scale, 1024px tiles
    /// cost ~4 MB each, so this keeps about 15 tiles (a viewport plus prefetched neighbors).
    private static let tileByteBudget = 64 * 1024 * 1024
    /// Tile height in device pixels: 512pt at 2×. Small enough that rasterizing one tile on
    /// the main thread doesn't drop a frame; the viewport needs two or three.
    static let tilePixelHeight = 1024
    /// Tiles above and below the viewport rasterized ahead of scrolling, one per main-queue
    /// turn so input events interleave.
    private static let prefetchMargin = 2

    private let metalView = MarkdownPreviewMetalCanvasView()

    private var layout = MarkdownPreviewLayout(blockLayouts: [], contentSize: .zero)
    private var style = MarkdownPreviewStyle()
    private var rasterImages: [Int: CGImage] = [:]
    private var highlightedCode: [Int: NSAttributedString] = [:]
    private var grid: MarkdownPreviewTileGrid?
    private var visibleRect: CGRect = .zero

    private var tiles: [Int: MTLTexture] = [:]
    /// Least-recently-used order, oldest first.
    private var tileLRU: [Int] = []

    var view: NSView { metalView }

    var isActive: Bool {
        get { !metalView.isHidden }
        set { metalView.isHidden = !newValue }
    }

    var backingScaleFactor: CGFloat {
        metalView.backingScaleFactor
    }

    /// Rebuilds the tile grid for a new layout/style/raster set and re-rasterizes whatever is
    /// currently visible. Tiles the change doesn't touch are kept (see `dropTiles(changedFrom:)`).
    /// Returns `false` only for a real failure (no Metal device, a document too wide to tile, or a
    /// texture/context allocation failure) — never for tall documents.
    @discardableResult
    func update(
        layout: MarkdownPreviewLayout,
        style: MarkdownPreviewStyle,
        rasterImages: [Int: CGImage],
        highlightedCode: [Int: NSAttributedString] = [:],
        keepingUnchangedTiles: Bool = true
    ) -> Bool {
        let newGrid = MetalContext.shared.device == nil
            ? nil
            : MarkdownPreviewTileGrid(
                contentSize: layout.contentSize, scale: metalView.backingScaleFactor, maxTilePixelHeight: Self.tilePixelHeight
            )
        if keepingUnchangedTiles, let oldGrid = grid, let newGrid, style == self.style {
            dropTiles(changedFrom: oldGrid, to: newGrid, oldLayout: self.layout, newLayout: layout,
                      oldImages: self.rasterImages, newImages: rasterImages)
        } else {
            dropAllTiles()
        }
        self.layout = layout
        self.style = style
        self.rasterImages = rasterImages
        self.highlightedCode = highlightedCode

        guard let device = MetalContext.shared.device, let grid = newGrid else {
            grid = nil
            presentFailure()
            return false
        }
        self.grid = grid

        // A leftover `visibleRect` from a previous (taller, or absent) document can sit entirely
        // past the new content height, which would make `rasterizeAndPresent` hand the canvas
        // zero tiles — a "successful" present of just the background color. Clamp it back onto
        // the new document, defaulting to the top when there is no overlap at all.
        if visibleRect.minY >= layout.contentSize.height || visibleRect == .zero {
            let height = min(visibleRect.height > 0 ? visibleRect.height : layout.contentSize.height, layout.contentSize.height)
            visibleRect = CGRect(x: 0, y: 0, width: layout.contentSize.width, height: height)
        }

        guard rasterizeAndPresent(device: device) else {
            self.grid = nil
            presentFailure()
            return false
        }
        return true
    }

    /// Call on scroll / layout with the currently visible rect, in content points. Rasterizes
    /// any newly visible tiles and re-presents.
    func setVisibleRect(_ rect: CGRect) {
        guard rect != visibleRect else { return }
        visibleRect = rect
        guard grid != nil, let device = MetalContext.shared.device else { return }
        _ = rasterizeAndPresent(device: device)
    }

    /// Number of tiles actually blitted into a real `CAMetalLayer` drawable on the last present.
    /// Requires the canvas to be in a window; stays `0` off-screen even when tile selection is
    /// working correctly. Exposed for tests to assert the pane is not silently presenting nothing.
    var presentedTileCount: Int {
        metalView.presentedTileCount
    }

    /// Number of tiles selected for the visible rect on the last `update()`/`setVisibleRect()`
    /// call, independent of whether the canvas is actually in a window to present them. Exposed
    /// for tests that check tile *selection* (e.g. a stale visible rect from a taller previous
    /// document not going empty) without needing a hosted `NSWindow`.
    private(set) var lastRequestedTileCount = 0

    /// Forces an immediate present if the canvas has pending tile/background changes.
    /// `layerContentsRedrawPolicy = .never` does not drive `updateLayer()` from `setNeedsDisplay`
    /// alone, so `MarkdownPreviewView.layout()` calls this once per layout pass as the primary
    /// trigger; the canvas's own deferred fallback covers everything else (scroll, async raster).
    func presentIfNeeded() {
        metalView.presentIfDirty()
    }

    /// Drops all cached tiles and re-derives the grid — call when `backingScaleFactor` or the
    /// effective appearance (semantic colors) changes.
    func invalidateAllTiles() {
        guard layout.contentSize != .zero else { return }
        _ = update(layout: layout, style: style, rasterImages: rasterImages, highlightedCode: highlightedCode,
                   keepingUnchangedTiles: false)
    }

    /// Tiles currently resident. Tests use it to check that an unchanged relayout keeps them.
    var residentTileCount: Int { tiles.count }

    func clear() {
        dropAllTiles()
        grid = nil
        layout = MarkdownPreviewLayout(blockLayouts: [], contentSize: .zero)
        presentFailure()
    }

    private func presentFailure() {
        metalView.setTiles([], backgroundColor: style.backgroundColor)
        metalView.setNeedsDisplay()
    }

    private func dropAllTiles() {
        tiles.removeAll()
        tileLRU.removeAll()
    }

    /// Drops the tiles whose pixels may differ between two layouts: those overlapping a block
    /// (or quote band) that moved, resized or changed content or raster image, plus any tile
    /// whose own extent changed with the content height. With the same width and scale, tile
    /// `i` covers the same document rect in both grids, so every other tile is still valid.
    private func dropTiles(
        changedFrom oldGrid: MarkdownPreviewTileGrid,
        to newGrid: MarkdownPreviewTileGrid,
        oldLayout: MarkdownPreviewLayout,
        newLayout: MarkdownPreviewLayout,
        oldImages: [Int: CGImage],
        newImages: [Int: CGImage]
    ) {
        guard !tiles.isEmpty else { return }
        guard oldGrid.pixelWidth == newGrid.pixelWidth, oldGrid.scale == newGrid.scale,
              oldGrid.tilePixelHeight == newGrid.tilePixelHeight else {
            dropAllTiles()
            return
        }
        var dirty: [CGRect] = []
        let oldBlocks = oldLayout.blockLayouts
        let newBlocks = newLayout.blockLayouts
        for index in 0 ..< max(oldBlocks.count, newBlocks.count) {
            let old = index < oldBlocks.count ? oldBlocks[index] : nil
            let new = index < newBlocks.count ? newBlocks[index] : nil
            if let old, let new, Self.paintsTheSame(old, new), oldImages[index] === newImages[index] {
                continue
            }
            // Past the first shifted block everything below usually moved too; one rect to the
            // end of the document covers it without walking the rest.
            let top = min(old?.frame.minY ?? .greatestFiniteMagnitude, new?.frame.minY ?? .greatestFiniteMagnitude)
            if let old, let new, old.frame.minY == new.frame.minY, old.frame.height == new.frame.height {
                dirty.append(old.frame.union(new.frame))
            } else {
                dirty.append(CGRect(x: 0, y: top, width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
                break
            }
        }
        if oldLayout.quoteDecorations != newLayout.quoteDecorations {
            for band in oldLayout.quoteDecorations.map(\.band) + newLayout.quoteDecorations.map(\.band) {
                dirty.append(band)
            }
        }
        // The last old tile may have been shorter than the new one at the same index.
        let firstResized = min(oldGrid.tileCount, newGrid.tileCount) - 1
        for index in Array(tiles.keys) {
            let rect = newGrid.contentRect(for: index).insetBy(dx: 0, dy: -8)
            let changed = index >= firstResized && oldGrid.contentRect(for: index) != newGrid.contentRect(for: index)
            if index >= newGrid.tileCount || changed || dirty.contains(where: { $0.intersects(rect) }) {
                tiles[index] = nil
                tileLRU.removeAll { $0 == index }
            }
        }
    }

    /// Same frames and same content. Typeset text is compared by identity: the layout's measure
    /// cache hands back the same object exactly when the block's content and width are unchanged.
    private static func paintsTheSame(_ lhs: MarkdownPreviewBlockLayout, _ rhs: MarkdownPreviewBlockLayout) -> Bool {
        guard lhs.frame == rhs.frame, lhs.textFrames == rhs.textFrames, lhs.markerFrames == rhs.markerFrames else {
            return false
        }
        if let left = lhs.text, let right = rhs.text {
            return left === right
        }
        return lhs.block == rhs.block && lhs.table == rhs.table
    }

    /// Bumped whenever the grid or its contents change, so a queued prefetch of a stale tile is
    /// dropped.
    private var tileGeneration = 0
    private var prefetchScheduled = false

    @discardableResult
    private func rasterizeAndPresent(device: MTLDevice) -> Bool {
        guard let grid else { return false }
        tileGeneration += 1
        let required = grid.indices(intersecting: visibleRect, margin: 0)

        for index in required where tiles[index] == nil {
            guard let texture = makeTileTexture(index: index, grid: grid, device: device) else {
                return false
            }
            tiles[index] = texture
        }
        touchLRU(with: required)
        evictIfNeeded(protecting: Set(required))
        schedulePrefetch()

        let scale = metalView.backingScaleFactor
        var presented: [MarkdownPreviewMetalCanvasView.Tile] = []
        presented.reserveCapacity(required.count)
        for index in required {
            guard let texture = tiles[index] else { continue }
            let originYPt = grid.contentRect(for: index).minY
            let destOriginYPx = ((originYPt - visibleRect.minY) * scale).rounded()
            presented.append(
                MarkdownPreviewMetalCanvasView.Tile(texture: texture, destOriginPx: CGPoint(x: 0, y: destOriginYPx))
            )
        }
        lastRequestedTileCount = presented.count
        metalView.setTiles(presented, backgroundColor: style.backgroundColor)
        metalView.setNeedsDisplay()
        return true
    }

    /// Rasterizes the nearest missing tile around the viewport on a later main-queue turn, then
    /// reschedules itself until the margin is filled. Tiles are never presented from here: the
    /// next scroll finds them resident.
    private func schedulePrefetch() {
        guard !prefetchScheduled else { return }
        prefetchScheduled = true
        let generation = tileGeneration
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.prefetchScheduled = false
                guard generation == self.tileGeneration, !self.metalView.isHidden,
                      let grid = self.grid, let device = MetalContext.shared.device else { return }
                let visible = Set(grid.indices(intersecting: self.visibleRect, margin: 0))
                let wanted = grid.indices(intersecting: self.visibleRect, margin: Self.prefetchMargin)
                let center = visible.isEmpty ? 0 : Double(visible.reduce(0, +)) / Double(visible.count)
                guard let next = wanted.filter({ self.tiles[$0] == nil })
                    .min(by: { abs(Double($0) - center) < abs(Double($1) - center) }),
                      let texture = self.makeTileTexture(index: next, grid: grid, device: device) else { return }
                self.tiles[next] = texture
                self.touchLRU(with: [next])
                self.evictIfNeeded(protecting: Set(wanted))
                self.schedulePrefetch()
            }
        }
    }

    private func touchLRU(with indices: [Int]) {
        for index in indices {
            tileLRU.removeAll { $0 == index }
            tileLRU.append(index)
        }
    }

    private func evictIfNeeded(protecting required: Set<Int>) {
        var residentBytes = tiles.values.reduce(0) { $0 + $1.allocatedSize }
        guard residentBytes > Self.tileByteBudget else { return }
        var cursor = 0
        while residentBytes > Self.tileByteBudget, cursor < tileLRU.count {
            let candidate = tileLRU[cursor]
            guard !required.contains(candidate) else {
                cursor += 1
                continue
            }
            if let texture = tiles.removeValue(forKey: candidate) {
                residentBytes -= texture.allocatedSize
            }
            tileLRU.remove(at: cursor)
        }
    }

    private func makeTileTexture(index: Int, grid: MarkdownPreviewTileGrid, device: MTLDevice) -> MTLTexture? {
        guard let context = makeTileContext(index: index, grid: grid), let data = context.data else { return nil }
        guard MetalTextureUpload.canAllocate(width: context.width, height: context.height, device: device) else {
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: context.width,
            height: context.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, context.width, context.height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: context.bytesPerRow
        )
        return texture
    }

    /// Rasterizes one tile's slice of the document into a `pixelSize(for:)`-sized bitmap.
    ///
    /// `MarkdownPreviewCGRenderer` assumes a top-down (flipped) context, matching what AppKit
    /// hands `MarkdownPreviewContentView.draw(_:)` for its `isFlipped == true` view. A bitmap
    /// context created here is native (bottom-up, unflipped), so the standard AppKit flip recipe
    /// is applied first. `translateBy(y: tileRect.maxY)` (not `tileRect.height`) additionally
    /// slides this tile's `[tileRect.minY, tileRect.maxY)` slice of the full-document coordinate
    /// space down to this context's own `[0, tileRect.height)` — block frames are passed through
    /// unmodified (global content coordinates), and CG clips anything outside the tile for free.
    ///
    /// Not `private`: unit-tested directly (no `MTLDevice` required) to guard the flip math
    /// against regressing back to the mirrored/upside-down rendering it replaced.
    func makeTileImage(index: Int, grid: MarkdownPreviewTileGrid) -> CGImage? {
        makeTileContext(index: index, grid: grid)?.makeImage()
    }

    /// Paints one tile into a bitmap already in the texture's layout (BGRA, premultiplied, row 0
    /// at the top), so its bytes upload with no conversion.
    private func makeTileContext(index: Int, grid: MarkdownPreviewTileGrid) -> CGContext? {
        let (pixelWidth, pixelHeight) = grid.pixelSize(for: index)
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: pixelWidth * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return nil
        }

        let tileRect = grid.contentRect(for: index)
        context.scaleBy(x: grid.scale, y: grid.scale)
        context.translateBy(x: 0, y: tileRect.maxY)
        context.scaleBy(x: 1, y: -1)

        MarkdownPreviewCGRenderer.draw(
            layout: layout,
            style: style,
            rasterImages: rasterImages,
            highlightedCode: highlightedCode,
            in: context,
            bounds: tileRect,
            clip: tileRect
        )

        return context
    }
}

@MainActor
final class MarkdownPreviewMetalCanvasView: NSView {
    struct Tile {
        let texture: MTLTexture
        /// Destination origin in the drawable, in device pixels (x is always 0 — no horizontal
        /// tiling — y may be negative or extend past the drawable for a partially visible tile).
        let destOriginPx: CGPoint
    }

    private var tiles: [Tile] = []
    private var backgroundColor: NSColor = .white

    /// Set on every successful `presentIfDirty()` — the regression guard for a canvas that stays
    /// `needsDisplay` forever without ever reaching a real `CAMetalLayer` present.
    private(set) var presentedTileCount = 0

    private var isDisplayDirty = false
    private var drawableRetryCount = 0
    private var presentRetryScheduled = false
    private var deferredPresentScheduled = false
    private static let maxDrawableRetries = 3

    /// Backing scale of the window this canvas is on (not `NSScreen.main`, which would be wrong
    /// for a window on a secondary display) — matches `MetalTextCanvasView.effectiveBackingScale`.
    var backingScaleFactor: CGFloat {
        window?.backingScaleFactor
            ?? window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // AppKit does not drive `updateLayer` from `layerContentsRedrawPolicy = .never` on its
        // own (see `MetalTextCanvasView`'s note on the same policy) — `presentIfDirty()` is
        // invoked explicitly by layout, plus a deferred/coalesced fallback below.
        layerContentsRedrawPolicy = .never
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MetalContext.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        // Tiles are blitted (not drawn), and a partially visible tile needs to be copied as a
        // clipped destination write, not a framebuffer render target — `framebufferOnly` would
        // make the drawable an illegal blit destination.
        metalLayer.framebufferOnly = false
        metalLayer.contentsScale = backingScaleFactor
        metalLayer.isOpaque = true
        metalLayer.presentsWithTransaction = false
        return metalLayer
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        presentIfDirty()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        // Every preview layout re-assigns the canvas frame; only a real resize needs a new frame.
        guard changed else { return }
        updateMetalLayerGeometry()
        setNeedsDisplay()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        updateMetalLayerGeometry()
        if !isHidden {
            setNeedsDisplay()
        }
    }

    private func updateMetalLayerGeometry() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        let scale = backingScaleFactor
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
    }

    /// The canvas is a fixed overlay in front of the scroll view; it must not intercept
    /// scroll-wheel/click events meant for the scroll view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func setTiles(_ tiles: [Tile], backgroundColor: NSColor) {
        self.tiles = tiles
        self.backgroundColor = backgroundColor
    }

    func setNeedsDisplay() {
        isDisplayDirty = true
        needsDisplay = true
        scheduleDeferredPresentIfNeeded()
    }

    /// `layerContentsRedrawPolicy = .never` means `needsDisplay = true` alone never reaches
    /// `updateLayer()`. Layout calls `presentIfDirty()` synchronously after it changes tiles; this
    /// covers callers that only invalidate (scroll, async raster completion) without a layout pass.
    private func scheduleDeferredPresentIfNeeded() {
        guard !deferredPresentScheduled else { return }
        deferredPresentScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deferredPresentScheduled = false
            self.presentIfDirty()
        }
    }

    /// Encode + present now if a display is pending. Safe to call redundantly (from layout, from
    /// the deferred fallback, and from `updateLayer()`) — a no-op once the frame is clean.
    func presentIfDirty() {
        guard window != nil, !isHidden, isDisplayDirty else { return }
        guard let metalLayer = layer as? CAMetalLayer else { return }
        updateMetalLayerGeometry()
        guard bounds.width > 0, bounds.height > 0,
              metalLayer.drawableSize.width > 1, metalLayer.drawableSize.height > 1 else {
            schedulePresentRetry()
            return
        }
        guard MetalContext.shared.isAvailable else { return }
        if present(on: metalLayer) {
            isDisplayDirty = false
            drawableRetryCount = 0
        } else {
            schedulePresentRetry()
        }
    }

    private func schedulePresentRetry() {
        guard !presentRetryScheduled, drawableRetryCount < Self.maxDrawableRetries else { return }
        presentRetryScheduled = true
        drawableRetryCount += 1
        DispatchQueue.main.async { [weak self] in
            self?.presentRetryScheduled = false
            self?.presentIfDirty()
        }
    }

    @discardableResult
    private func present(on metalLayer: CAMetalLayer) -> Bool {
        guard MetalContext.shared.isAvailable,
              let drawable = metalLayer.nextDrawable(),
              let commandQueue = MetalContext.shared.commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let clearColor = MetalColor.premultiplied(backgroundColor, appearance: effectiveAppearance, colorSpace: .sRGB)
        let alpha = max(clearColor.w, 0.0001)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clearColor.x / alpha),
            green: Double(clearColor.y / alpha),
            blue: Double(clearColor.z / alpha),
            alpha: 1
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
        encoder.endEncoding()

        if !tiles.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
            for tile in tiles {
                blitTile(tile, into: drawable.texture, using: blit)
            }
            blit.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
        presentedTileCount = tiles.count
        return true
    }

    private func blitTile(_ tile: Tile, into destination: MTLTexture, using blit: MTLBlitCommandEncoder) {
        let destOriginY = Int(tile.destOriginPx.y.rounded())
        let sourceHeight = tile.texture.height
        let sourceWidth = min(tile.texture.width, destination.width)
        guard sourceWidth > 0, sourceHeight > 0 else { return }

        // Clip the copy to the drawable's vertical extent for a tile that only partially
        // overlaps the viewport (its top or bottom row is above/below the visible area).
        let sourceStartY = max(0, -destOriginY)
        let destStartY = max(0, destOriginY)
        let copyHeight = min(sourceHeight - sourceStartY, destination.height - destStartY)
        guard copyHeight > 0 else { return }

        blit.copy(
            from: tile.texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: sourceStartY, z: 0),
            sourceSize: MTLSize(width: sourceWidth, height: copyHeight, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: destStartY, z: 0)
        )
    }
}
