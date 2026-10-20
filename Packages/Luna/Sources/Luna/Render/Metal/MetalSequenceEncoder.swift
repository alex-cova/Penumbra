import Foundation
import CoreGraphics
import Metal

/// Metal encoder for positioned sequence diagrams: mirrors
/// `DiagramRenderer+Sequence._drawSequence` section for section, in order
/// (blocks, lifelines, activations, messages, notes, actors on top).
struct MetalSequenceEncoder {
    var ctx: MetalEncodeContext

    mutating func encode(positioned: PositionedGraph) throws {
        guard case .sequenceDiagram(
            let actors, let messages, let blocks,
            let lifelines, let activations, let notes
        ) = positioned.content
        else {
            throw MetalDiagramError.encodeFailed("Metal sequence renderer needs sequence content")
        }
        guard !actors.isEmpty else { return }
        try drawBlocks(blocks)
        drawLifelines(lifelines, actors: actors, messages: messages)
        drawActivations(activations)
        try drawMessages(messages)
        try drawNotes(notes)
        try drawActors(actors)
    }

    // MARK: Blocks (loop/alt/opt/par/critical)

    mutating func drawBlocks(_ blocks: [PositionedSequenceBlock]) throws {
        let s = ctx.scale
        for block in blocks {
            let rect = ctx.R(CGRect(x: block.x, y: block.y, width: block.width, height: block.height))
            let border = ctx.color(ctx.theme.effectiveBorder())
            ctx.solid.strokePolyline(ctx.closedRing(rect),
                width: ctx.config.strokeWidthOuterBox * s, closed: true, color: border)
            // Tab label.
            let labelText = "\(block.type)\(block.label.isEmpty ? "" : " [\(block.label)]")"
            let tabWidth = ctx.config.estimateTextWidth(
                labelText, fontSize: ctx.config.fontSizeEdgeLabel,
                fontWeight: ctx.config.fontWeightGroupHeader) + 16
            let tabRect = ctx.R(CGRect(x: block.x, y: block.y,
                width: tabWidth, height: ctx.config.sequenceTabHeight))
            ctx.solid.fillRect(tabRect, color: ctx.color(ctx.theme.subgraphHeaderColor()))
            ctx.solid.strokePolyline(ctx.closedRing(tabRect),
                width: ctx.config.strokeWidthOuterBox * s, closed: true, color: border)
            try ctx.emitTextAt(labelText,
                point: CGPoint(x: block.x + 6, y: block.y + ctx.config.sequenceTabHeight / 2),
                color: ctx.theme.effectiveTextSecondary(),
                font: ctx.config.groupHeaderFont(), alignment: .left)
            // Dividers.
            for divider in block.dividers {
                let pts = [ctx.P(CGPoint(x: block.x, y: divider.y)),
                           ctx.P(CGPoint(x: block.x + block.width, y: divider.y))]
                for run in MetalTessellator.dashRuns(pts, pattern: [6 * s, 4 * s]) {
                    ctx.solid.strokePolyline(run, width: 0.75 * s, closed: false,
                        color: ctx.color(ctx.theme.effectiveLine()))
                }
                if !divider.label.isEmpty {
                    try ctx.emitTextAt("[\(divider.label)]",
                        point: CGPoint(x: block.x + 8, y: divider.y + 14),
                        color: ctx.theme.effectiveMuted(),
                        font: ctx.config.edgeLabelFont(), alignment: .left)
                }
            }
        }
    }

    // MARK: Lifelines

    mutating func drawLifelines(
        _ lifelines: [SequenceLifeline],
        actors: [PositionedSequenceActor],
        messages: [PositionedSequenceMessage]
    ) {
        let s = ctx.scale
        let color = ctx.color(ctx.theme.effectiveLine())
        if lifelines.isEmpty {
            // Fallback: compute from actors (mirrors CG).
            let maxY = messages.map(\.y).max() ?? 300
            for actor in actors {
                let pts = [ctx.P(CGPoint(x: actor.x, y: actor.y + actor.height)),
                           ctx.P(CGPoint(x: actor.x, y: maxY + 60))]
                for run in MetalTessellator.dashRuns(pts, pattern: [6 * s, 4 * s]) {
                    ctx.solid.strokePolyline(run, width: 0.75 * s, closed: false, color: color)
                }
            }
        } else {
            for ll in lifelines {
                let pts = [ctx.P(CGPoint(x: ll.x, y: ll.topY)),
                           ctx.P(CGPoint(x: ll.x, y: ll.bottomY))]
                for run in MetalTessellator.dashRuns(pts, pattern: [6 * s, 4 * s]) {
                    ctx.solid.strokePolyline(run, width: 0.75 * s, closed: false, color: color)
                }
            }
        }
    }

    // MARK: Activations

