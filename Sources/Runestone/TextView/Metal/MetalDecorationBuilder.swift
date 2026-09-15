@preconcurrency import AppKit
import CoreText
import Foundation
import simd

/// Converts a `LineFragmentPaintSpec`'s decorations into Metal geometry: a 1:1 port of
/// `LineFragmentRenderer.drawHighlightedRanges` / `drawMarkedRange` / `drawInvisibleCharacters` /
/// `drawFoldPlaceholder` / `drawWarningBorder`, plus focus-mode alpha on the invisible-symbol glyphs.
///
/// - Filled / stroked / rounded rectangles (standard highlight, marked background, outline, fold
///   chip, warning border, straight underline) become `SolidInstance`s.
/// - Wavy squiggles become `DecorationVertex` triangle ribbons.
/// - Invisible-character symbols and the fold-placeholder text are tiny `CTLine`s rasterized into
///   the shared glyph atlas via `GlyphRunExtractor`.
///
/// Draw order (matching Core Graphics): `underlaySolids` + `underlayTriangles` paint *below* the
/// glyphs, `overlaySolids` + `overlayGlyphs` paint *above* them. `symbolGlyphs` sit with the text.
struct MetalDecorationGeometry: Equatable {
    var underlaySolids: [SolidInstance] = []
    var underlayTriangles: [DecorationVertex] = []
    var symbolGlyphs: [GlyphInstance] = []
    var overlaySolids: [SolidInstance] = []
    var overlayGlyphs: [GlyphInstance] = []

    var isEmpty: Bool {
        underlaySolids.isEmpty && underlayTriangles.isEmpty && symbolGlyphs.isEmpty
            && overlaySolids.isEmpty && overlayGlyphs.isEmpty
    }
}

enum MetalDecorationBuilder {
    /// Squiggle geometry, copied from `LineFragmentRenderer.drawLineHighlight(wavy:)`.
    static let squiggleAmplitude: CGFloat = 1.5
    static let squiggleWavelength: CGFloat = 4
    static let squiggleLineWidth: CGFloat = 1.2
    static let foldChipPadding: CGFloat = 4

    /// System 11 pt medium — the fold-placeholder face, matching `LineFragmentRenderer`
    /// (deliberately *not* the theme font atlased).
    @MainActor
    static var foldPlaceholderFont: UIFont {
        .systemFont(ofSize: 11, weight: .medium)
    }

    @MainActor
    static func build(
        spec: LineFragmentPaintSpec,
        atlas: GlyphAtlas,
        scale: CGFloat,
        budget: inout GlyphRasterBudget
    ) -> MetalDecorationGeometry {
        let context = Context(spec: spec, scale: max(scale, 0.001))
        var geometry = MetalDecorationGeometry()
        appendHighlights(spec.decorations.highlighted, context: context, into: &geometry)
        appendMarkedRange(spec.decorations, context: context, into: &geometry)
        appendInvisibleCharacters(spec.decorations, context: context, atlas: atlas, budget: &budget, into: &geometry)
        appendFoldPlaceholder(spec.decorations, context: context, atlas: atlas, budget: &budget, into: &geometry)
        return geometry
    }
}

private extension MetalDecorationBuilder {
    /// Per-fragment constants: content-space origin, height, and X resolution against the `CTLine`.
    struct Context {
        let line: CTLine
        let originX: CGFloat
        let originY: CGFloat
        let width: CGFloat
        let height: CGFloat
        let scale: CGFloat
        let appearance: NSAppearance?
        let fragmentRangeUpperBound: Int
        let endsWithLineBreak: Bool

        init(spec: LineFragmentPaintSpec, scale: CGFloat) {
            line = spec.line
            originX = spec.frame.minX
            originY = spec.frame.minY
            width = spec.frame.width
            height = spec.frame.height
            self.scale = scale
            appearance = spec.appearance
            fragmentRangeUpperBound = spec.decorations.fragmentRangeUpperBound
            endsWithLineBreak = spec.decorations.endsWithLineBreak
        }

        func x(at lineLocalIndex: Int) -> CGFloat {
            originX + CTLineGetOffsetForStringIndex(line, lineLocalIndex, nil)
        }

        var endOfLineX: CGFloat {
            originX + CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }

