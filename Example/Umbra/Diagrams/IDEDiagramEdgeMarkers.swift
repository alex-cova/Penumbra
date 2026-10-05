import CoreGraphics
import Foundation

/// One closed or open outline drawn at an end of an edge.
nonisolated struct IDEDiagramMarkerShape: Equatable {
    enum Fill: Equatable {
        case none
        /// The canvas color, so the line behind a hollow marker does not show through.
        case background
        case stroke
    }

    var points: [CGPoint]
    var closed: Bool
    var fill: Fill
}

nonisolated struct IDEDiagramEdgeGeometry: Equatable {
    /// The polyline to stroke, shortened where a closed marker sits so the line meets its base.
    var line: [CGPoint]
    var shapes: [IDEDiagramMarkerShape]
}

/// UML end markers for an edge, computed in the route's own coordinate space so the canvas, the exports and
/// the tests all use the same geometry.
nonisolated enum IDEDiagramEdgeMarkers {
    static func geometry(kind: IDEDiagramEdgeKind, route: [CGPoint], size: CGFloat) -> IDEDiagramEdgeGeometry {
        guard route.count >= 2, size > 0 else { return IDEDiagramEdgeGeometry(line: route, shapes: []) }
        var line = route
        var shapes: [IDEDiagramMarkerShape] = []

        switch kind {
        case .inheritance, .realization:
            if let marker = trianglePlacement(&line, length: size * 1.3, width: size) {
                shapes.append(IDEDiagramMarkerShape(points: marker, closed: true, fill: .background))
            }
        case .aggregation:
            if let marker = diamondPlacement(&line, length: size * 1.7, width: size * 0.9) {
                shapes.append(IDEDiagramMarkerShape(points: marker, closed: true, fill: .background))
            }
        case .association, .dependency:
            if let arrow = openArrow(line, length: size * 1.2, width: size * 0.8) {
                shapes.append(IDEDiagramMarkerShape(points: arrow, closed: false, fill: .none))
            }
        case .projectDependency, .libraryDependency, .replaced:
            if let marker = trianglePlacement(&line, length: size, width: size * 0.8) {
                shapes.append(IDEDiagramMarkerShape(points: marker, closed: true, fill: .stroke))
            }
        }
        return IDEDiagramEdgeGeometry(line: line, shapes: shapes)
    }

    /// Triangle whose tip is the route's last point; the route is pulled back to the triangle's base.
    private static func trianglePlacement(_ line: inout [CGPoint], length: CGFloat, width: CGFloat) -> [CGPoint]? {
        guard let frame = endFrame(line, length: length) else { return nil }
        line[line.count - 1] = frame.base
        return [frame.tip, frame.base + frame.normal * (width / 2), frame.base - frame.normal * (width / 2)]
    }

    /// Diamond whose tip is the route's first point; the route starts at the diamond's far corner.
    private static func diamondPlacement(_ line: inout [CGPoint], length: CGFloat, width: CGFloat) -> [CGPoint]? {
        var reversed = Array(line.reversed())
        guard let frame = endFrame(reversed, length: length) else { return nil }
        let middle = frame.tip + (frame.base - frame.tip) * 0.5
        reversed[reversed.count - 1] = frame.base
        line = Array(reversed.reversed())
        return [frame.tip, middle + frame.normal * (width / 2), frame.base, middle - frame.normal * (width / 2)]
    }

    private static func openArrow(_ line: [CGPoint], length: CGFloat, width: CGFloat) -> [CGPoint]? {
        guard let frame = endFrame(line, length: length) else { return nil }
        return [frame.base + frame.normal * (width / 2), frame.tip, frame.base - frame.normal * (width / 2)]
    }

    private struct EndFrame {
        var tip: CGPoint
        var base: CGPoint
        var normal: CGVector
    }

    /// The tip at the polyline's end and the point `length` back along its last segment (shorter when that
    /// segment is shorter), with the unit normal across it.
    private static func endFrame(_ line: [CGPoint], length: CGFloat) -> EndFrame? {
        guard line.count >= 2 else { return nil }
        let tip = line[line.count - 1]
        let previous = line[line.count - 2]
        let dx = tip.x - previous.x
        let dy = tip.y - previous.y
        let segment = hypot(dx, dy)
        guard segment > 0.001 else { return nil }
        let direction = CGVector(dx: dx / segment, dy: dy / segment)
        let back = min(length, segment * 0.9)
        let base = CGPoint(x: tip.x - direction.dx * back, y: tip.y - direction.dy * back)
        return EndFrame(tip: tip, base: base, normal: CGVector(dx: -direction.dy, dy: direction.dx))
    }
}

private func + (point: CGPoint, vector: CGVector) -> CGPoint {
    CGPoint(x: point.x + vector.dx, y: point.y + vector.dy)
}

private func - (point: CGPoint, vector: CGVector) -> CGPoint {
    CGPoint(x: point.x - vector.dx, y: point.y - vector.dy)
}

private func * (vector: CGVector, scalar: CGFloat) -> CGVector {
    CGVector(dx: vector.dx * scalar, dy: vector.dy * scalar)
}

private func - (lhs: CGPoint, rhs: CGPoint) -> CGVector {
    CGVector(dx: lhs.x - rhs.x, dy: lhs.y - rhs.y)
}
