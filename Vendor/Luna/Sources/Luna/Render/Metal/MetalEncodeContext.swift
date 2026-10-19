import Foundation
import CoreGraphics
import Metal

/// Shared encode state for Luna's Metal renderers: theme/config/scale,
/// solid-geometry and per-texture tessellation streams, the label cache, and
/// the text-placement math that mirrors `LabelRenderer` exactly.
///
/// (Flowchart's nested encoder predates this type and keeps its own copies
/// to avoid churning proven code; all newer encoders build on this. Both
/// follow `LabelRenderer`, which is the single source of truth.)
struct MetalEncodeContext {
    var theme: DiagramTheme
    var config: RenderConfig
    var scale: CGFloat
    var solid = MetalTessellator()
    var streams: [ObjectIdentifier: MetalTessellator] = [:]
    var streamTextures: [ObjectIdentifier: MTLTexture] = [:]
    var labels: MetalLabelCache
    /// Device pixel rects of every emitted label quad, for tests.
    var debugLabelRects: [CGRect] = []
    /// When false, quads still render but are not recorded above. Used for
    /// known-approximation output (XY rotated titles) that no placement of
    /// axis-aligned quads can match.
    var recordDebugRects = true

    var texturedLayers: [(texture: MTLTexture, floats: [Float])] {
        streamTextures.compactMap { id, texture in
            guard let stream = streams[id] else { return nil }
            return (texture, stream.floats)
        }
    }

    mutating func withTex(_ texture: MTLTexture, _ body: (inout MetalTessellator) -> Void) {
        let id = ObjectIdentifier(texture)
        if streamTextures[id] == nil { streamTextures[id] = texture }
        var stream = streams[id] ?? MetalTessellator()
        body(&stream)
        streams[id] = stream
    }

    func color(_ c: BMColor) -> SIMD4<Float> {
        MetalDiagramRenderer.rgba(c)
    }

    func R(_ r: CGRect) -> CGRect {
        CGRect(x: r.origin.x * scale, y: r.origin.y * scale,
            width: r.width * scale, height: r.height * scale)
    }

    func P(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale, y: p.y * scale)
    }

    func closedRing(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
         CGPoint(x: r.minX, y: r.minY)]
    }

    func closedRingOfRounded(_ r: CGRect, radius: CGFloat) -> [CGPoint] {
        var probe = MetalTessellator()
        let ring = probe.roundedRectRing(r, radius: radius)
        return ring + [ring[0]]
    }

    // MARK: Text (placement math mirrors LabelRenderer exactly)

    mutating func emitLine(
        placement: MetalLabelCache.Placement,
        line: MetalLabelCache.Block.Line,
        at origin: CGPoint,
        color: BMColor
    ) {
        let s = placement.pixelSize
        let lw = line.size.width * scale
        let lh = line.size.height * scale
        guard lw >= 0.5, lh >= 0.5 else { return }
        let lx = origin.x, ly = origin.y
        // Bitmap row 0 is the block's visual top (verified by atlas
        // readback), matching texture row order: sample V straight down.
        let u0 = placement.uv.minX + (line.origin.x * scale) / s.width * placement.uv.width
        let u1 = u0 + lw / s.width * placement.uv.width
        let vTop = placement.uv.minY + (line.origin.y * scale) / s.height * placement.uv.height
        let vH = lh / s.height * placement.uv.height
        let vv0 = Float(vTop)
        let vv1 = Float(vTop + vH)
        let c = self.color(color)
        let fu0 = Float(u0), fu1 = Float(u1)
        withTex(placement.texture) { tess in
            tess.vertex(x: lx, y: ly, color: c, uvX: fu0, uvY: vv0, mode: 1)
            tess.vertex(x: lx + lw, y: ly, color: c, uvX: fu1, uvY: vv0, mode: 1)
            tess.vertex(x: lx + lw, y: ly + lh, color: c, uvX: fu1, uvY: vv1, mode: 1)
            tess.vertex(x: lx, y: ly, color: c, uvX: fu0, uvY: vv0, mode: 1)
            tess.vertex(x: lx + lw, y: ly + lh, color: c, uvX: fu1, uvY: vv1, mode: 1)
            tess.vertex(x: lx, y: ly + lh, color: c, uvX: fu0, uvY: vv1, mode: 1)
        }
        if recordDebugRects {
            debugLabelRects.append(CGRect(x: lx, y: ly, width: lw, height: lh))
        }
    }

    mutating func emitBlock(
        _ placement: MetalLabelCache.Placement,
        blockTopLeft: CGPoint,
        color: BMColor
    ) {
        for line in placement.block.lines {
            emitLine(placement: placement, line: line,
                at: CGPoint(x: blockTopLeft.x + line.origin.x * scale,
                    y: blockTopLeft.y + line.origin.y * scale),
                color: color)
        }
    }

    /// Mirrors `drawText(at:alignment:)`.
    mutating func emitTextAt(
        _ text: String, point: CGPoint, color: BMColor, font: BMFont, alignment: TextAlignment
    ) throws {
        guard !text.isEmpty else { return }
        let placement = try labels.placement(text: text, font: font, scale: scale)
        if text.contains("\n") {
            let lineHeight = font.pointSize * 1.3
            let top = point.y * scale - CGFloat(placement.block.lines.count) * lineHeight * scale / 2
            var ly = top
            for line in placement.block.lines {
                let cx = point.x * scale - line.size.width * scale / 2
                emitLine(placement: placement, line: line, at: CGPoint(x: cx, y: ly), color: color)
                ly += lineHeight * scale
            }
        } else {
            // Center on the measured line size (like CG), not the ceiled
            // block box: identical glyph placement down to the pixel.
            guard let first = placement.block.lines.first else { return }
            let w = first.size.width * scale, h = first.size.height * scale
            let ox: CGFloat
            switch alignment {
            case .left: ox = point.x * scale
            case .center: ox = point.x * scale - w / 2
            case .right: ox = point.x * scale - w
            }
            emitBlock(placement, blockTopLeft: CGPoint(x: ox, y: point.y * scale - h / 2), color: color)
        }
    }

    /// Mirrors `drawText(in:alignment:)`.
    mutating func emitTextIn(
        _ text: String, rect: CGRect, color: BMColor, font: BMFont, alignment: TextAlignment
    ) throws {
        guard !text.isEmpty else { return }
        let r = R(rect)
        let placement = try labels.placement(text: text, font: font, scale: scale)
        if text.contains("\n") {
            let lineHeight = font.pointSize * 1.3
            let blockH = CGFloat(placement.block.lines.count) * lineHeight * scale
            var ly = r.midY - blockH / 2
            for line in placement.block.lines {
                let cx = r.midX - line.size.width * scale / 2
                emitLine(placement: placement, line: line, at: CGPoint(x: cx, y: ly), color: color)
                ly += lineHeight * scale
            }
        } else {
            // Center on the measured line size (like CG), not the ceiled block box.
            guard let first = placement.block.lines.first else { return }
            let w = first.size.width * scale, h = first.size.height * scale
            let ox: CGFloat
            switch alignment {
            case .left: ox = r.minX
            case .center: ox = r.minX + (r.width - w) / 2
            case .right: ox = r.minX + r.width - w
            }
            let oy = r.minY + (r.height - h) / 2
            emitBlock(placement, blockTopLeft: CGPoint(x: ox, y: oy), color: color)
        }
    }
}