        func premultiplied(_ color: UIColor) -> SIMD4<Float> {
            MetalColor.premultipliedSRGB(color, appearance: appearance)
        }
    }

    // MARK: Highlights

    static func appendHighlights(
        _ highlights: [HighlightedRangeFragment],
        context: Context,
        into geometry: inout MetalDecorationGeometry
    ) {
        for highlight in highlights {
            switch highlight.style {
            case .standard:
                geometry.underlaySolids.append(standardHighlight(highlight, context: context))
            case .underline:
                geometry.underlaySolids.append(underline(highlight, context: context))
            case .squiggle:
                geometry.underlayTriangles.append(contentsOf: squiggle(highlight, context: context))
            case .outline(_, let fill):
                geometry.underlaySolids.append(outline(highlight, context: context, fill: fill))
            }
        }
    }

    static func standardHighlight(_ highlight: HighlightedRangeFragment, context: Context) -> SolidInstance {
        let startX = context.x(at: highlight.range.lowerBound)
        let extendsToLineEnd = highlight.range.upperBound == context.fragmentRangeUpperBound && context.endsWithLineBreak
        let endX = extendsToLineEnd ? context.originX + context.width : context.x(at: highlight.range.upperBound)
        let fillColor = highlight.isInactive ? highlight.color.withAlphaComponent(0.25) : highlight.color
        let corners = highlight.roundedCorners
        let radius = (!corners.isEmpty && highlight.cornerRadius > 0) ? highlight.cornerRadius : 0
        return SolidInstance(
            origin: SIMD2(Float(startX), Float(context.originY)),
            size: SIMD2(Float(max(endX - startX, 0)), Float(context.height)),
            fillColor: context.premultiplied(fillColor),
            strokeColor: SolidInstance.noColor,
            cornerRadius: Float(radius),
            strokeWidth: 0,
            roundedCornersMask: SolidInstance.cornerMask(from: corners)
        )
    }

    static func underline(_ highlight: HighlightedRangeFragment, context: Context) -> SolidInstance {
        let startX = context.x(at: highlight.range.lowerBound)
        let endX = context.x(at: highlight.range.upperBound)
        let y = context.originY + context.height - 2 - squiggleLineWidth / 2
        return SolidInstance(
            origin: SIMD2(Float(startX), Float(y)),
            size: SIMD2(Float(max(endX - startX, 0)), Float(squiggleLineWidth)),
            fillColor: context.premultiplied(highlight.color),
            strokeColor: SolidInstance.noColor,
            cornerRadius: Float(squiggleLineWidth / 2),
            strokeWidth: 0,
            roundedCornersMask: SolidInstance.allCornersMask
        )
    }

    static func outline(_ highlight: HighlightedRangeFragment, context: Context, fill: Bool) -> SolidInstance {
        let startX = context.x(at: highlight.range.lowerBound)
        let endX = context.x(at: highlight.range.upperBound)
        let inset: CGFloat = 1
        let rectX = startX - inset
        let rectWidth = max(endX - startX + inset * 2, 2)
        let strokeColor = context.premultiplied(highlight.color)
        let fillColor = fill ? context.premultiplied(highlight.color.withAlphaComponent(0.2)) : SolidInstance.noColor
        return SolidInstance(
            origin: SIMD2(Float(rectX), Float(context.originY + inset)),
            size: SIMD2(Float(rectWidth), Float(context.height - inset * 2)),
            fillColor: fillColor,
            strokeColor: strokeColor,
            cornerRadius: Float(highlight.cornerRadius),
            strokeWidth: 0.5,
            roundedCornersMask: SolidInstance.allCornersMask
        )
    }

