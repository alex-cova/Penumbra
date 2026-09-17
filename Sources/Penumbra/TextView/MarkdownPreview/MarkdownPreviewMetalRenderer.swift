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
    /// Resident tile texture budget. At a typical ~525pt-wide preview, 2× scale, 4096px tiles
    /// cost ~17 MB each, so this keeps 3–4 tiles (a viewport plus margin) resident.
    private static let tileByteBudget = 64 * 1024 * 1024

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
    /// currently visible. Returns `false` only for a real failure (no Metal device, a document
    /// too wide to tile, or a texture/context allocation failure) — never for tall documents.
    @discardableResult
    func update(
        layout: MarkdownPreviewLayout,
        style: MarkdownPreviewStyle,
        rasterImages: [Int: CGImage],
        highlightedCode: [Int: NSAttributedString] = [:]
    ) -> Bool {
        self.layout = layout
        self.style = style
        self.rasterImages = rasterImages
        self.highlightedCode = highlightedCode
        dropAllTiles()

        guard let device = MetalContext.shared.device,
              let grid = MarkdownPreviewTileGrid(contentSize: layout.contentSize, scale: metalView.backingScaleFactor) else {
            grid = nil
            presentFailure()
            return false
        }
        self.grid = grid

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

    /// Drops all cached tiles and re-derives the grid — call when `backingScaleFactor` changes.
    func invalidateForScaleChange() {
        guard layout.contentSize != .zero else { return }
        _ = update(layout: layout, style: style, rasterImages: rasterImages, highlightedCode: highlightedCode)
    }

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

    @discardableResult
    private func rasterizeAndPresent(device: MTLDevice) -> Bool {
        guard let grid else { return false }
        let required = grid.indices(intersecting: visibleRect)

        for index in required where tiles[index] == nil {
            guard let texture = makeTileTexture(index: index, grid: grid, device: device) else {
                return false
            }
            tiles[index] = texture
        }
        touchLRU(with: required)
        evictIfNeeded(protecting: Set(required))

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
        metalView.setTiles(presented, backgroundColor: style.backgroundColor)
        metalView.setNeedsDisplay()
        return true
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
        guard let image = makeTileImage(index: index, grid: grid) else { return nil }
        return uploadTexture(from: image, device: device)
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
        let (pixelWidth, pixelHeight) = grid.pixelSize(for: index)
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
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

        return context.makeImage()
    }

    private func uploadTexture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = image.width
        let height = image.height
        guard MetalTextureUpload.canAllocate(width: width, height: height, device: device) else {
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        return texture
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

    var backingScaleFactor: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
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
        present()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let metalLayer = layer as? CAMetalLayer {
            let scale = backingScaleFactor
            metalLayer.drawableSize = CGSize(width: max(newSize.width * scale, 1), height: max(newSize.height * scale, 1))
        }
        setNeedsDisplay()
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
        needsDisplay = true
    }

    private func present() {
        guard MetalContext.shared.isAvailable,
              let metalLayer = layer as? CAMetalLayer,
              let drawable = metalLayer.nextDrawable(),
              let commandQueue = MetalContext.shared.commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

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
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.endEncoding()

        if !tiles.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
            for tile in tiles {
                blitTile(tile, into: drawable.texture, using: blit)
            }
            blit.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
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
