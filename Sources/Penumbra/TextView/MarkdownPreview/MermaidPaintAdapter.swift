import PenumbraLuna
@preconcurrency import AppKit
import CoreGraphics

struct MermaidPaintResult: Equatable {
    var height: CGFloat
    var image: CGImage?
    /// The diagram's unscaled size, in points (`prepared.bounds.size` before the raster `scale`
    /// multiplier) — lets the layout pass size the block to the diagram's natural extent instead
    /// of always stretching it to the full content width.
    var naturalSize: CGSize?
    var errorMessage: String?
}

enum MermaidPaintAdapter {
    static let maxRasterDimension: CGFloat = 4096

    static func diagramTheme(from style: MarkdownPreviewStyle) -> DiagramTheme {
        diagramTheme(from: style.mermaidRenderingContext)
    }

    static func diagramTheme(from context: MarkdownPreviewStyle.MermaidRenderingContext) -> DiagramTheme {
        let background = context.backgroundRGBA
        let foreground = context.foregroundRGBA
        let backgroundColor = BMColor(
            red: background.red,
            green: background.green,
            blue: background.blue,
            alpha: background.alpha
        )
        let foregroundColor = BMColor(
            red: foreground.red,
            green: foreground.green,
            blue: foreground.blue,
            alpha: foreground.alpha
        )
        // Seed from a full scheme so edge/series colors come from real roles:
        // with only bg/fg the accent falls back to the foreground, and in dark
        // mode the series hue rotation around near-white produces
        // white/salmon/red instead of the scheme's family.
        let brightness =
            0.299 * background.red + 0.587 * background.green + 0.114 * background.blue
        var theme = brightness < 0.5 ? DiagramTheme.umbra : DiagramTheme.zincLight
        theme.background = backgroundColor
        theme.foreground = foregroundColor
        return theme
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

            // Never upscale a diagram past its natural size: display width is capped at the
            // diagram's own point width, only shrinking (not growing) to fit `contentWidth`.
            let displayWidth = min(contentWidth, bounds.width)
            let displayHeight = displayWidth * (bounds.height / bounds.width)
            // `render` is nonisolated async, so this already runs off the main actor.
            // Metal first when opted in (flowchart/state only); any failure
            // falls back to the CoreGraphics raster below.
            if mermaidStyle.preferMetal,
               let metalImage = try? rasterizeMetal(source: source, scale: scale, theme: theme)
            {
                return MermaidPaintResult(
                    height: max(displayHeight, 80),
                    image: metalImage,
                    naturalSize: bounds.size,
                    errorMessage: nil
                )
            }
            let image = try rasterize(prepared: prepared, scale: scale, theme: theme)

            return MermaidPaintResult(
                height: max(displayHeight, 80),
                image: image,
                naturalSize: bounds.size,
                errorMessage: nil
            )
        } catch {
            return MermaidPaintResult(height: 120, image: nil, errorMessage: error.localizedDescription)
        }
    }

    /// Shared Metal renderer so the label atlas and pipelines persist across
    /// diagrams. Renders run off-main; `MetalDiagramRenderer` is internally
    /// synchronized.
    private static let sharedMetalRenderer = MetalDiagramRenderer()

    /// Metal raster for flowchart-family diagrams. Throws for other diagram
    /// types and on any Metal failure; the caller falls back to CoreGraphics.
    private static func rasterizeMetal(
        source: String, scale: CGFloat, theme: DiagramTheme
    ) throws -> CGImage? {
        let positioned = try MermaidRenderer.layout(source)
        guard positioned.width > 0, positioned.height > 0 else { return nil }
        return try sharedMetalRenderer.renderCGImage(positioned, theme: theme, scale: scale)
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
}
