import Foundation
import CoreGraphics
import Metal

/// Metal encoder for positioned ER diagrams: mirrors
/// `DiagramRenderer+ER._drawEr` (relationship lines, entity boxes with key
/// badges, crow's-foot markers, label pills).
struct MetalEREncoder {
    var ctx: MetalEncodeContext

    mutating func encode(positioned: PositionedGraph) throws {
        guard case .erDiagram(let entities, let relationships) = positioned.content else {
            throw MetalDiagramError.encodeFailed("Metal ER renderer needs ER content")
        }
        guard !entities.isEmpty else { return }
        let s = ctx.scale
        for rel in relationships {
            let pts = rel.points.map { ctx.P(CGPoint(x: $0.x, y: $0.y)) }
            guard pts.count >= 2 else { continue }
            let runs: [[CGPoint]]
            if !rel.identifying {
                runs = MetalTessellator.dashRuns(pts, pattern: [6 * s, 4 * s])
            } else {
                runs = [pts]
            }
            for run in runs {
                ctx.solid.strokePolyline(run, width: ctx.config.strokeWidthConnector * s,
                    closed: false, color: ctx.color(ctx.theme.effectiveLine()))
            }
        }
        for entity in entities {
            try drawEntity(entity)
        }
        for rel in relationships {
            let pts = rel.points.map { ctx.P(CGPoint(x: $0.x, y: $0.y)) }
            guard pts.count >= 2 else { continue }
            drawCrowsFoot(point: pts[0], toward: pts[1], cardinality: rel.cardinality1)
            drawCrowsFoot(point: pts[pts.count - 1], toward: pts[pts.count - 2],
                cardinality: rel.cardinality2)
        }
        for rel in relationships {
            try drawLabel(rel)
        }
    }

    // MARK: Entities

    mutating func drawEntity(_ entity: PositionedErEntity) throws {
        let s = ctx.scale
        let border = ctx.color(ctx.theme.effectiveBorder())
        let box = ctx.R(CGRect(x: entity.x, y: entity.y, width: entity.width, height: entity.height))
        ctx.solid.fillRect(box, color: ctx.color(ctx.theme.effectiveSurface()))
        ctx.solid.strokePolyline(ctx.closedRing(box),
            width: ctx.config.strokeWidthOuterBox * s, closed: true, color: border)
        let headerRect = ctx.R(CGRect(x: entity.x, y: entity.y,
            width: entity.width, height: entity.headerHeight))
        ctx.solid.fillRect(headerRect, color: ctx.color(ctx.theme.subgraphHeaderColor()))
        ctx.solid.strokePolyline(ctx.closedRing(headerRect),
            width: ctx.config.strokeWidthOuterBox * s, closed: true, color: border)
        let nameFont = BMFont.systemFont(ofSize: ctx.config.fontSizeNodeLabel, weight: .bold)
        try ctx.emitTextAt(entity.label,
            point: CGPoint(x: entity.x + entity.width / 2, y: entity.y + entity.headerHeight / 2),
            color: ctx.theme.foreground, font: nameFont, alignment: .center)
        let attrTop = entity.y + entity.headerHeight
        ctx.solid.strokePolyline(
            [ctx.P(CGPoint(x: entity.x, y: attrTop)),
             ctx.P(CGPoint(x: entity.x + entity.width, y: attrTop))],
            width: ctx.config.strokeWidthInnerBox * s, closed: false, color: border)
        let monoFont = metalMonoFont(size: ctx.config.erAttrFontSize)
        if entity.attributes.isEmpty {
            try ctx.emitTextAt("(no attributes)",
                point: CGPoint(x: entity.x + entity.width / 2, y: attrTop + entity.rowHeight / 2),
                color: ctx.theme.effectiveTextFaint(),
                font: metalItalicSystemFont(size: ctx.config.erAttrFontSize, weight: 0.0),
                alignment: .center)
        }
        for i in 0..<entity.attributes.count {
            let attr = entity.attributes[i]
            let rowY = attrTop + CGFloat(i) * entity.rowHeight + entity.rowHeight / 2
            var typeX = entity.x + 8
            if !attr.keys.isEmpty {
                let keyText = attr.keys.joined(separator: ",")
                let keyWidth = ctx.config.estimateTextWidth(keyText, fontSize: 9, fontWeight: 600) + 8
                let badgeRect = ctx.R(CGRect(x: entity.x + 6, y: rowY - 7, width: keyWidth, height: 14))
                ctx.solid.fillRoundedRect(badgeRect, radius: 2 * s,
                    color: ctx.color(ctx.theme.keyBadgeColor()))
                let keyFont = BMFont.systemFont(ofSize: 9, weight: .semibold)
                try ctx.emitTextAt(keyText,
                    point: CGPoint(x: entity.x + 6 + keyWidth / 2, y: rowY),
                    color: ctx.theme.effectiveTextSecondary(), font: keyFont, alignment: .center)
                typeX += ctx.config.estimateTextWidth(keyText, fontSize: 9, fontWeight: 600) + 14
            }
            if !attr.type.isEmpty {
                try ctx.emitTextAt(attr.type, point: CGPoint(x: typeX, y: rowY),
                    color: ctx.theme.effectiveMuted(), font: monoFont, alignment: .left)
            }
            if !attr.name.isEmpty {
                try ctx.emitTextAt(attr.name,
                    point: CGPoint(x: entity.x + entity.width - 8, y: rowY),
                    color: ctx.theme.effectiveTextSecondary(), font: monoFont, alignment: .right)
            }
        }
    }

