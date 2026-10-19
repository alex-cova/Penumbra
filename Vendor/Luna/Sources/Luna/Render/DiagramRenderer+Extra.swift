import Foundation
import CoreGraphics

#if targetEnvironment(macCatalyst)
import UIKit
#elseif canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension DiagramRenderer {
    func _drawExtra(_ positioned: PositionedGraph, in context: CGContext, bounds: CGRect) {
        guard let scene = positioned.extraScene else { return }
        _withFittedContext(context, bounds: bounds, contentWidth: max(1, scene.width), contentHeight: max(1, scene.height)) { ctx in
            for item in scene.items {
                self._drawExtraItem(item, in: ctx)
            }
        }
    }

    private func _drawExtraItem(_ item: ExtraItem, in ctx: CGContext) {
        switch item {
        case let .rect(x, y, width, height, fill, stroke, corner, dashed):
            let rect = CGRect(x: x, y: y, width: width, height: height)
            let path: CGPath
            if corner > 0 {
                path = CGPath(roundedRect: rect, cornerWidth: min(corner, width / 2), cornerHeight: min(corner, height / 2), transform: nil)
            } else {
                path = CGPath(rect: rect, transform: nil)
            }
            if fill != .none {
                ctx.setFillColor(self._extraCGColor(fill))
                ctx.addPath(path)
                ctx.fillPath()
            }
            if stroke != .none {
                ctx.setStrokeColor(self._extraCGColor(stroke))
                ctx.setLineWidth(1)
                if dashed { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
                ctx.addPath(path)
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }

        case let .ellipse(x, y, width, height, fill, stroke):
            let rect = CGRect(x: x, y: y, width: width, height: height)
            if fill != .none {
                ctx.setFillColor(self._extraCGColor(fill))
                ctx.fillEllipse(in: rect)
            }
            if stroke != .none {
                ctx.setStrokeColor(self._extraCGColor(stroke))
                ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: rect)
            }

        case let .line(x1, y1, x2, y2, stroke, width, dashed):
            ctx.setStrokeColor(self._extraCGColor(stroke))
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            if dashed { ctx.setLineDash(phase: 0, lengths: [5, 4]) }
            ctx.move(to: CGPoint(x: x1, y: y1))
            ctx.addLine(to: CGPoint(x: x2, y: y2))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])

        case let .polyline(points, fill, stroke, width, closed):
            guard let first = points.first else { return }
            ctx.beginPath()
            ctx.move(to: CGPoint(x: first.x, y: first.y))
            for point in points.dropFirst() {
                ctx.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            if closed { ctx.closePath() }
            if fill != .none {
                ctx.saveGState()
                ctx.setFillColor(self._extraCGColor(fill))
                ctx.fillPath()
                ctx.restoreGState()
                ctx.beginPath()
                ctx.move(to: CGPoint(x: first.x, y: first.y))
                for point in points.dropFirst() {
                    ctx.addLine(to: CGPoint(x: point.x, y: point.y))
                }
                if closed { ctx.closePath() }
            }
            if stroke != .none {
                ctx.setStrokeColor(self._extraCGColor(stroke))
                ctx.setLineWidth(width)
                ctx.setLineJoin(.round)
                ctx.strokePath()
            }

        case let .wedge(cx, cy, radius, start, end, fill, stroke, innerRadius):
            let center = CGPoint(x: cx, y: cy)
            ctx.beginPath()
            if innerRadius > 1 {
                ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                ctx.addArc(center: center, radius: innerRadius, startAngle: end, endAngle: start, clockwise: true)
                ctx.closePath()
            } else {
                ctx.move(to: center)
                ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                ctx.closePath()
            }
            if fill != .none {
                ctx.setFillColor(self._extraCGColor(fill))
                ctx.fillPath()
            }
            if stroke != .none {
                ctx.setStrokeColor(self._extraCGColor(stroke))
                ctx.setLineWidth(1)
                ctx.strokePath()
            }

        case let .text(text, x, y, size, fill, anchor, weight):
            let font = self._extraFont(size: size, weight: weight)
            let alignment: TextAlignment
            switch anchor {
            case .start: alignment = .left
            case .middle: alignment = .center
            case .end: alignment = .right
            }
            self.labelRenderer.drawText(
                text,
                at: CGPoint(x: x, y: y),
                context: ctx,
                color: self._extraBMColor(fill),
                font: font,
                alignment: alignment
            )
        }
    }

    private func _extraFont(size: Double, weight: Int) -> BMFont {
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        let uiWeight: UIFont.Weight
        if weight >= 600 { uiWeight = .semibold }
        else if weight >= 500 { uiWeight = .medium }
        else { uiWeight = .regular }
        return UIFont.systemFont(ofSize: size, weight: uiWeight)
        #elseif canImport(AppKit)
        let nsWeight: NSFont.Weight
        if weight >= 600 { nsWeight = .semibold }
        else if weight >= 500 { nsWeight = .medium }
        else { nsWeight = .regular }
        return NSFont.systemFont(ofSize: size, weight: nsWeight)
        #endif
    }

    private func _extraBMColor(_ fill: ExtraFill) -> BMColor {
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
            guard let baseHex = _hex(_extraBMColor(base)),
                  let fgHex = _hex(theme.foreground),
                  let bgHex = _hex(theme.background)
            else { return theme.foreground }
            return BMColor(hex: pickContrastingHex(on: baseHex, fgHex, bgHex))
        }
    }

    private func _extraCGColor(_ fill: ExtraFill) -> CGColor {
        _extraBMColor(fill).cgColor
    }
}