    static func squiggle(_ highlight: HighlightedRangeFragment, context: Context) -> [DecorationVertex] {
        let startX = context.x(at: highlight.range.lowerBound)
        let endX = context.x(at: highlight.range.upperBound)
        guard endX > startX else {
            return []
        }
        let y = context.originY + context.height - 2
        var centerline: [CGPoint] = [CGPoint(x: startX, y: y)]
        var x = startX
        while x < endX {
            let midX = min(x + squiggleWavelength / 2, endX)
            let nextX = min(x + squiggleWavelength, endX)
            appendQuadCurve(
                from: centerline[centerline.count - 1],
                to: CGPoint(x: midX, y: y + squiggleAmplitude),
                control: CGPoint(x: (x + midX) / 2, y: y - squiggleAmplitude),
                into: &centerline
            )
            appendQuadCurve(
                from: centerline[centerline.count - 1],
                to: CGPoint(x: nextX, y: y),
                control: CGPoint(x: (midX + nextX) / 2, y: y + squiggleAmplitude),
                into: &centerline
            )
            x = nextX
        }
        return ribbon(from: centerline, halfWidth: squiggleLineWidth / 2, color: context.premultiplied(highlight.color))
    }

    static func appendQuadCurve(from start: CGPoint, to end: CGPoint, control: CGPoint, into points: inout [CGPoint], segments: Int = 6) {
        for step in 1...segments {
            let t = CGFloat(step) / CGFloat(segments)
            let inv = 1 - t
            let px = inv * inv * start.x + 2 * inv * t * control.x + t * t * end.x
            let py = inv * inv * start.y + 2 * inv * t * control.y + t * t * end.y
            points.append(CGPoint(x: px, y: py))
        }
    }

    static func ribbon(from centerline: [CGPoint], halfWidth: CGFloat, color: SIMD4<Float>) -> [DecorationVertex] {
        guard centerline.count >= 2 else {
            return []
        }
        var vertices: [DecorationVertex] = []
        vertices.reserveCapacity((centerline.count - 1) * 6)
        for index in 0..<(centerline.count - 1) {
            let a = centerline[index]
            let b = centerline[index + 1]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let length = max(hypot(dx, dy), 0.0001)
            let nx = -dy / length * halfWidth
            let ny = dx / length * halfWidth
            let a0 = SIMD2<Float>(Float(a.x + nx), Float(a.y + ny))
            let a1 = SIMD2<Float>(Float(a.x - nx), Float(a.y - ny))
            let b0 = SIMD2<Float>(Float(b.x + nx), Float(b.y + ny))
            let b1 = SIMD2<Float>(Float(b.x - nx), Float(b.y - ny))
            vertices.append(DecorationVertex(position: a0, color: color))
            vertices.append(DecorationVertex(position: a1, color: color))
            vertices.append(DecorationVertex(position: b0, color: color))
            vertices.append(DecorationVertex(position: a1, color: color))
            vertices.append(DecorationVertex(position: b1, color: color))
            vertices.append(DecorationVertex(position: b0, color: color))
        }
        return vertices
    }

    // MARK: Marked range

    static func appendMarkedRange(
        _ decorations: LineFragmentDecorations,
        context: Context,
        into geometry: inout MetalDecorationGeometry
    ) {
        guard let markedRange = decorations.markedRange else {
            return
        }
        let startX = context.x(at: markedRange.lowerBound)
        let endX = context.x(at: markedRange.upperBound)
        let radius = decorations.markedRadius > 0 ? decorations.markedRadius : 0
        geometry.underlaySolids.append(SolidInstance(
            origin: SIMD2(Float(startX), Float(context.originY)),
            size: SIMD2(Float(max(endX - startX, 0)), Float(context.height)),
            fillColor: context.premultiplied(decorations.markedColor),
            strokeColor: SolidInstance.noColor,
            cornerRadius: Float(radius),
            strokeWidth: 0,
            roundedCornersMask: SolidInstance.allCornersMask
        ))
    }

    // MARK: Invisible characters

    @MainActor
    static func appendInvisibleCharacters(
        _ decorations: LineFragmentDecorations,
        context: Context,
        atlas: GlyphAtlas,
        budget: inout GlyphRasterBudget,
        into geometry: inout MetalDecorationGeometry
    ) {
        let layout = decorations.invisibles
        guard !layout.isEmpty else {
            return
        }
        for warning in layout.warnings {
            geometry.overlaySolids.append(warningBorder(atX: context.originX + warning.x, decorations: decorations, context: context))
        }
        let font = decorations.invisibleFont
        for mark in layout.symbols {
            let color = mark.color ?? decorations.invisibleTextColor
            let markX = mark.isEndOfLine ? context.endOfLineX : context.originX + mark.x
            let glyphs = textGlyphs(
                mark.string,
                font: font,
                color: color,
                atX: markX,
                context: context,
                atlas: atlas,
                budget: &budget
            )
            geometry.symbolGlyphs.append(contentsOf: glyphs)
        }
    }

