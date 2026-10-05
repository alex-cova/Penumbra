import DiagramKit
import SwiftUI

/// Draws a scene's edges with their UML end markers into a SwiftUI canvas.
enum IDEDiagramEdgeDrawing {
    static func draw(
        _ edges: [SceneEdge],
        kinds: [UUID: IDEDiagramEdgeKind],
        viewport: ViewportState,
        background: Color,
        labelColor: Color,
        in context: inout GraphicsContext
    ) {
        let zoom = viewport.zoom
        let markerSize = 10 * min(1.4, max(0.75, zoom))
        for edge in edges {
            let kind = kinds[edge.id] ?? .association
            let points = edge.route.points.map { viewport.worldToView($0) }
            let geometry = IDEDiagramEdgeMarkers.geometry(kind: kind, route: points, size: markerSize)
            let color = edge.stroke.swiftUIColor
            let width = max(1, edge.lineWidth)

            var line = Path()
            if let first = geometry.line.first {
                line.move(to: first)
                for point in geometry.line.dropFirst() { line.addLine(to: point) }
            }
            context.stroke(
                line,
                with: .color(color),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: edge.isDashed ? [6, 4] : [])
            )
            for shape in geometry.shapes {
                var path = Path()
                if let first = shape.points.first {
                    path.move(to: first)
                    for point in shape.points.dropFirst() { path.addLine(to: point) }
                    if shape.closed { path.closeSubpath() }
                }
                switch shape.fill {
                case .none: break
                case .background: context.fill(path, with: .color(background))
                case .stroke: context.fill(path, with: .color(color))
                }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            if !edge.label.isEmpty, zoom >= 0.5 {
                drawLabel(edge.label, at: viewport.worldToView(edge.labelPoint), color: labelColor, background: background, in: &context)
            }
        }
    }

    private static func drawLabel(_ text: String, at point: CGPoint, color: Color, background: Color, in context: inout GraphicsContext) {
        let resolved = context.resolve(Text(text).font(.system(size: 10)).foregroundStyle(color))
        let size = resolved.measure(in: CGSize(width: 240, height: 40))
        let rect = CGRect(x: point.x - size.width / 2 - 3, y: point.y - size.height / 2 - 1, width: size.width + 6, height: size.height + 2)
        context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(background.opacity(0.9)))
        context.draw(resolved, at: point, anchor: .center)
    }
}