    mutating func drawActivations(_ activations: [SequenceActivation]) {
        let s = ctx.scale
        for act in activations {
            let rect = ctx.R(CGRect(x: act.x - act.width / 2, y: act.topY,
                width: act.width, height: act.bottomY - act.topY))
            ctx.solid.fillRect(rect, color: ctx.color(ctx.theme.effectiveSurface()))
            ctx.solid.strokePolyline(ctx.closedRing(rect),
                width: ctx.config.strokeWidthInnerBox * s, closed: true,
                color: ctx.color(ctx.theme.effectiveBorder()))
        }
    }

    // MARK: Messages

    mutating func drawMessages(_ messages: [PositionedSequenceMessage]) throws {
        let s = ctx.scale
        let lineColor = ctx.color(ctx.theme.effectiveLine())
        let headColor = ctx.color(ctx.theme.effectiveArrow())
        let lineWidth = ctx.config.strokeWidthConnector * s
        for msg in messages {
            if msg.isSelf {
                let loopW = 28.0, loopH = 20.0
                let pts = [
                    CGPoint(x: msg.x1, y: msg.y),
                    CGPoint(x: msg.x1 + loopW, y: msg.y),
                    CGPoint(x: msg.x1 + loopW, y: msg.y + loopH),
                    CGPoint(x: msg.x2, y: msg.y + loopH),
                ].map { ctx.P($0) }
                let runs: [[CGPoint]]
                if msg.lineStyle == "dashed" {
                    runs = MetalTessellator.dashRuns(pts, pattern: [6 * s, 4 * s])
                } else {
                    runs = [pts]
                }
                for run in runs {
                    ctx.solid.strokePolyline(run, width: lineWidth, closed: false, color: lineColor)
                }
                drawHead(style: msg.arrowHead, at: pts[3], from: pts[2], color: headColor)
                if !msg.label.isEmpty {
                    try ctx.emitTextAt(msg.label,
                        point: CGPoint(x: msg.x1 + 28 + 4, y: msg.y + 10),
                        color: ctx.theme.effectiveMuted(),
                        font: ctx.config.edgeLabelFont(), alignment: .left)
                }
            } else {
                let p0 = ctx.P(CGPoint(x: msg.x1, y: msg.y))
                let p1 = ctx.P(CGPoint(x: msg.x2, y: msg.y))
                let runs: [[CGPoint]]
                if msg.lineStyle == "dashed" {
                    runs = MetalTessellator.dashRuns([p0, p1], pattern: [6 * s, 4 * s])
                } else {
                    runs = [[p0, p1]]
                }
                for run in runs {
                    ctx.solid.strokePolyline(run, width: lineWidth, closed: false, color: lineColor)
                }
                drawHead(style: msg.arrowHead, at: p1, from: p0, color: headColor)
                if !msg.label.isEmpty {
                    try ctx.emitTextAt(msg.label,
                        point: CGPoint(x: (msg.x1 + msg.x2) / 2, y: msg.y - 8),
                        color: ctx.theme.effectiveMuted(),
                        font: ctx.config.edgeLabelFont(), alignment: .center)
                }
            }
        }
    }

    /// Mirrors `_drawSequenceArrowHead` (tip-frame geometry, arrow color).
    mutating func drawHead(style: String, at tip: CGPoint, from prev: CGPoint, color: SIMD4<Float>) {
        let s = ctx.scale
        let lineWidth = ctx.config.strokeWidthConnector
        let aw = ctx.config.arrowHeadWidth * lineWidth * s
        let ah = ctx.config.arrowHeadHeight * lineWidth * s
        let angle = atan2(tip.y - prev.y, tip.x - prev.x)
        switch style {
        case "open":
            ctx.solid.arrowOpen(tip: tip, angle: angle, color: color,
                lineWidth: lineWidth * s, width: aw, height: ah)
        case "cross":
            let cs = ah * 0.5
            let dx = cos(angle), dy = sin(angle)
            let px = -dy, py = dx
            let base = CGPoint(x: tip.x - dx * 2 * cs, y: tip.y - dy * 2 * cs)
            ctx.solid.strokePolyline([
                CGPoint(x: base.x - px * cs, y: base.y - py * cs),
                CGPoint(x: tip.x + px * cs, y: tip.y + py * cs),
            ], width: lineWidth * s, closed: false, color: color)
            ctx.solid.strokePolyline([
                CGPoint(x: base.x + px * cs, y: base.y + py * cs),
                CGPoint(x: tip.x - px * cs, y: tip.y - py * cs),
            ], width: lineWidth * s, closed: false, color: color)
        default:
            ctx.solid.arrowTriangle(tip: tip, angle: angle, color: color, width: aw, height: ah)
        }
    }

    // MARK: Notes