    static func warningBorder(atX x: CGFloat, decorations: LineFragmentDecorations, context: Context) -> SolidInstance {
        let pointSize = decorations.invisibleFont.pointSize
        let size = CGSize(width: max(pointSize * 0.55, 6), height: pointSize)
        let y = context.originY + (context.height - size.height) / 2
        return SolidInstance(
            origin: SIMD2(Float(x), Float(y)),
            size: SIMD2(Float(size.width), Float(size.height)),
            fillColor: SolidInstance.noColor,
            strokeColor: context.premultiplied(decorations.invisibleWarningColor),
            cornerRadius: 2,
            strokeWidth: 1,
            roundedCornersMask: SolidInstance.allCornersMask
        )
    }

    // MARK: Fold placeholder

    @MainActor
    static func appendFoldPlaceholder(
        _ decorations: LineFragmentDecorations,
        context: Context,
        atlas: GlyphAtlas,
        budget: inout GlyphRasterBudget,
        into geometry: inout MetalDecorationGeometry
    ) {
        guard let text = decorations.foldPlaceholder else {
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: decorations.foldPlaceholderColor,
            .font: foldPlaceholderFont
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let endOfLineX = context.endOfLineX
        let backgroundX = endOfLineX + foldChipPadding
        let backgroundY = context.originY + (context.height - size.height) / 2 - 1
        let backgroundWidth = size.width + foldChipPadding * 2
        let backgroundHeight = size.height + 2
        geometry.overlaySolids.append(SolidInstance(
            origin: SIMD2(Float(backgroundX), Float(backgroundY)),
            size: SIMD2(Float(backgroundWidth), Float(backgroundHeight)),
            fillColor: context.premultiplied(decorations.foldPlaceholderBackgroundColor),
            strokeColor: SolidInstance.noColor,
            cornerRadius: Float(backgroundHeight / 2),
            strokeWidth: 0,
            roundedCornersMask: SolidInstance.allCornersMask
        ))
        let textX = backgroundX + foldChipPadding
        geometry.overlayGlyphs.append(contentsOf: textGlyphs(
            text,
            font: foldPlaceholderFont,
            color: decorations.foldPlaceholderColor,
            atX: textX,
            context: context,
            atlas: atlas,
            budget: &budget
        ))
    }

    // MARK: Shared text rasterization

    @MainActor
    static func textGlyphs(
        _ string: String,
        font: UIFont,
        color: UIColor,
        atX x: CGFloat,
        context: Context,
        atlas: GlyphAtlas,
        budget: inout GlyphRasterBudget
    ) -> [GlyphInstance] {
        guard !string.isEmpty else {
            return []
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let symbolHeight = attributed.size().height
        let ascent = CGFloat(CTFontGetAscent(font as CTFont))
        // Core Graphics draws the symbol box top-aligned at (height - symbolHeight) / 2; the glyph
        // baseline within that box is `ascent` below the top.
        let baselineContentY = context.originY + (context.height - symbolHeight) / 2 + ascent
        // Feed the extractor a frame whose baseline formula collapses to `height`, so the glyph
        // baseline lands exactly at `baselineContentY`.
        let boxHeight = max(context.height, 1)
        let syntheticFrame = CGRect(
            x: x,
            y: baselineContentY - boxHeight,
            width: max(context.width, 1),
            height: boxHeight
        )
        let request = GlyphExtractRequest(
            line: ctLine,
            fragmentFrame: syntheticFrame,
            descent: 0,
            baseSize: CGSize(width: 0, height: boxHeight),
            scaledSize: CGSize(width: 0, height: boxHeight),
            unfocusedAlpha: 1,
            focusedRanges: [],
            scale: context.scale,
            emitRect: .infinite,
            atlasWarmRect: .null,
            fallbackFont: font as CTFont,
            fallbackColor: color,
            appearance: context.appearance
        )
        return GlyphRunExtractor.extract(request, atlas: atlas, budget: &budget).instances
    }
}
