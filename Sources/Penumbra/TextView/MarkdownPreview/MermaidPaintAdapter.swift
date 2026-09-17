import PenumbraBeautifulMermaid
@preconcurrency import AppKit
import CoreGraphics
import Metal

struct MermaidPaintResult: Equatable {
    var height: CGFloat
    var image: CGImage?
    var errorMessage: String?
}

@MainActor
final class MermaidTextureCache {
    private struct Key: Hashable {
        var sourceHash: Int
        var themeHash: Int
        var width: Int
        var scaleBits: UInt32
    }

    private var textures: [Key: MTLTexture] = [:]

    func texture(
        for image: CGImage,
        sourceHash: Int,
        themeHash: Int,
        device: MTLDevice
    ) -> MTLTexture? {
        let key = Key(
            sourceHash: sourceHash,
            themeHash: themeHash,
            width: image.width,
            scaleBits: 0
        )
        if let cached = textures[key] { return cached }
        guard let texture = makeTexture(from: image, device: device) else { return nil }
        textures[key] = texture
        return texture
    }

    func clear() {
        textures.removeAll()
    }

    private func makeTexture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = image.width
        let height = image.height
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

enum MermaidPaintAdapter {
    static let maxRasterDimension: CGFloat = 4096

    static func diagramTheme(from style: MarkdownPreviewStyle) -> DiagramTheme {
        diagramTheme(from: style.mermaidRenderingContext)
    }

    static func diagramTheme(from context: MarkdownPreviewStyle.MermaidRenderingContext) -> DiagramTheme {
        let background = context.backgroundRGBA
        let foreground = context.foregroundRGBA
        return DiagramTheme(
            background: BMColor(
                red: background.red,
                green: background.green,
                blue: background.blue,
                alpha: background.alpha
            ),
            foreground: BMColor(
                red: foreground.red,
                green: foreground.green,
                blue: foreground.blue,
                alpha: foreground.alpha
            )
        )
    }

    /// Lays out and rasterizes a mermaid diagram off the main actor.
    static func render(
        source: String,
        mermaidStyle: MarkdownPreviewStyle.MermaidRenderingContext,
        contentWidth: CGFloat
    ) async -> MermaidPaintResult {
        let theme = diagramTheme(from: mermaidStyle)
        do {
            let prepared = try await MermaidRenderer.prepareAsync(source: source, theme: theme)
            let bounds = prepared.bounds
            guard bounds.width > 0, bounds.height > 0 else {
                return MermaidPaintResult(height: 120, image: nil, errorMessage: "Empty diagram")
            }

            var scale: CGFloat = 2
            var pixelWidth = bounds.width * scale
            var pixelHeight = bounds.height * scale
            let maxDim = min(mermaidStyle.mermaidMaxDimension, maxRasterDimension)
            if pixelWidth > maxDim || pixelHeight > maxDim {
                let downscale = maxDim / max(pixelWidth, pixelHeight)
                scale *= downscale
                pixelWidth = bounds.width * scale
                pixelHeight = bounds.height * scale
            }

            let displayHeight = contentWidth * (bounds.height / bounds.width)
            let image = try await Task.detached {
                try rasterize(prepared: prepared, scale: scale, theme: theme)
            }.value

            return MermaidPaintResult(height: max(displayHeight, 80), image: image, errorMessage: nil)
        } catch {
            return MermaidPaintResult(height: 120, image: nil, errorMessage: error.localizedDescription)
        }
    }

    private static func rasterize(prepared: PreparedDiagram, scale: CGFloat, theme: DiagramTheme) throws -> CGImage? {
        let bounds = prepared.bounds
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return nil }

        if !theme.transparent {
            context.setFillColor(theme.background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        prepared.render(context, bounds)
        return context.makeImage()
    }

    static func drawPrepared(
        prepared: PreparedDiagram,
        in context: CGContext,
        frame: CGRect
    ) {
        let bounds = prepared.bounds
        guard bounds.width > 0, bounds.height > 0, frame.width > 0, frame.height > 0 else { return }
        let fitScale = min(frame.width / bounds.width, frame.height / bounds.height)
        let scaledWidth = bounds.width * fitScale
        let scaledHeight = bounds.height * fitScale
        let offsetX = frame.minX + (frame.width - scaledWidth) / 2
        let offsetY = frame.minY + (frame.height - scaledHeight) / 2

        context.saveGState()
        context.translateBy(x: 0, y: frame.maxY + frame.minY)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: offsetX, y: offsetY)
        context.scaleBy(x: fitScale, y: fitScale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        prepared.render(context, bounds)
        context.restoreGState()
    }
}
