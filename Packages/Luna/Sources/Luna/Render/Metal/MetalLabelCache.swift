import Foundation
import CoreGraphics
import CoreText
import Metal

#if targetEnvironment(macCatalyst)
import UIKit
#elseif canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// GPU label cache for Luna's Metal backend: each unique text block is
/// rasterized once with CoreText (using the exact measurement and placement
/// math of `LabelRenderer`, so quads land where CG would draw) and packed
/// into a shared atlas texture. Quads sample it as a coverage mask tinted by
/// the label color in the shader.
///
/// Bounded: the 2048² atlas plus dedicated oversize textures share a 16 MB
/// budget; atlas overflow clears the atlas (labels re-upload on demand).
/// Thread-safe; usable off the main thread.
final class MetalLabelCache {
    struct Key: Hashable {
        var text: String
        var fontName: String
        var fontSize: CGFloat
        var scale: CGFloat
    }

    /// One cached block: per-line bitmap offsets plus the atlas UV of the
    /// whole block. Lines share the block bitmap (multiline math included).
    struct Block {
        var lines: [Line]
        var blockSize: CGSize
        struct Line {
            var text: String
            var size: CGSize
            /// Offset of this line's bitmap rect inside the block bitmap (points, y-down).
            var origin: CGPoint
        }
    }

    struct Placement {
        var texture: MTLTexture
        /// UV rect of the whole block inside `texture` (v = 0 is the block's
        /// visual top; bitmap row 0 holds the first line).
        var uv: CGRect
        var block: Block
        /// Device-pixel size of the block bitmap.
        var pixelSize: CGSize
    }

    static let atlasDimension = 2048
    static let budgetBytes = 16 * 1024 * 1024

    private let lock = NSLock()
    private let device: MTLDevice
    private var atlas: MTLTexture?
    private var shelfX = 0
    private var shelfY = 0
    private var shelfH = 0
    private var entries: [Key: Placement] = [:]
    /// Dedicated (non-atlas) textures by key, for oversize blocks.
    private var dedicated: [Key: MTLTexture] = [:]
    private var lru: [Key] = []
    private(set) var atlasClears = 0
    private(set) var residentBytes = 0

    init?(device: MTLDevice) {
        self.device = device
    }

    /// Returns the cached placement, rasterizing and uploading on miss.
    /// Bitmaps are always white; the caller tints. Throws when the block
    /// cannot be placed (caller falls back to CG).
    func placement(
        text: String,
        font: BMFont,
        scale: CGFloat
    ) throws -> Placement {
        let key = Key(
            text: text,
            fontName: font.fontName,
            fontSize: font.pointSize,
            scale: scale
        )
        lock.lock(); defer { lock.unlock() }
        if let hit = entries[key] {
            touchLocked(key)
            return hit
        }
        let placement = try rasterizeLocked(key: key, font: font)
        entries[key] = placement
        touchLocked(key)
        evictLocked()
        return placement
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        dedicated.removeAll()
        lru.removeAll()
        atlas = nil
        shelfX = 0; shelfY = 0; shelfH = 0
        residentBytes = 0
    }

    // MARK: - Private

