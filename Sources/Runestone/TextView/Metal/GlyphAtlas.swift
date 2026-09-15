import CoreText
import Darwin
import Foundation
import Metal

struct GlyphAtlasConfiguration: Sendable {
    var hasUnifiedMemory: Bool
    var lruBudgetBytes: Int
    var coveragePageSize: Int
    var colorPageSize: Int
    var maxGlyphExtent: Int

    static func `default`(hasUnifiedMemory: Bool) -> GlyphAtlasConfiguration {
        GlyphAtlasConfiguration(
            hasUnifiedMemory: hasUnifiedMemory,
            lruBudgetBytes: GlyphAtlas.lruBudgetBytes,
            coveragePageSize: GlyphAtlas.coveragePageSize,
            colorPageSize: GlyphAtlas.colorPageSize,
            maxGlyphExtent: GlyphAtlas.maxGlyphExtentPixels
        )
    }
}

struct GlyphAtlasSlot {
    var texture: MTLTexture?
    var pageID: UInt32
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var originX: Float
    var originY: Float

    var isEmpty: Bool {
        width == 0 || height == 0
    }
}

enum GlyphAtlasResult {
    case hit(GlyphAtlasSlot)
    case oversize
    case failed
}

/// Coverage (R8) and color (BGRA) glyph atlas. Lookup, raster, and upload run on the main actor.
@MainActor
final class GlyphAtlas {
    nonisolated static let lruBudgetBytes = 32 * 1024 * 1024
    nonisolated static let maxGlyphExtentPixels = GlyphRasterizer.maxGlyphExtentPixels
    nonisolated static let coveragePageSize = 2048
    nonisolated static let colorPageSize = 1024
    /// 1 px between packed tiles so bilinear samples at slot edges stay in written texels.
    nonisolated static let packerGutterPixels = 1

    let storageMode: MTLStorageMode
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let configuration: GlyphAtlasConfiguration

    private var coveragePages: [AtlasPage] = []
    private var colorPages: [AtlasPage] = []
    private var cache: [GlyphKey: CacheEntry] = [:]
    private var nextPageID: UInt32 = 1
    private var lruClock: UInt64 = 0

    private(set) var hitCount = 0
    private(set) var missCount = 0
    /// Cumulative texel bytes uploaded to atlas pages this process (raster misses + prewarm).
    private(set) var uploadedBytes = 0

    nonisolated private static let prewarmQueue = DispatchQueue(label: "runestone.glyph-atlas.prewarm")

    init(device: MTLDevice, commandQueue: MTLCommandQueue, configuration: GlyphAtlasConfiguration) {
        self.device = device
        self.commandQueue = commandQueue
        self.configuration = configuration
        self.storageMode = configuration.hasUnifiedMemory ? .shared : .private
    }

    convenience init?(context: MetalContext = .shared, hasUnifiedMemory: Bool? = nil) {
        guard let device = context.device, let commandQueue = context.commandQueue else {
            return nil
        }
        let unified = hasUnifiedMemory ?? device.hasUnifiedMemory
        self.init(
            device: device,
            commandQueue: commandQueue,
            configuration: .default(hasUnifiedMemory: unified)
        )
    }

