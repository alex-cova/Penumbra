import Foundation
import CoreGraphics

#if targetEnvironment(macCatalyst)
import UIKit
#elseif canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Font constructors for Metal encoders, mirroring `DiagramRenderer`'s
/// `_monoFont` / `_italicMonoFont` / `_italicSystemFont` exactly (same inputs
/// produce the same fonts, hence the same label cache entries).
func metalMonoFont(size: CGFloat) -> BMFont {
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    return UIFont(name: "Menlo", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    #elseif canImport(AppKit)
    return NSFont(name: "Menlo", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    #endif
}

func metalItalicMonoFont(size: CGFloat) -> BMFont {
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    return UIFont(name: "Menlo-Italic", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    #elseif canImport(AppKit)
    return NSFont(name: "Menlo-Italic", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    #endif
}

func metalItalicSystemFont(size: CGFloat, weight: CGFloat) -> BMFont {
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    let baseFont = BMFont.systemFont(ofSize: size, weight: UIFont.Weight(weight))
    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
        return BMFont(descriptor: descriptor, size: size)
    }
    return baseFont
    #elseif canImport(AppKit)
    let baseFont = BMFont.systemFont(ofSize: size, weight: NSFont.Weight(weight))
    let manager = NSFontManager.shared
    return manager.convert(baseFont, toHaveTrait: .italicFontMask)
    #endif
}

/// Metal encoder for positioned class diagrams: mirrors
/// `DiagramRenderer+Class._drawClass` (relationships, boxes, highlighted
/// members, labels and cardinality).
struct MetalClassEncoder {
    var ctx: MetalEncodeContext

    mutating func encode(positioned: PositionedGraph) throws {
        guard case .classDiagram(let classes, let relationships) = positioned.content else {
            throw MetalDiagramError.encodeFailed("Metal class renderer needs class content")
        }
        guard !classes.isEmpty else { return }
        for rel in relationships {
            try drawRelationship(rel)
        }
        for cls in classes {
            try drawClass(cls)
        }
        for rel in relationships {
            try drawRelationshipLabels(rel)
        }
    }

    // MARK: Relationships

    mutating func drawRelationship(_ rel: PositionedClassRelationship) throws {
        let pts = rel.points.map { ctx.P(CGPoint(x: $0.x, y: $0.y)) }
        guard pts.count >= 2 else { return }
        let s = ctx.scale
        let runs: [[CGPoint]]
        if rel.type == RenderRelType.dependency.rawValue ||
            rel.type == RenderRelType.realization.rawValue {
            runs = MetalTessellator.dashRuns(pts, pattern: [6 * s, 4 * s])
        } else {
            runs = [pts]
        }
        for run in runs {
            ctx.solid.strokePolyline(run, width: ctx.config.strokeWidthConnector * s,
                closed: false, color: ctx.color(ctx.theme.effectiveLine()))
        }
        drawMarker(rel, pts: pts)
    }

    /// Mirrors `_drawClassMarker` (tip-frame geometry rotated onto the endpoint).
    mutating func drawMarker(_ rel: PositionedClassRelationship, pts: [CGPoint]) {
        guard pts.count >= 2 else { return }
        let s = ctx.scale
        let endpoint: CGPoint, prevPoint: CGPoint
        if rel.markerAt == "from" {
            endpoint = pts[0]; prevPoint = pts[1]
        } else {
            endpoint = pts[pts.count - 1]; prevPoint = pts[pts.count - 2]
        }
        let angle = atan2(endpoint.y - prevPoint.y, endpoint.x - prevPoint.x)
        let dx = cos(angle), dy = sin(angle)
        let px = -dy, py = dx
        // Tip-frame local point (in device pixels) rotated onto the endpoint.
        func at(lx: CGFloat, ly: CGFloat) -> CGPoint {
            CGPoint(x: endpoint.x + dx * lx * s + px * ly * s,
                    y: endpoint.y + dy * lx * s + py * ly * s)
        }
        let arrow = ctx.color(ctx.theme.effectiveArrow())
        switch rel.type {
        case RenderRelType.inheritance.rawValue, RenderRelType.realization.rawValue:
            let tri = [at(lx: 0, ly: 0), at(lx: -12, ly: -5), at(lx: -12, ly: 5)]
            ctx.solid.fillSimplePolygon(tri, color: ctx.color(ctx.theme.background))
            ctx.solid.strokePolyline(tri + [tri[0]], width: 1.5 * s, closed: true, color: arrow)
        case RenderRelType.composition.rawValue, RenderRelType.aggregation.rawValue:
            let diamond = [at(lx: 0, ly: 0), at(lx: -6, ly: -5), at(lx: -12, ly: 0), at(lx: -6, ly: 5)]
            if rel.type == RenderRelType.composition.rawValue {
                ctx.solid.fillSimplePolygon(diamond, color: arrow)
                // CG's composition branch sets only the fill color, so the
                // stroke runs with the graphics state's default black 1px pen.
                ctx.solid.strokePolyline(diamond + [diamond[0]], width: 1.0 * s,
                    closed: true, color: SIMD4<Float>(0, 0, 0, 1))
            } else {
                ctx.solid.fillSimplePolygon(diamond, color: ctx.color(ctx.theme.background))
                ctx.solid.strokePolyline(diamond + [diamond[0]], width: 1.5 * s,
                    closed: true, color: arrow)
            }
        default:
            // Open arrow for association/dependency.
            ctx.solid.strokePolyline(
                [at(lx: -8, ly: -3), at(lx: 0, ly: 0), at(lx: -8, ly: 3)],
                width: 1.5 * s, closed: false, color: arrow)
        }
    }

    // MARK: Class boxes

    mutating func drawClass(_ cls: PositionedClassNode) throws {
        let s = ctx.scale
        let border = ctx.color(ctx.theme.effectiveBorder())
        let box = ctx.R(CGRect(x: cls.x, y: cls.y, width: cls.width, height: cls.height))
        ctx.solid.fillRect(box, color: ctx.color(ctx.theme.effectiveSurface()))
        ctx.solid.strokePolyline(ctx.closedRing(box),
            width: ctx.config.strokeWidthOuterBox * s, closed: true, color: border)
        let headerRect = ctx.R(CGRect(x: cls.x, y: cls.y, width: cls.width, height: cls.headerHeight))
        ctx.solid.fillRect(headerRect, color: ctx.color(ctx.theme.subgraphHeaderColor()))
        ctx.solid.strokePolyline(ctx.closedRing(headerRect),
            width: ctx.config.strokeWidthOuterBox * s, closed: true, color: border)
        // Annotation shifts the name down (mirrors CG).
        var nameY = cls.y + cls.headerHeight / 2
        if let annotation = cls.annotation, !annotation.isEmpty {
            try ctx.emitTextAt("<<\(annotation)>>",
                point: CGPoint(x: cls.x + cls.width / 2, y: cls.y + 12),
                color: ctx.theme.effectiveMuted(),
                font: metalItalicSystemFont(size: 10, weight: 0.23),
                alignment: .center)
            nameY = cls.y + cls.headerHeight / 2 + 6
        }
        let nameFont = BMFont.systemFont(ofSize: ctx.config.fontSizeNodeLabel, weight: .bold)
        try ctx.emitTextAt(cls.label,
            point: CGPoint(x: cls.x + cls.width / 2, y: nameY),
            color: ctx.theme.foreground, font: nameFont, alignment: .center)
        // Divider.
        let attrTop = cls.y + cls.headerHeight
        ctx.solid.strokePolyline(
            [ctx.P(CGPoint(x: cls.x, y: attrTop)), ctx.P(CGPoint(x: cls.x + cls.width, y: attrTop))],
            width: ctx.config.strokeWidthInnerBox * s, closed: false, color: border)
        for i in 0..<cls.attributes.count {
            let memberY = attrTop + 4 + CGFloat(i) * ctx.config.classMemberRowHeight
                + ctx.config.classMemberRowHeight / 2
            try drawMember(cls.attributes[i],
                at: CGPoint(x: cls.x + ctx.config.classBoxPadX, y: memberY))
        }
        // Method divider.
        let methodTop = attrTop + cls.attrHeight
        ctx.solid.strokePolyline(
            [ctx.P(CGPoint(x: cls.x, y: methodTop)), ctx.P(CGPoint(x: cls.x + cls.width, y: methodTop))],
            width: ctx.config.strokeWidthInnerBox * s, closed: false, color: border)
        for i in 0..<cls.methods.count {
            let memberY = methodTop + 4 + CGFloat(i) * ctx.config.classMemberRowHeight
                + ctx.config.classMemberRowHeight / 2
            try drawMember(cls.methods[i],
                at: CGPoint(x: cls.x + ctx.config.classBoxPadX, y: memberY))
        }
    }

    /// Mirrors `_drawClassMemberHighlighted` (segmented colors, mono advances).
    /// `point` is in content coords; advances use the same estimator as CG.
    mutating func drawMember(_ member: ClassMember, at point: CGPoint) throws {
        let memberFont = member.isAbstract
            ? metalItalicMonoFont(size: ctx.config.classMemberFontSize)
            : metalMonoFont(size: ctx.config.classMemberFontSize)
        var currentX = point.x
        func advance(_ text: String, config: RenderConfig) {
            // Same estimator the layout used: advances match CG exactly.
            currentX += config.estimateMonoTextWidth(text, fontSize: config.classMemberFontSize)
        }
        if !member.visibility.isEmpty {
            let visText = member.visibility + " "
            try ctx.emitTextAt(visText, point: CGPoint(x: currentX, y: point.y),
                color: ctx.theme.effectiveTextFaint(), font: memberFont, alignment: .left)
            advance(visText, config: ctx.config)
        }
        let displayName = member.isMethod ? "\(member.name)(\(member.params ?? ""))" : member.name
        if !displayName.isEmpty {
            try ctx.emitTextAt(displayName, point: CGPoint(x: currentX, y: point.y),
                color: ctx.theme.effectiveTextSecondary(), font: memberFont, alignment: .left)
        }
        if member.isStatic {
            let nameWidth = ctx.config.estimateMonoTextWidth(
                displayName, fontSize: ctx.config.classMemberFontSize)
            ctx.solid.strokePolyline([
                ctx.P(CGPoint(x: currentX, y: point.y + 6)),
                ctx.P(CGPoint(x: currentX + nameWidth, y: point.y + 6)),
            ], width: 1.0 * ctx.scale, closed: false,
                color: ctx.color(ctx.theme.effectiveTextSecondary()))
        }
        advance(displayName, config: ctx.config)
        if let type = member.type, !type.isEmpty {
            let colonText = ": "
            try ctx.emitTextAt(colonText, point: CGPoint(x: currentX, y: point.y),
                color: ctx.theme.effectiveTextFaint(), font: memberFont, alignment: .left)
            advance(colonText, config: ctx.config)
            try ctx.emitTextAt(type, point: CGPoint(x: currentX, y: point.y),
                color: ctx.theme.effectiveMuted(), font: memberFont, alignment: .left)
        }
    }

    // MARK: Labels and cardinality

    mutating func drawRelationshipLabels(_ rel: PositionedClassRelationship) throws {
        guard rel.label != nil || rel.fromCardinality != nil || rel.toCardinality != nil else { return }
        let pts = rel.points.map { CGPoint(x: $0.x, y: $0.y) }
        guard pts.count >= 2 else { return }
        let labelFont = ctx.config.edgeLabelFont()
        if let label = rel.label, !label.isEmpty {
            let pos: CGPoint
            if let lp = rel.labelPosition {
                pos = CGPoint(x: lp.x, y: lp.y)
            } else {
                let mid = pts[pts.count / 2]
                pos = CGPoint(x: mid.x, y: mid.y)
            }
            try ctx.emitTextAt(label, point: CGPoint(x: pos.x, y: pos.y - 8),
                color: ctx.theme.effectiveMuted(), font: labelFont, alignment: .center)
        }
        if let fromCard = rel.fromCardinality, !fromCard.isEmpty {
            let offset = Self.cardinalityOffset(from: pts[0], to: pts[1])
            try ctx.emitTextAt(fromCard,
                point: CGPoint(x: pts[0].x + offset.x, y: pts[0].y + offset.y),
                color: ctx.theme.effectiveMuted(), font: labelFont, alignment: .center)
        }
        if let toCard = rel.toCardinality, !toCard.isEmpty {
            let offset = Self.cardinalityOffset(from: pts[pts.count - 1], to: pts[pts.count - 2])
            try ctx.emitTextAt(toCard,
                point: CGPoint(x: pts[pts.count - 1].x + offset.x, y: pts[pts.count - 1].y + offset.y),
                color: ctx.theme.effectiveMuted(), font: labelFont, alignment: .center)
        }
    }

    /// Mirrors `_cardinalityOffset` exactly (content-space constants).
    static func cardinalityOffset(from: CGPoint, to: CGPoint) -> CGPoint {
        let dx = to.x - from.x
        let dy = to.y - from.y
        if abs(dx) > abs(dy) {
            return CGPoint(x: dx > 0 ? 14 : -14, y: -10)
        }
        return CGPoint(x: -14, y: dy > 0 ? 14 : -14)
    }
}
