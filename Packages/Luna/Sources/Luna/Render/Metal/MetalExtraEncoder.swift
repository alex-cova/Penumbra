import Foundation
import CoreGraphics
import Metal

#if targetEnvironment(macCatalyst)
import UIKit
#elseif canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// ExtraFill → theme color, mirroring `DiagramRenderer+Extra._extraBMColor`.
func metalExtraColor(_ fill: ExtraFill, theme: DiagramTheme) -> BMColor {
    switch fill {
    case .none:
        return theme.background.withAlphaComponent(0)
    case .background:
        return theme.background
    case .foreground:
        return theme.foreground
    case .muted:
        return theme.effectiveMuted()
    case .accent:
        return theme.effectiveAccent()
    case .surface:
        return theme.effectiveSurface()
    case .border:
        return theme.effectiveBorder()
    case .series(let index):
        let hex = getSeriesColor(
            index,
            _hex(theme.effectiveAccent()) ?? CHART_ACCENT_FALLBACK,
            _hex(theme.background)
        )
        return BMColor(hex: hex)
    case .contrast(let base):
        guard let baseHex = _hex(metalExtraColor(base, theme: theme)),
              let fgHex = _hex(theme.foreground),
              let bgHex = _hex(theme.background)
        else { return theme.foreground }
        return BMColor(hex: pickContrastingHex(on: baseHex, fgHex, bgHex))
    case .translucent(let base):
        return metalExtraColor(base, theme: theme).withAlphaComponent(0.2)
    }
}

/// Extra font mapping, mirroring `_extraFont` (system font by size/weight).
func metalExtraFont(size: Double, weight: Int) -> BMFont {
    let cgSize = CGFloat(size)
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    let uiWeight: UIFont.Weight
    if weight >= 600 { uiWeight = .semibold }
    else if weight >= 500 { uiWeight = .medium }
    else { uiWeight = .regular }
    return UIFont.systemFont(ofSize: cgSize, weight: uiWeight)
    #elseif canImport(AppKit)
    let nsWeight: NSFont.Weight
    if weight >= 600 { nsWeight = .semibold }
    else if weight >= 500 { nsWeight = .medium }
    else { nsWeight = .regular }
    return NSFont.systemFont(ofSize: cgSize, weight: nsWeight)
    #endif
}

/// Metal encoder for `ExtraScene` display lists (pie, gantt, gitGraph,
/// journey, mindmap, timeline, quadrant, sankey, radar, treemap, venn,
/// packet, block, requirement, architecture, c4, kanban, usecase, treeView,
/// ishikawa, cynefin, wardley, eventmodeling, railroad, info): mirrors
/// `_drawExtraItem` item for item, in order.
struct MetalExtraEncoder {
    var ctx: MetalEncodeContext

    mutating func encode(scene: ExtraScene) throws {
        for item in scene.items {
            try drawItem(item)
        }
    }