    convenience init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        hasUnifiedMemory: Bool,
        lruBudgetBytes: Int = GlyphAtlas.lruBudgetBytes,
        coveragePageSize: Int = GlyphAtlas.coveragePageSize,
        colorPageSize: Int = GlyphAtlas.colorPageSize,
        maxGlyphExtent: Int = GlyphAtlas.maxGlyphExtentPixels
    ) {
        self.init(
            device: device,
            commandQueue: commandQueue,
            configuration: GlyphAtlasConfiguration(
                hasUnifiedMemory: hasUnifiedMemory,
                lruBudgetBytes: lruBudgetBytes,
                coveragePageSize: coveragePageSize,
                colorPageSize: colorPageSize,
                maxGlyphExtent: maxGlyphExtent
            )
        )
    }

    var usedBytes: Int {
        coverageBytes + colorBytes
    }

    var coverageBytes: Int {
        coveragePages.reduce(0) { $0 + $1.byteCount }
    }

    var colorBytes: Int {
        colorPages.reduce(0) { $0 + $1.byteCount }
    }

    var coveragePageCount: Int { coveragePages.count }
    var colorPageCount: Int { colorPages.count }

    /// Texture backing the page `id` returned in a `GlyphAtlasSlot`, or `nil` if that page was evicted.
    func pageTexture(id: UInt32) -> MTLTexture? {
        if let page = coveragePages.first(where: { $0.id == id }) {
            return page.texture
        }
        return colorPages.first(where: { $0.id == id })?.texture
    }

    /// `true` when page `id` is a BGRA color page (emoji), `false` for an R8 coverage page.
    func isColorPage(id: UInt32) -> Bool {
        colorPages.contains { $0.id == id }
    }

    /// Drops every page and cached slot. Used when the backing scale changes (keys embed scale).
    func removeAll() {
        cache.removeAll()
        coveragePages.removeAll()
        colorPages.removeAll()
        hitCount = 0
        missCount = 0
    }

    /// Drops every cached tile for `font` (all sizes/matrices/scales) and evicts any page that
    /// becomes empty as a result. Called when `theme.font` changes so a swapped-out face does not
    /// keep occupying the shared atlas until LRU catches up.
    func invalidate(for font: CTFont) {
        let fontID = GlyphKey.fontID(for: font)
        let victims = cache.keys.filter { $0.fontID == fontID }
        guard !victims.isEmpty else {
            return
        }
        for key in victims {
            cache.removeValue(forKey: key)
        }
        for page in coveragePages + colorPages {
            let hadKeys = !page.keys.isEmpty
            page.keys.subtract(victims)
            if hadKeys && page.keys.isEmpty {
                evict(page)
            }
        }
    }
    var cachedGlyphCount: Int {
        cache.values.reduce(0) { count, entry in
            if case .slot = entry {
                return count + 1
            }
            return count
        }
    }

    func contains(_ key: GlyphKey) -> Bool {
        if case .slot = cache[key] {
            return true
        }
        return false
    }

    /// Slot or oversize — used so extract can skip the raster budget on a resident key.
    func hasEntry(_ key: GlyphKey) -> Bool {
        cache[key] != nil
    }

    func cached(_ key: GlyphKey) -> GlyphAtlasSlot? {
        if case .slot(let slot) = cache[key] {
            return slot
        }
        return nil
    }

    @discardableResult
    func lookup(
        font: CTFont,
        glyph: CGGlyph,
        scale: CGFloat,
        runMatrix: CGAffineTransform = .identity,
        subpixel: UInt8 = 0,
        isColor: Bool? = nil
    ) -> GlyphAtlasResult {
        let color = isColor ?? GlyphRasterizer.isColorFont(font)
        let key = GlyphKey.make(
            font: font,
            glyph: glyph,
            scale: scale,
            runMatrix: runMatrix,
            subpixel: subpixel,
            isColor: color
        )
        if let entry = cache[key] {
            switch entry {
            case .slot(let slot):
                hitCount += 1
                touch(pageID: slot.pageID)
                return .hit(slot)
            case .oversize:
                return .oversize
            }
        }
        missCount += 1
        RunestoneSignposts.event("GlyphAtlas.miss")
        switch GlyphRasterizer.rasterize(
            font: font,
            glyph: glyph,
            scale: scale,
            runMatrix: runMatrix,
            subpixel: subpixel,
            isColor: color,
            maxExtent: configuration.maxGlyphExtent
        ) {
        case .oversize:
            cache[key] = .oversize
            return .oversize
        case .empty:
            let slot = GlyphAtlasSlot(
                texture: nil,
                pageID: 0,
                x: 0,
                y: 0,
                width: 0,
                height: 0,
                originX: 0,
                originY: 0
            )
            cache[key] = .slot(slot)
            return .hit(slot)
        case .failed:
            return .failed
        case .bitmap(let bitmap):
            return upload(bitmap)
        }
    }

    /// Upload a bitmap into the atlas. `allowingPageSizedTile` lifts the per-glyph size cap so the
    /// whole-run raster fallback (PR 8) can pack a tile up to a full page.
    @discardableResult
    func upload(_ bitmap: GlyphBitmap, allowingPageSizedTile: Bool = false) -> GlyphAtlasResult {
        if let entry = cache[bitmap.key] {
            switch entry {
            case .slot(let slot):
                touch(pageID: slot.pageID)
                return .hit(slot)
            case .oversize:
                return .oversize
            }
        }
        let sizeCap = allowingPageSizedTile
            ? (bitmap.isColor ? configuration.colorPageSize : configuration.coveragePageSize)
            : configuration.maxGlyphExtent
        if bitmap.width > sizeCap || bitmap.height > sizeCap {
            cache[bitmap.key] = .oversize
            return .oversize
        }
        guard bitmap.width > 0, bitmap.height > 0 else {
            let slot = GlyphAtlasSlot(
                texture: nil,
                pageID: 0,
                x: 0,
                y: 0,
                width: 0,
                height: 0,
                originX: bitmap.originX,
                originY: bitmap.originY
            )
            cache[bitmap.key] = .slot(slot)
            return .hit(slot)
        }
        evictToFit(extraBytes: 0)
        guard let packed = pack(width: bitmap.width, height: bitmap.height, isColor: bitmap.isColor) else {
            return .failed
        }
        packed.page.lastUsed = tick()
        guard uploadPixels(bitmap, to: packed.page, x: packed.x, y: packed.y) else {
            return .failed
        }
        uploadedBytes += bitmap.width * bitmap.height * (bitmap.isColor ? 4 : 1)
        RunestoneSignposts.event("GlyphAtlas.uploadBytes")
        packed.page.keys.insert(bitmap.key)
        let slot = GlyphAtlasSlot(
            texture: packed.page.texture,
            pageID: packed.page.id,
            x: packed.x,
            y: packed.y,
            width: bitmap.width,
            height: bitmap.height,
            originX: bitmap.originX,
            originY: bitmap.originY
        )
        cache[bitmap.key] = .slot(slot)
        return .hit(slot)
    }

    /// Drops non-hot pages (keeps the most recently used coverage page and color page).
    func handleMemoryPressure() {
        let keepCoverage = coveragePages.max { $0.lastUsed < $1.lastUsed }
        let keepColor = colorPages.max { $0.lastUsed < $1.lastUsed }
        for page in coveragePages where page !== keepCoverage {
            evict(page)
        }
        for page in colorPages where page !== keepColor {
            evict(page)
        }
    }

    /// Builds printable Latin-1 CPU bitmaps (optionally off-main) and uploads on the main actor.
    func prewarm(
        font: CTFont,
        scale: CGFloat,
        runMatrix: CGAffineTransform = .identity,
        rasterizeOnBackground: Bool = true,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let snapshot = FontSnapshot(font: font, scale: scale, runMatrix: runMatrix, maxExtent: configuration.maxGlyphExtent)
        let finish: @MainActor @Sendable ([GlyphBitmap]) -> Void = { [weak self] bitmaps in
            guard let self else {
                completion?()
                return
            }
            for bitmap in bitmaps {
                _ = self.upload(bitmap)
            }
            completion?()
        }
        if rasterizeOnBackground {
            Self.prewarmQueue.async {
                let bitmaps = GlyphRasterizer.prewarmBitmaps(
                    font: snapshot.font,
                    scale: snapshot.scale,
                    runMatrix: snapshot.runMatrix,
                    maxExtent: snapshot.maxExtent
                )
                Task { @MainActor in
                    finish(bitmaps)
                }
            }
        } else {
            let bitmaps = GlyphRasterizer.prewarmBitmaps(
                font: snapshot.font,
                scale: snapshot.scale,
                runMatrix: snapshot.runMatrix,
                maxExtent: snapshot.maxExtent
            )
            finish(bitmaps)
        }
    }

    /// First coverage page texel census for PerfHarness / snapshot diagnostics. `nil` when no
    /// coverage page exists or readback fails.
    func debugCoverageTexelCensus() -> (nonzero: Int, total: Int, pages: Int)? {
        guard let page = coveragePages.first else {
            return (0, 0, 0)
        }
        let slot = GlyphAtlasSlot(
            texture: page.texture,
            pageID: page.id,
            x: 0,
            y: 0,
            width: page.texture.width,
            height: page.texture.height,
            originX: 0,
            originY: 0
        )
        guard let pixels = copyPixels(from: slot) else {
            return nil
        }
        var nonzero = 0
        for byte in pixels where byte != 0 {
            nonzero += 1
        }
        return (nonzero, pixels.count, coveragePages.count)
    }

    func copyPixels(from slot: GlyphAtlasSlot) -> Data? {
        guard let texture = slot.texture, slot.width > 0, slot.height > 0 else {
            return nil
        }
        let bytesPerPixel = texture.pixelFormat == .r8Unorm ? 1 : 4
        let alignment = max(bytesPerPixel, device.minimumLinearTextureAlignment(for: texture.pixelFormat))
        let bytesPerRow = alignedStride(slot.width * bytesPerPixel, alignment: alignment)
        let length = bytesPerRow * slot.height
        let region = MTLRegionMake2D(slot.x, slot.y, slot.width, slot.height)
        if texture.storageMode == .shared {
            var data = Data(count: length)
            data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else {
                    return
                }
                texture.getBytes(base, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
            }
            return tightlyPacked(data, width: slot.width, height: slot.height, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel)
        }
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            return nil
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: slot.x, y: slot.y, z: 0),
            sourceSize: MTLSize(width: slot.width, height: slot.height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: length
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let data = Data(bytes: buffer.contents(), count: length)
        return tightlyPacked(data, width: slot.width, height: slot.height, bytesPerRow: bytesPerRow, bytesPerPixel: bytesPerPixel)
    }
}