    // MARK: Crow's feet

    /// Mirrors `_drawCrowsFoot` (unit/perp frame off the endpoint).
    mutating func drawCrowsFoot(point: CGPoint, toward: CGPoint, cardinality: String) {
        let s = ctx.scale
        let sw = (ctx.config.strokeWidthConnector + 0.25) * s
        let dx = point.x - toward.x, dy = point.y - toward.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 0 else { return }
        let ux = dx / len, uy = dy / len
        let px = -uy, py = ux
        let tipX = point.x - ux * 4 * s, tipY = point.y - uy * 4 * s
        let hasOneLine = cardinality == "one" || cardinality == "zero-one"
        let hasCrowsFoot = cardinality == "many" || cardinality == "zero-many"
        let hasCircle = cardinality == "zero-one" || cardinality == "zero-many"
        let color = ctx.color(ctx.theme.effectiveLine())
        if hasOneLine {
            let halfW = 6.0 * s
            ctx.solid.strokePolyline([
                CGPoint(x: tipX + px * halfW, y: tipY + py * halfW),
                CGPoint(x: tipX - px * halfW, y: tipY - py * halfW),
            ], width: sw, closed: false, color: color)
            let line2X = tipX - ux * 4 * s, line2Y = tipY - uy * 4 * s
            ctx.solid.strokePolyline([
                CGPoint(x: line2X + px * halfW, y: line2Y + py * halfW),
                CGPoint(x: line2X - px * halfW, y: line2Y - py * halfW),
            ], width: sw, closed: false, color: color)
        }
        if hasCrowsFoot {
            let fanW = 7.0 * s
            let backX = point.x - ux * 16 * s, backY = point.y - uy * 16 * s
            let back = CGPoint(x: backX, y: backY)
            ctx.solid.strokePolyline([
                CGPoint(x: tipX + px * fanW, y: tipY + py * fanW), back,
            ], width: sw, closed: false, color: color)
            ctx.solid.strokePolyline([
                CGPoint(x: tipX, y: tipY), back,
            ], width: sw, closed: false, color: color)
            ctx.solid.strokePolyline([
                CGPoint(x: tipX - px * fanW, y: tipY - py * fanW), back,
            ], width: sw, closed: false, color: color)
        }
        if hasCircle {
            let circleOffset = (hasCrowsFoot ? 20.0 : 12.0) * s
            let cx = point.x - ux * circleOffset, cy = point.y - uy * circleOffset
            let circleRect = CGRect(x: cx - 4 * s, y: cy - 4 * s, width: 8 * s, height: 8 * s)
            ctx.solid.fillEllipse(circleRect, color: ctx.color(ctx.theme.background))
            ctx.solid.strokeEllipse(circleRect, width: sw, color: color)
        }
    }

    // MARK: Relationship labels

    mutating func drawLabel(_ rel: PositionedErRelationship) throws {
        guard !rel.label.isEmpty else { return }
        let s = ctx.scale
        let pts = rel.points.map { CGPoint(x: $0.x, y: $0.y) }
        let mid = Self.arcLengthMidpoint(pts)
        let textW = ctx.config.estimateTextWidth(rel.label,
            fontSize: ctx.config.fontSizeEdgeLabel, fontWeight: 400) + 8
        let textH = ctx.config.fontSizeEdgeLabel + 6
        let bgRect = ctx.R(CGRect(x: mid.x - textW / 2, y: mid.y - textH / 2, width: textW, height: textH))
        ctx.solid.fillRoundedRect(bgRect, radius: 2 * s,
            color: ctx.color(ctx.theme.background))
        ctx.solid.strokePolyline(ctx.closedRingOfRounded(bgRect, radius: 2 * s),
            width: 0.5 * s, closed: true,
            color: ctx.color(ctx.theme.effectiveInnerStroke()))
        try ctx.emitTextAt(rel.label, point: mid,
            color: ctx.theme.effectiveMuted(),
            font: ctx.config.edgeLabelFont(), alignment: .center)
    }

    /// Mirrors `_arcLengthMidpoint`.
    static func arcLengthMidpoint(_ points: [CGPoint]) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        var totalLen: CGFloat = 0
        for i in 1..<points.count {
            totalLen += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        guard totalLen > 0 else { return points[0] }
        let halfLen = totalLen / 2
        var walked: CGFloat = 0
        for i in 1..<points.count {
            let segLen = hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
            if walked + segLen >= halfLen {
                let t = segLen > 0 ? (halfLen - walked) / segLen : 0
                return CGPoint(x: points[i - 1].x + (points[i].x - points[i - 1].x) * t,
                               y: points[i - 1].y + (points[i].y - points[i - 1].y) * t)
            }
            walked += segLen
        }
        return points.last ?? points[0]
    }
}