    mutating func drawItem(_ item: ExtraItem) throws {
        switch item {
        case let .rect(x, y, width, height, fill, stroke, corner, dashed):
            let rect = ctx.R(CGRect(x: x, y: y, width: width, height: height))
            if fill != .none {
                let c = ctx.color(metalExtraColor(fill, theme: ctx.theme))
                if corner > 0 {
                    let r = min(corner * ctx.scale, rect.width / 2, rect.height / 2)
                    ctx.solid.fillRoundedRect(rect, radius: r, color: c)
                } else {
                    ctx.solid.fillRect(rect, color: c)
                }
            }
            if stroke != .none {
                let c = ctx.color(metalExtraColor(stroke, theme: ctx.theme))
                let ring: [CGPoint]
                if corner > 0 {
                    let r = min(corner * ctx.scale, rect.width / 2, rect.height / 2)
                    var probe = MetalTessellator()
                    let outline = probe.roundedRectRing(rect, radius: r)
                    ring = outline + [outline[0]]
                } else {
                    ring = ctx.closedRing(rect)
                }
                if dashed {
                    for run in MetalTessellator.dashRuns(ring, pattern: [4 * ctx.scale, 3 * ctx.scale]) {
                        ctx.solid.strokePolyline(run, width: 1 * ctx.scale, closed: false, color: c)
                    }
                } else {
                    ctx.solid.strokePolyline(ring, width: 1 * ctx.scale, closed: true, color: c)
                }
            }

        case let .ellipse(x, y, width, height, fill, stroke):
            let rect = ctx.R(CGRect(x: x, y: y, width: width, height: height))
            if fill != .none {
                ctx.solid.fillEllipse(rect, color: ctx.color(metalExtraColor(fill, theme: ctx.theme)))
            }
            if stroke != .none {
                ctx.solid.strokeEllipse(rect, width: 1.2 * ctx.scale,
                    color: ctx.color(metalExtraColor(stroke, theme: ctx.theme)))
            }

        case let .line(x1, y1, x2, y2, stroke, width, dashed):
            let c = ctx.color(metalExtraColor(stroke, theme: ctx.theme))
            let pts = [ctx.P(CGPoint(x: x1, y: y1)), ctx.P(CGPoint(x: x2, y: y2))]
            if dashed {
                for run in MetalTessellator.dashRuns(pts, pattern: [5 * ctx.scale, 4 * ctx.scale]) {
                    ctx.solid.strokePolyline(run, width: width * ctx.scale, closed: false, color: c)
                }
            } else {
                ctx.solid.strokePolyline(pts, width: width * ctx.scale, closed: false, color: c)
            }

        case let .polyline(points, fill, stroke, width, closed):
            let pts = points.map { ctx.P(CGPoint(x: $0.x, y: $0.y)) }
            guard pts.count >= 2 else { return }
            if fill != .none {
                ctx.solid.fillSimplePolygon(pts, color: ctx.color(metalExtraColor(fill, theme: ctx.theme)))
            }
            if stroke != .none {
                var ring = pts
                if closed, let first = pts.first { ring.append(first) }
                ctx.solid.strokePolyline(ring, width: width * ctx.scale, closed: false,
                    color: ctx.color(metalExtraColor(stroke, theme: ctx.theme)))
            }

        case let .wedge(cx, cy, radius, start, end, fill, stroke, innerRadius):
            let c = ctx.P(CGPoint(x: cx, y: cy))
            let r = radius * ctx.scale
            if fill != .none {
                let fc = ctx.color(metalExtraColor(fill, theme: ctx.theme))
                if innerRadius > 1 {
                    ctx.solid.fillDonut(cx: c.x, cy: c.y, outerR: r,
                        innerR: innerRadius * ctx.scale,
                        start: start, end: end, color: fc)
                } else {
                    ctx.solid.fillWedge(cx: c.x, cy: c.y, radius: r,
                        start: start, end: end, color: fc)
                }
            }
            if stroke != .none {
                // Stroke the wedge outline: outer arc + spokes (+ inner arc).
                let sc = ctx.color(metalExtraColor(stroke, theme: ctx.theme))
                var sweep = end - start
                while sweep < 0 { sweep += 2 * .pi }
                while sweep >= 2 * .pi { sweep -= 2 * .pi }
                let steps = max(8, Int(ceil(sweep / (2 * .pi) * 64)))
                var outline: [CGPoint] = []
                for i in 0...steps {
                    let a = start + sweep * Double(i) / Double(steps)
                    outline.append(CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
                }
                if innerRadius > 1 {
                    let ir = innerRadius * ctx.scale
                    for i in stride(from: steps, through: 0, by: -1) {
                        let a = start + sweep * Double(i) / Double(steps)
                        outline.append(CGPoint(x: c.x + ir * cos(a), y: c.y + ir * sin(a)))
                    }
                } else {
                    outline.append(CGPoint(x: c.x, y: c.y))
                }
                ctx.solid.strokePolyline(outline + [outline[0]], width: 1 * ctx.scale,
                    closed: false, color: sc)
            }

        case let .text(text, x, y, size, fill, anchor, weight):
            let font = metalExtraFont(size: size, weight: weight)
            let alignment: TextAlignment
            switch anchor {
            case .start: alignment = .left
            case .middle: alignment = .center
            case .end: alignment = .right
            }
            // NOTE: content coords — emitTextAt scales internally. Passing
            // ctx.P here double-scales text off the diagram at scale != 1.
            try ctx.emitTextAt(text, point: CGPoint(x: x, y: y),
                color: metalExtraColor(fill, theme: ctx.theme),
                font: font, alignment: alignment)
        }
    }
}