private extension GlyphAtlas {
    enum CacheEntry {
        case slot(GlyphAtlasSlot)
        case oversize
    }

    final class AtlasPage {
        let id: UInt32
        let texture: MTLTexture
        let isColor: Bool
        let byteCount: Int
        var packer: ShelfPacker
        var lastUsed: UInt64
        var keys: Set<GlyphKey> = []

        init(id: UInt32, texture: MTLTexture, isColor: Bool, byteCount: Int, packer: ShelfPacker, lastUsed: UInt64) {
            self.id = id
            self.texture = texture
            self.isColor = isColor
            self.byteCount = byteCount
            self.packer = packer
            self.lastUsed = lastUsed
        }
    }

    struct ShelfPacker {
        let width: Int
        let height: Int
        let gutter: Int
        var cursorX = 0
        var cursorY = 0
        var shelfHeight = 0

        init(width: Int, height: Int, gutter: Int = GlyphAtlas.packerGutterPixels) {
            self.width = width
            self.height = height
            self.gutter = gutter
        }

        mutating func allocate(width w: Int, height h: Int) -> (x: Int, y: Int)? {
            guard w > 0, h > 0, w <= width, h <= height else {
                return nil
            }
            if shelfHeight == 0 {
                cursorX = w + gutter
                cursorY = 0
                shelfHeight = h
                return (0, 0)
            }
            if cursorX + w <= width, h <= shelfHeight {
                let x = cursorX
                cursorX += w + gutter
                return (x, cursorY)
            }
            let newY = cursorY + shelfHeight + gutter
            if newY + h <= height, w <= width {
                cursorX = w + gutter
                cursorY = newY
                shelfHeight = h
                return (0, newY)
            }
            return nil
        }
    }