    mutating func drawNotes(_ notes: [PositionedSequenceNote]) throws {
        let s = ctx.scale
        let foldSize = 6.0 * s
        for note in notes {
            let rect = ctx.R(CGRect(x: note.x, y: note.y, width: note.width, height: note.height))
            ctx.solid.fillSimplePolygon([
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX - foldSize, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY + foldSize),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY),
            ], color: ctx.color(ctx.theme.subgraphHeaderColor()))
            ctx.solid.strokePolyline([
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX - foldSize, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY + foldSize),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.minY),
            ], width: ctx.config.strokeWidthInnerBox * s, closed: true,
                color: ctx.color(ctx.theme.effectiveBorder()))
            ctx.solid.fillConvexRing([
                CGPoint(x: rect.maxX - foldSize, y: rect.minY),
                CGPoint(x: rect.maxX - foldSize, y: rect.minY + foldSize),
                CGPoint(x: rect.maxX, y: rect.minY + foldSize),
            ], color: ctx.color(ctx.theme.effectiveBorder()))
            if !note.text.isEmpty {
                try ctx.emitTextIn(note.text,
                    rect: CGRect(x: note.x + 6, y: note.y + 4,
                        width: note.width - 12, height: note.height - 8),
                    color: ctx.theme.effectiveMuted(),
                    font: ctx.config.edgeLabelFont(), alignment: .center)
            }
        }
    }

    // MARK: Actors

    mutating func drawActors(_ actors: [PositionedSequenceActor]) throws {
        for actor in actors {
            if actor.type == "actor" {
                try drawActorFigure(actor)
            } else {
                let box = ctx.R(CGRect(x: actor.x - actor.width / 2, y: actor.y,
                    width: actor.width, height: actor.height))
                ctx.solid.fillRoundedRect(box, radius: 4 * ctx.scale,
                    color: ctx.color(ctx.theme.effectiveSurface()))
                ctx.solid.strokePolyline(
                    ctx.closedRingOfRounded(box, radius: 4 * ctx.scale),
                    width: 1.0 * ctx.scale, closed: true,
                    color: ctx.color(ctx.theme.effectiveBorder()))
                try ctx.emitTextAt(actor.label,
                    point: CGPoint(x: actor.x, y: actor.y + actor.height / 2),
                    color: ctx.theme.foreground,
                    font: ctx.config.nodeLabelFont(), alignment: .center)
            }
        }
    }

    /// Mirrors `_drawActorFigure` (24x24 viewBox geometry, stroked figure).
    mutating func drawActorFigure(_ actor: PositionedSequenceActor) throws {
        let s = ctx.scale
        let color = ctx.color(ctx.theme.effectiveLine())
        let width = 1.5 * s
        let cx = actor.x
        let boxTop = actor.y
        let figH = actor.height - 16
        let k = figH / 24.0
        let ox = cx - 12 * k, oy = boxTop
        // Outer circle (center 12,12 radius 11) and head (center 12,10 radius 3).
        let outerR = 11.0 * k * s
        let oc = ctx.P(CGPoint(x: ox + 12 * k, y: oy + 12 * k))
        ctx.solid.strokeEllipse(CGRect(x: oc.x - outerR, y: oc.y - outerR,
            width: outerR * 2, height: outerR * 2), width: width, color: color)
        let headR = 3.0 * k * s
        let hc = ctx.P(CGPoint(x: ox + 12 * k, y: oy + 10 * k))
        ctx.solid.strokeEllipse(CGRect(x: hc.x - headR, y: hc.y - headR,
            width: headR * 2, height: headR * 2), width: width, color: color)
        // Shoulders quad curve, flattened (CG flattens beziers for stroke).
        let a = ctx.P(CGPoint(x: ox + 5.6 * k, y: oy + 18.4 * k))
        let c = ctx.P(CGPoint(x: ox + 12 * k, y: oy + 16 * k))
        let b = ctx.P(CGPoint(x: ox + 18.4 * k, y: oy + 18.4 * k))
        ctx.solid.strokePolyline(Self.flattenQuad(a, c, b, segments: 12),
            width: width, closed: false, color: color)
        // Label below the figure.
        try ctx.emitTextAt(actor.label,
            point: CGPoint(x: cx, y: boxTop + figH + 8),
            color: ctx.theme.foreground,
            font: ctx.config.nodeLabelFont(), alignment: .center)
    }

    static func flattenQuad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, segments: Int) -> [CGPoint] {
        (0...max(1, segments)).map { i in
            let t = CGFloat(i) / CGFloat(max(1, segments))
            let mt = 1 - t
            return CGPoint(
                x: mt * mt * a.x + 2 * mt * t * c.x + t * t * b.x,
                y: mt * mt * a.y + 2 * mt * t * c.y + t * t * b.y)
        }
    }
}