func renderExtraSceneSvg(
    _ scene: ExtraScene,
    _ colors: DiagramColors,
    _ font: String,
    _ transparent: Bool
) -> String {
    let themeColors = original_src_theme.DiagramColors(
        bg: colors.bg, fg: colors.fg, line: colors.line, accent: colors.accent,
        muted: colors.muted, surface: colors.surface, border: colors.border
    )
    var parts: [String] = [
        original_src_theme.svgOpenTag(scene.width, scene.height, themeColors, transparent),
        original_src_theme.buildStyleBlock(font, false)
    ]
    for item in scene.items {
        parts.append(extraItemSvg(item, colors))
    }
    parts.append("</svg>")
    return parts.joined(separator: "\n")
}

private func extraFillCss(_ fill: ExtraFill, _ colors: DiagramColors) -> String {
    switch fill {
    case .none: return "none"
    case .background: return colors.bg
    case .foreground: return colors.fg
    case .muted: return colors.muted ?? colors.fg
    case .accent: return colors.accent ?? colors.fg
    case .surface: return colors.surface ?? colors.bg
    case .border: return colors.border ?? colors.fg
    case .series(let index):
        return getSeriesColor(index, colors.accent ?? CHART_ACCENT_FALLBACK, colors.bg)
    case .contrast(let base):
        return pickContrastingHex(on: extraFillCss(base, colors), colors.fg, colors.bg)
    }
}

private func extraItemSvg(_ item: ExtraItem, _ colors: DiagramColors) -> String {
    switch item {
    case let .rect(x, y, width, height, fill, stroke, corner, dashed):
        let dash = dashed ? " stroke-dasharray=\"4 3\"" : ""
        return "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(width)\" height=\"\(height)\" rx=\"\(corner)\" fill=\"\(extraFillCss(fill, colors))\" stroke=\"\(extraFillCss(stroke, colors))\"\(dash)/>"
    case let .ellipse(x, y, width, height, fill, stroke):
        return "<ellipse cx=\"\(x + width / 2)\" cy=\"\(y + height / 2)\" rx=\"\(width / 2)\" ry=\"\(height / 2)\" fill=\"\(extraFillCss(fill, colors))\" stroke=\"\(extraFillCss(stroke, colors))\"/>"
    case let .line(x1, y1, x2, y2, stroke, width, dashed):
        let dash = dashed ? " stroke-dasharray=\"5 4\"" : ""
        return "<line x1=\"\(x1)\" y1=\"\(y1)\" x2=\"\(x2)\" y2=\"\(y2)\" stroke=\"\(extraFillCss(stroke, colors))\" stroke-width=\"\(width)\"\(dash)/>"
    case let .polyline(points, fill, stroke, width, closed):
        let d = points.map { "\($0.x),\($0.y)" }.joined(separator: " ")
        let tag = closed ? "polygon" : "polyline"
        return "<\(tag) points=\"\(d)\" fill=\"\(extraFillCss(fill, colors))\" stroke=\"\(extraFillCss(stroke, colors))\" stroke-width=\"\(width)\"/>"
    case let .wedge(cx, cy, radius, start, end, fill, stroke, innerRadius):
        let large = (end - start) > Double.pi ? 1 : 0
        func pt(_ angle: Double, _ r: Double) -> (Double, Double) {
            (cx + cos(angle) * r, cy + sin(angle) * r)
        }
        let s = pt(start, radius)
        let e = pt(end, radius)
        if innerRadius > 1 {
            let si = pt(start, innerRadius)
            let ei = pt(end, innerRadius)
            let d = "M \(s.0) \(s.1) A \(radius) \(radius) 0 \(large) 1 \(e.0) \(e.1) L \(ei.0) \(ei.1) A \(innerRadius) \(innerRadius) 0 \(large) 0 \(si.0) \(si.1) Z"
            return "<path d=\"\(d)\" fill=\"\(extraFillCss(fill, colors))\" stroke=\"\(extraFillCss(stroke, colors))\"/>"
        }
        let d = "M \(cx) \(cy) L \(s.0) \(s.1) A \(radius) \(radius) 0 \(large) 1 \(e.0) \(e.1) Z"
        return "<path d=\"\(d)\" fill=\"\(extraFillCss(fill, colors))\" stroke=\"\(extraFillCss(stroke, colors))\"/>"
    case let .text(text, x, y, size, fill, anchor, weight):
        return "<text x=\"\(x)\" y=\"\(y)\" font-size=\"\(size)\" font-weight=\"\(weight)\" text-anchor=\"\(anchor.rawValue)\" fill=\"\(extraFillCss(fill, colors))\" dominant-baseline=\"middle\">\(ExtraText.xmlEscape(text))</text>"
    }
}