    struct FontSnapshot: @unchecked Sendable {
        let font: CTFont
        let scale: CGFloat
        let runMatrix: CGAffineTransform
        let maxExtent: Int
    }

    func tick() -> UInt64 {
        lruClock += 1
        return lruClock
    }

    func touch(pageID: UInt32) {
        guard pageID != 0 else {
            return
        }
        if let page = coveragePages.first(where: { $0.id == pageID }) {
            page.lastUsed = tick()
            return
        }
        if let page = colorPages.first(where: { $0.id == pageID }) {
            page.lastUsed = tick()
        }
    }

    func pack(width: Int, height: Int, isColor: Bool) -> (page: AtlasPage, x: Int, y: Int)? {
        let pages = isColor ? colorPages : coveragePages
        for page in pages {
            if let origin = page.packer.allocate(width: width, height: height) {
                return (page, origin.x, origin.y)
            }
        }
        let pageBytes = pageByteCount(isColor: isColor)
        evictToFit(extraBytes: pageBytes)
        guard let page = makePage(isColor: isColor) else {
            return nil
        }
        evictToFit(extraBytes: 0, protecting: page)
        guard let origin = page.packer.allocate(width: width, height: height) else {
            return nil
        }
        return (page, origin.x, origin.y)
    }

    func makePage(isColor: Bool) -> AtlasPage? {
        let size = isColor ? configuration.colorPageSize : configuration.coveragePageSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: isColor ? .bgra8Unorm : .r8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = storageMode
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        guard clearTexture(texture) else {
            return nil
        }
        let page = AtlasPage(
            id: nextPageID,
            texture: texture,
            isColor: isColor,
            byteCount: pageByteCount(isColor: isColor),
            packer: ShelfPacker(width: size, height: size),
            lastUsed: tick()
        )
        nextPageID += 1
        if isColor {
            colorPages.append(page)
        } else {
            coveragePages.append(page)
        }
        return page
    }

    func pageByteCount(isColor: Bool) -> Int {
        let size = isColor ? configuration.colorPageSize : configuration.coveragePageSize
        let bytesPerPixel = isColor ? 4 : 1
        return size * size * bytesPerPixel
    }