    private func touchLocked(_ key: Key) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }

    private func evictLocked() {
        while residentBytes > Self.budgetBytes, let oldest = lru.first {
            lru.removeFirst()
            entries.removeValue(forKey: oldest)
            if let tex = dedicated.removeValue(forKey: oldest) {
                residentBytes -= tex.width * tex.height * 4
            }
        }
        // Atlas bytes are accounted wholesale; clearing is the only relief.
        if residentBytes > Self.budgetBytes {
            clearAtlasLocked()
        }
    }

    private func rasterizeLocked(key: Key, font: BMFont) throws -> Placement {
        // Layout math mirrors LabelRenderer exactly (single line or \n block).
        let rawLines = key.text.components(separatedBy: "\n")
        let lineHeight = key.fontSize * 1.3
        var lines: [Block.Line] = []
        var maxWidth: CGFloat = 0
        for line in rawLines {
            let size = NSAttributedString(string: line, attributes: [.font: font]).size()
            maxWidth = max(maxWidth, size.width)
            lines.append(Block.Line(text: line, size: size, origin: .zero))
        }
        let blockHeight = CGFloat(max(rawLines.count, 1)) * lineHeight
        let blockWidth = max(1, ceil(maxWidth))
        // Per-line origins: vertically stacked like drawMultilineText; the
        // bitmap is tight around the block, lines drawn at their measured size.
        var laid: [Block.Line] = []
        for (i, line) in lines.enumerated() {
            laid.append(Block.Line(text: line.text, size: line.size,
                origin: CGPoint(x: 0, y: CGFloat(i) * lineHeight)))
        }
        let block = Block(lines: laid, blockSize: CGSize(width: blockWidth, height: blockHeight))

        let pxW = max(1, Int(ceil(blockWidth * key.scale)))
        let pxH = max(1, Int(ceil(blockHeight * key.scale)))
        guard let image = rasterizeBlock(block: block, font: font, width: pxW, height: pxH, scale: key.scale) else {
            throw MetalDiagramError.encodeFailed("label raster failed")
        }
        // Atlas pack (shelf); on overflow clear once and retry, else use a
        // dedicated texture (also the oversize path).
        if pxW <= Self.atlasDimension, pxH <= Self.atlasDimension {
            if let slot = claimAtlasSlot(width: pxW, height: pxH) {
                return placeInAtlas(slot: slot, image: image, block: block, pxW: pxW, pxH: pxH)
            }
            clearAtlasLocked()
            if let slot = claimAtlasSlot(width: pxW, height: pxH) {
                return placeInAtlas(slot: slot, image: image, block: block, pxW: pxW, pxH: pxH)
            }
        }
        guard let texture = makeTexture(width: pxW, height: pxH) else {
            throw MetalDiagramError.allocationFailed("label texture \(pxW)x\(pxH)")
        }
        texture.replace(region: MTLRegionMake2D(0, 0, pxW, pxH), mipmapLevel: 0,
            withBytes: image.bytes, bytesPerRow: pxW * 4)
        dedicated[key] = texture
        residentBytes += pxW * pxH * 4
        return Placement(texture: texture,
            uv: CGRect(x: 0, y: 0, width: 1, height: 1),
            block: block, pixelSize: CGSize(width: pxW, height: pxH))
    }

    private struct Bitmap {
        var bytes: [UInt8]
    }

    /// Rasterizes the block white-on-transparent (coverage mask); the shader
    /// tints it. Bitmap rows are bottom-first (CoreGraphics order); quads flip
    /// V when sampling.
    private func rasterizeBlock(block: Block, font: BMFont, width: Int, height: Int, scale: CGFloat) -> Bitmap? {
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // Flip so bitmap row 0 is the visual top (matches texture row order).
        context.translateBy(x: 0, y: CGFloat(height) / scale)
        context.scaleBy(x: 1, y: -1)
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let needsContext = NSGraphicsContext.current == nil
        if needsContext {
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        }
        #endif
        let white = BMColor(red: 1, green: 1, blue: 1, alpha: 1)
        for line in block.lines where !line.text.isEmpty {
            let attr = NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: white])
            attr.draw(in: CGRect(origin: line.origin, size: line.size))
        }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        if needsContext { NSGraphicsContext.current = nil }
        #endif
        guard let data = context.data else { return nil }
        let count = width * height * 4
        var bytes = [UInt8](repeating: 0, count: count)
        memcpy(&bytes, data, count)
        return Bitmap(bytes: bytes)
    }

    private struct Slot {
        var texture: MTLTexture
        var x: Int
        var y: Int
    }

    private func placeInAtlas(slot: Slot, image: Bitmap, block: Block, pxW: Int, pxH: Int) -> Placement {
        slot.texture.replace(
            region: MTLRegionMake2D(slot.x, slot.y, pxW, pxH),
            mipmapLevel: 0,
            withBytes: image.bytes,
            bytesPerRow: pxW * 4
        )
        let uv = CGRect(
            x: CGFloat(slot.x) / CGFloat(Self.atlasDimension),
            y: CGFloat(slot.y) / CGFloat(Self.atlasDimension),
            width: CGFloat(pxW) / CGFloat(Self.atlasDimension),
            height: CGFloat(pxH) / CGFloat(Self.atlasDimension)
        )
        return Placement(texture: slot.texture, uv: uv, block: block,
            pixelSize: CGSize(width: pxW, height: pxH))
    }

    private func clearAtlasLocked() {
        atlas = nil
        shelfX = 0; shelfY = 0; shelfH = 0
        atlasClears += 1
        entries.removeAll()
        residentBytes = dedicated.values.reduce(0) { $0 + $1.width * $1.height * 4 }
    }

    private func claimAtlasSlot(width: Int, height: Int) -> Slot? {
        if atlas == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: Self.atlasDimension,
                height: Self.atlasDimension, mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            // Zero-fill once: fresh textures expose uninitialized memory in
            // the 1px shelf gutters between slots, and linear filtering at
            // quad edges blends those texels in as nondeterministic colored
            // confetti. Zeros sample as transparent instead.
            let zeros = [UInt8](repeating: 0,
                count: Self.atlasDimension * Self.atlasDimension * 4)
            zeros.withUnsafeBytes { ptr in
                texture.replace(region: MTLRegionMake2D(0, 0, Self.atlasDimension, Self.atlasDimension),
                    mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: Self.atlasDimension * 4)
            }
            atlas = texture
            residentBytes += Self.atlasDimension * Self.atlasDimension * 4
        }
        guard let atlas else { return nil }
        if shelfX + width > Self.atlasDimension {
            shelfY += shelfH
            shelfX = 0
            shelfH = 0
        }
        guard shelfY + height <= Self.atlasDimension else { return nil }
        let slot = Slot(texture: atlas, x: shelfX, y: shelfY)
        shelfX += width + 1
        shelfH = max(shelfH, height + 1)
        return slot
    }

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        guard MetalDiagramBackend.canAllocate(width: width, height: height) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
}
