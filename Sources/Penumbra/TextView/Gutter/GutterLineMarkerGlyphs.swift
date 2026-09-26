@preconcurrency import AppKit
import Foundation

/// Draws the ``GutterLineMarkerIcon`` glyphs: a green ring with an "I" for interface
/// relationships, a blue double ring for overrides, and an arrow that points up to what a member
/// implements or down to what implements it. Vector-drawn, so they stay sharp at any scale and
/// follow the current appearance.
public enum GutterLineMarkerGlyphs {
    /// An image of `icon` at `pointSize` that redraws for the appearance it is shown in.
    public static func image(for icon: GutterLineMarkerIcon, pointSize: CGFloat = 12) -> NSImage {
        let image = NSImage(size: CGSize(width: pointSize, height: pointSize), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(icon, in: rect, context: context)
            return true
        }
        image.accessibilityDescription = accessibilityLabel(for: icon)
        return image
    }

    public static func accessibilityLabel(for icon: GutterLineMarkerIcon) -> String {
        switch icon {
        case .implementing: return "Implementing method"
        case .implemented: return "Implemented"
        case .overriding: return "Overriding method"
        case .overridden: return "Overridden"
        case .siblingInherited: return "Sibling inherited method"
        case .recursiveCall: return "Recursive call"
        }
    }

    /// Draws `icon` into `rect` of a flipped (y-down) context.
    static func draw(_ icon: GutterLineMarkerIcon, in rect: CGRect, context: CGContext) {
        let size = min(rect.width, rect.height)
        let box = CGRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size)
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch icon {
        case .implementing:
            drawInterfaceBadge(in: box, context: context)
            drawArrow(in: box, up: true, down: false, color: upArrowColor, context: context)
        case .implemented:
            drawInterfaceBadge(in: box, context: context)
            drawArrow(in: box, up: false, down: true, color: downArrowColor, context: context)
        case .overriding:
            drawOverrideBadge(in: box, context: context)
            drawArrow(in: box, up: true, down: false, color: upArrowColor, context: context)
        case .overridden:
            drawOverrideBadge(in: box, context: context)
            drawArrow(in: box, up: false, down: true, color: downArrowColor, context: context)
        case .siblingInherited:
            drawInterfaceBadge(in: box, context: context)
            drawArrow(in: box, up: true, down: true, color: upArrowColor, context: context)
        case .recursiveCall:
            drawRecursion(in: box, context: context)
        }
    }

    // MARK: - Colors

    private static let interfaceColor = dynamic(light: NSColor(srgbRed: 0.35, green: 0.62, blue: 0.33, alpha: 1),
                                                dark: NSColor(srgbRed: 0.40, green: 0.70, blue: 0.40, alpha: 1))
    private static let overrideColor = dynamic(light: NSColor(srgbRed: 0.25, green: 0.47, blue: 0.87, alpha: 1),
                                               dark: NSColor(srgbRed: 0.36, green: 0.56, blue: 0.96, alpha: 1))
    private static let upArrowColor = dynamic(light: NSColor(srgbRed: 0.85, green: 0.30, blue: 0.30, alpha: 1),
                                              dark: NSColor(srgbRed: 0.93, green: 0.40, blue: 0.40, alpha: 1))
    private static let downArrowColor = dynamic(light: NSColor(white: 0.30, alpha: 1), dark: NSColor(white: 0.85, alpha: 1))
    private static let recursionColor = dynamic(light: NSColor(white: 0.40, alpha: 1), dark: NSColor(white: 0.75, alpha: 1))

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    // MARK: - Parts

    /// The badge's circle: the left three quarters of the box, leaving room for the arrow.
    private static func badgeCircle(in box: CGRect) -> CGRect {
        let diameter = box.width * 0.74
        return CGRect(x: box.minX + box.width * 0.02, y: box.midY - diameter / 2, width: diameter, height: diameter)
    }

    private static func drawInterfaceBadge(in box: CGRect, context: CGContext) {
        let circle = badgeCircle(in: box)
        let lineWidth = max(box.width * 0.09, 1)
        context.setStrokeColor(interfaceColor.cgColor)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: circle.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        // A serif "I".
        let top = circle.minY + circle.height * 0.30
        let bottom = circle.maxY - circle.height * 0.30
        let serif = circle.width * 0.13
        context.setLineWidth(max(box.width * 0.08, 0.9))
        context.move(to: CGPoint(x: circle.midX, y: top))
        context.addLine(to: CGPoint(x: circle.midX, y: bottom))
        context.move(to: CGPoint(x: circle.midX - serif, y: top))
        context.addLine(to: CGPoint(x: circle.midX + serif, y: top))
        context.move(to: CGPoint(x: circle.midX - serif, y: bottom))
        context.addLine(to: CGPoint(x: circle.midX + serif, y: bottom))
        context.strokePath()
    }

    private static func drawOverrideBadge(in box: CGRect, context: CGContext) {
        let circle = badgeCircle(in: box)
        let lineWidth = max(box.width * 0.09, 1)
        context.setStrokeColor(overrideColor.cgColor)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: circle.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        context.strokeEllipse(in: circle.insetBy(dx: circle.width * 0.29, dy: circle.height * 0.29))
    }

    private static func drawArrow(in box: CGRect, up: Bool, down: Bool, color: NSColor, context: CGContext) {
        let x = box.maxX - box.width * 0.12
        let top = box.minY + box.height * 0.12
        let bottom = box.maxY - box.height * 0.08
        let head = box.width * 0.13
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(max(box.width * 0.08, 0.9))
        context.move(to: CGPoint(x: x, y: top))
        context.addLine(to: CGPoint(x: x, y: bottom))
        if up {
            context.move(to: CGPoint(x: x - head, y: top + head))
            context.addLine(to: CGPoint(x: x, y: top))
            context.addLine(to: CGPoint(x: x + head, y: top + head))
        }
        if down {
            context.move(to: CGPoint(x: x - head, y: bottom - head))
            context.addLine(to: CGPoint(x: x, y: bottom))
            context.addLine(to: CGPoint(x: x + head, y: bottom - head))
        }
        context.strokePath()
    }

    /// An almost-closed circular arrow around a green dot.
    private static func drawRecursion(in box: CGRect, context: CGContext) {
        let center = CGPoint(x: box.midX, y: box.midY)
        let radius = box.width * 0.36
        let lineWidth = max(box.width * 0.09, 1)
        context.setStrokeColor(recursionColor.cgColor)
        context.setLineWidth(lineWidth)
        // Flipped context: angles run clockwise from 3 o'clock. The gap sits at the top right.
        let start = -CGFloat.pi * 0.30
        let end = -CGFloat.pi * 0.62
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        context.strokePath()
        // Arrowhead at the end of the arc, pointing along it.
        let tip = CGPoint(x: center.x + radius * cos(end), y: center.y + radius * sin(end))
        // The arc's direction of travel at its end (increasing angle), and its normal.
        let direction = CGPoint(x: -sin(end), y: cos(end))
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let head = box.width * 0.17
        let back = CGPoint(x: tip.x - direction.x * head, y: tip.y - direction.y * head)
        context.move(to: CGPoint(x: back.x + normal.x * head * 0.8, y: back.y + normal.y * head * 0.8))
        context.addLine(to: tip)
        context.addLine(to: CGPoint(x: back.x - normal.x * head * 0.8, y: back.y - normal.y * head * 0.8))
        context.strokePath()
        let dot = box.width * 0.24
        context.setFillColor(interfaceColor.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot))
    }
}