    func evictToFit(extraBytes: Int, protecting protected: AtlasPage? = nil) {
        let budget = configuration.lruBudgetBytes
        while usedBytes + extraBytes > budget {
            let candidates = (coveragePages + colorPages).filter { $0 !== protected }
            guard let victim = candidates.min(by: { $0.lastUsed < $1.lastUsed }) else {
                return
            }
            evict(victim)
        }
    }

    func evict(_ page: AtlasPage) {
        for key in page.keys {
            cache.removeValue(forKey: key)
        }
        page.keys.removeAll()
        coveragePages.removeAll { $0 === page }
        colorPages.removeAll { $0 === page }
    }

    func clearTexture(_ texture: MTLTexture) -> Bool {
        let bytesPerPixel = texture.pixelFormat == .r8Unorm ? 1 : 4
        let width = texture.width
        let height = texture.height
        let alignment = max(bytesPerPixel, device.minimumLinearTextureAlignment(for: texture.pixelFormat))
        let bytesPerRow = alignedStride(width * bytesPerPixel, alignment: alignment)
        let length = bytesPerRow * height
        if storageMode == .shared {
            let zeros = Data(count: length)
            zeros.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else {
                    return
                }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: bytesPerRow
                )
            }
            return true
        }
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            return false
        }
        memset(buffer.contents(), 0, length)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return false
        }
        blit.copy(
            from: buffer,
            sourceOffset: 0,
            sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: length,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return true
    }

    func uploadPixels(_ bitmap: GlyphBitmap, to page: AtlasPage, x: Int, y: Int) -> Bool {
        let format: MTLPixelFormat = bitmap.isColor ? .bgra8Unorm : .r8Unorm
        let bytesPerPixel = bitmap.isColor ? 4 : 1
        let alignment = max(bytesPerPixel, device.minimumLinearTextureAlignment(for: format))
        let alignedRow = alignedStride(bitmap.width * bytesPerPixel, alignment: alignment)
        let staging = stagingData(from: bitmap, alignedBytesPerRow: alignedRow, bytesPerPixel: bytesPerPixel)
        if storageMode == .shared {
            staging.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else {
                    return
                }
                page.texture.replace(
                    region: MTLRegionMake2D(x, y, bitmap.width, bitmap.height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: alignedRow
                )
            }
            return true
        }
        guard let buffer = device.makeBuffer(length: staging.count, options: .storageModeShared) else {
            return false
        }
        staging.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(buffer.contents(), base, staging.count)
            }
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return false
        }
        blit.copy(
            from: buffer,
            sourceOffset: 0,
            sourceBytesPerRow: alignedRow,
            sourceBytesPerImage: alignedRow * bitmap.height,
            sourceSize: MTLSize(width: bitmap.width, height: bitmap.height, depth: 1),
            to: page.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: x, y: y, z: 0)
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return true
    }

    func stagingData(from bitmap: GlyphBitmap, alignedBytesPerRow: Int, bytesPerPixel: Int) -> Data {
        let tightRow = bitmap.width * bytesPerPixel
        if bitmap.bytesPerRow == alignedBytesPerRow {
            if tightRow == bitmap.bytesPerRow {
                return bitmap.data
            }
        }
        var staged = Data(count: alignedBytesPerRow * bitmap.height)
        bitmap.data.withUnsafeBytes { srcRaw in
            staged.withUnsafeMutableBytes { dstRaw in
                guard let src = srcRaw.baseAddress, let dst = dstRaw.baseAddress else {
                    return
                }
                for row in 0..<bitmap.height {
                    memcpy(
                        dst + row * alignedBytesPerRow,
                        src + row * bitmap.bytesPerRow,
                        tightRow
                    )
                }
            }
        }
        return staged
    }
}

private func alignedStride(_ value: Int, alignment: Int) -> Int {
    let align = max(alignment, 1)
    return (value + align - 1) / align * align
}

private func tightlyPacked(_ data: Data, width: Int, height: Int, bytesPerRow: Int, bytesPerPixel: Int) -> Data {
    let tightRow = width * bytesPerPixel
    if bytesPerRow == tightRow {
        return data
    }
    var packed = Data(count: tightRow * height)
    data.withUnsafeBytes { srcRaw in
        packed.withUnsafeMutableBytes { dstRaw in
            guard let src = srcRaw.baseAddress, let dst = dstRaw.baseAddress else {
                return
            }
            for row in 0..<height {
                memcpy(dst + row * tightRow, src + row * bytesPerRow, tightRow)
            }
        }
    }
    return packed
}
