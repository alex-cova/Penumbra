import CoreGraphics
import Foundation

/// Vertical-strip tile geometry for the Metal markdown preview, factored out of
/// ``MarkdownPreviewMetalRenderer`` so it can be unit-tested without a live Metal device (same
/// spirit as ``MetalCanvasGeometry``).
///
/// The full document is sliced into fixed-pixel-height horizontal strips stacked top to bottom.
/// Tile boundaries are integral device pixels, so neighbouring tiles abut exactly (no seams).
struct MarkdownPreviewTileGrid: Equatable {
    /// Full preview content size, in points.
    let contentSize: CGSize
    /// Backing scale factor the tiles are rasterized at.
    let scale: CGFloat
    /// Full content width, in device pixels.
    let pixelWidth: Int
    /// Height of one interior tile, in device pixels. The last tile may be shorter.
    let tilePixelHeight: Int
    /// Number of tiles covering the full content height.
    let tileCount: Int

    /// - Returns: `nil` only when the geometry is genuinely impossible to tile: a non-positive
    ///   size/scale, or a document wider than `MetalTextureUpload.maxTextureDimension` (out of
    ///   scope — horizontal tiling is not implemented; see the design brief).
    init?(contentSize: CGSize, scale: CGFloat, maxTilePixelHeight: Int = 4096) {
        guard contentSize.width > 0, contentSize.height > 0, scale > 0 else {
            return nil
        }
        let pixelWidth = Int((contentSize.width * scale).rounded(.up))
        guard pixelWidth > 0, pixelWidth <= MetalTextureUpload.maxTextureDimension else {
            return nil
        }
        // A tile must respect both the max-dimension and max-pixel-count GPU limits.
        let dimensionCap = MetalTextureUpload.maxTextureDimension
        let pixelCountCap = max(1, MetalTextureUpload.maxPixelCount / pixelWidth)
        let tilePixelHeight = max(1, min(maxTilePixelHeight, min(dimensionCap, pixelCountCap)))

        let pixelHeight = Int((contentSize.height * scale).rounded(.up))
        let tileCount = max(1, Int(ceil(Double(pixelHeight) / Double(tilePixelHeight))))

        self.contentSize = contentSize
        self.scale = scale
        self.pixelWidth = pixelWidth
        self.tilePixelHeight = tilePixelHeight
        self.tileCount = tileCount
    }

    /// Tile indices intersecting `visibleRect` (content points), expanded by `margin` tiles on
    /// each side and clamped to `0..<tileCount`.
    func indices(intersecting visibleRect: CGRect, margin: Int = 1) -> [Int] {
        guard tileCount > 0 else {
            return []
        }
        let tileHeightPt = CGFloat(tilePixelHeight) / scale
        guard tileHeightPt > 0 else {
            return []
        }
        let minY = max(0, visibleRect.minY)
        let maxY = max(minY, min(contentSize.height, visibleRect.maxY))
        guard maxY > minY || visibleRect.height >= 0 else {
            return []
        }
        let lastSampledY = max(minY, maxY - 0.0001)
        let minIndex = Int(floor(minY / tileHeightPt)) - margin
        let maxIndex = Int(floor(lastSampledY / tileHeightPt)) + margin
        let clampedMin = max(0, minIndex)
        let clampedMax = min(tileCount - 1, maxIndex)
        guard clampedMin <= clampedMax else {
            return []
        }
        return Array(clampedMin...clampedMax)
    }

    /// The content-space rect (points) this tile covers. Full width, clamped height for the
    /// last (possibly shorter) tile.
    func contentRect(for index: Int) -> CGRect {
        let tileHeightPt = CGFloat(tilePixelHeight) / scale
        let y = CGFloat(index) * tileHeightPt
        let height = max(0, min(tileHeightPt, contentSize.height - y))
        return CGRect(x: 0, y: y, width: contentSize.width, height: height)
    }

    /// The pixel dimensions to allocate for this tile's texture/bitmap context, derived directly
    /// from `contentRect(for:)` so the two never disagree about the last tile's height.
    func pixelSize(for index: Int) -> (width: Int, height: Int) {
        let rect = contentRect(for: index)
        let height = Int((rect.height * scale).rounded(.up))
        return (pixelWidth, max(0, height))
    }

    /// This tile's vertical offset from the top of the full content, in device pixels.
    func pixelOriginY(for index: Int) -> Int {
        index * tilePixelHeight
    }
}
