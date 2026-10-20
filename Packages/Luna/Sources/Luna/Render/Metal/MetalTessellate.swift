import Foundation
import CoreGraphics

/// CPU tessellation for Luna's Metal backend: every shape CG draws is
/// expanded here into triangles with identical geometry (same insets, skews,
/// radii and arrowhead dimensions as `NodeShapeRenderer`/`EdgeRenderer`), so
/// the GPU output matches the CoreGraphics fallback pixel for pixel up to
/// antialiasing. Coordinates are emitted in device pixels.
struct MetalTessellator {
    /// 12 floats per vertex: pos.xy, uv.xy, color.rgba, mode, plus 3 padding
    /// floats. The padding is load-bearing: Metal pads `DiagramVertex` (which
    /// contains a `float4`) to a 48-byte array stride, so the CPU must emit
    /// 48 bytes per vertex too.
    var floats: [Float] = []

    /// Floats per vertex, matching `DiagramVertex`'s 48-byte GPU stride.
    static let floatsPerVertex = 12

    var vertexCount: Int { floats.count / Self.floatsPerVertex }

    mutating func vertex(x: Double, y: Double, color: SIMD4<Float>, uvX: Float = 0, uvY: Float = 0, mode: Float = 0) {
        floats.append(Float(x)); floats.append(Float(y))
        floats.append(uvX); floats.append(uvY)
        floats.append(color.x); floats.append(color.y); floats.append(color.z); floats.append(color.w)
        floats.append(mode)
        floats.append(0); floats.append(0); floats.append(0)
    }

    /// Triangle fan over a convex ring. All Luna node shapes are convex.
    mutating func fillConvexRing(_ ring: [CGPoint], color: SIMD4<Float>) {
        guard ring.count >= 3 else { return }
        let cx = ring.reduce(0) { $0 + $1.x } / CGFloat(ring.count)
        let cy = ring.reduce(0) { $0 + $1.y } / CGFloat(ring.count)
        for i in 0..<ring.count {
            let a = ring[i]
            let b = ring[(i + 1) % ring.count]
            vertex(x: a.x, y: a.y, color: color)
            vertex(x: b.x, y: b.y, color: color)
            vertex(x: cx, y: cy, color: color)
        }
    }

    mutating func fillRect(_ r: CGRect, color: SIMD4<Float>) {
        fillConvexRing([
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
        ], color: color)
    }

    /// Rounded rect outline (convex): corner arcs plus straight runs.
    mutating func roundedRectRing(_ r: CGRect, radius: CGFloat, cornerSegments: Int = 10) -> [CGPoint] {
        let rad = min(radius, r.width / 2, r.height / 2)
        guard rad > 0.01 else {
            return [
                CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
            ]
        }
        var pts: [CGPoint] = []
        let centers = [
            CGPoint(x: r.maxX - rad, y: r.minY + rad),
            CGPoint(x: r.maxX - rad, y: r.maxY - rad),
            CGPoint(x: r.minX + rad, y: r.maxY - rad),
            CGPoint(x: r.minX + rad, y: r.minY + rad),
        ]
        let starts: [CGFloat] = [-.pi / 2, 0, .pi / 2, .pi]
        for c in 0..<4 {
            for i in 0...cornerSegments {
                let a = starts[c] + CGFloat(i) / CGFloat(cornerSegments) * (.pi / 2)
                pts.append(CGPoint(x: centers[c].x + cos(a) * rad, y: centers[c].y + sin(a) * rad))
            }
        }
        return pts
    }

    mutating func fillRoundedRect(_ r: CGRect, radius: CGFloat, color: SIMD4<Float>) {
        fillConvexRing(roundedRectRing(r, radius: radius), color: color)
    }

    mutating func fillEllipse(_ r: CGRect, color: SIMD4<Float>, segments: Int = 64) {
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
        var ring: [CGPoint] = []
        ring.reserveCapacity(segments)
        for i in 0..<segments {
            let a = CGFloat(i) / CGFloat(segments) * 2 * .pi
            ring.append(CGPoint(x: cx + cos(a) * rx, y: cy + sin(a) * ry))
        }
        fillConvexRing(ring, color: color)
    }

    mutating func strokeEllipse(_ r: CGRect, width: CGFloat, color: SIMD4<Float>) {
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
        var ring: [CGPoint] = []
        let segments = 64
        for i in 0...segments {
            let a = CGFloat(i) / CGFloat(segments) * 2 * .pi
            ring.append(CGPoint(x: cx + cos(a) * rx, y: cy + sin(a) * ry))
        }
        strokePolyline(ring, width: width, closed: true, color: color)
    }

    /// Round-join / round-cap stroke, matching CG's `.round` line join and cap
    /// used throughout the CG renderers.
    mutating func strokePolyline(_ points: [CGPoint], width: CGFloat, closed: Bool, color: SIMD4<Float>) {
        guard points.count >= 2 else { return }
        let w = max(0.5, width) / 2
        let segs: [(CGPoint, CGPoint)]
        if closed {
            var s: [(CGPoint, CGPoint)] = []
            for i in 0..<points.count {
                s.append((points[i], points[(i + 1) % points.count]))
            }
            segs = s
        } else {
            var s: [(CGPoint, CGPoint)] = []
            for i in 0..<(points.count - 1) {
                s.append((points[i], points[i + 1]))
            }
            segs = s
        }
        for (a, b) in segs {
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(1e-6, hypot(dx, dy))
            let nx = -dy / len * w, ny = dx / len * w
            fillConvexRing([
                CGPoint(x: a.x + nx, y: a.y + ny), CGPoint(x: b.x + nx, y: b.y + ny),
                CGPoint(x: b.x - nx, y: b.y - ny), CGPoint(x: a.x - nx, y: a.y - ny),
            ], color: color)
        }
        // Round joins at every interior joint.
        let joints = closed ? points : Array(points.dropFirst().dropLast())
        for j in joints {
            fanDisk(center: j, radius: w, color: color)
        }
        if !closed {
            if let first = points.first { fanDisk(center: first, radius: w, color: color) }
            if let last = points.last { fanDisk(center: last, radius: w, color: color) }
        }
    }

    mutating func fanDisk(center: CGPoint, radius: CGFloat, color: SIMD4<Float>, segments: Int = 12) {
        var ring: [CGPoint] = []
        for i in 0...segments {
            let a = CGFloat(i) / CGFloat(segments) * 2 * .pi
            ring.append(CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
        }
        var prev = ring[0]
        for p in ring.dropFirst() {
            vertex(x: center.x, y: center.y, color: color)
            vertex(x: prev.x, y: prev.y, color: color)
            vertex(x: p.x, y: p.y, color: color)
            prev = p
        }
    }

    /// Splits a polyline into solid runs per a CG dash pattern ([on, off, ...]).
    /// Interior vertices inside an on-interval are preserved so corners stay sharp.
    static func dashRuns(_ points: [CGPoint], pattern: [CGFloat]) -> [[CGPoint]] {
        guard !pattern.isEmpty, points.count >= 2 else { return [points] }
        let cycle = pattern.reduce(0, +)
        guard cycle > 0 else { return [points] }
        var cum: [CGFloat] = [0]
        for i in 0..<(points.count - 1) {
            cum.append(cum.last! + hypot(points[i + 1].x - points[i].x, points[i + 1].y - points[i].y))
        }
        let total = cum.last!
        guard total > 0 else { return [] }
        func point(at d: CGFloat) -> CGPoint {
            let dd = min(max(d, 0), total)
            var lo = 0, hi = cum.count - 1
            while lo + 1 < hi {
                let m = (lo + hi) / 2
                if cum[m] <= dd { lo = m } else { hi = m }
            }
            let seg = min(lo, points.count - 2)
            let len = cum[seg + 1] - cum[seg]
            guard len > 1e-9 else { return points[seg] }
            let t = (dd - cum[seg]) / len
            return CGPoint(
                x: points[seg].x + (points[seg + 1].x - points[seg].x) * t,
                y: points[seg].y + (points[seg + 1].y - points[seg].y) * t
            )
        }
        var runs: [[CGPoint]] = []
        var cursor: CGFloat = 0
        var slot = 0
        while cursor < total {
            let end = min(cursor + pattern[slot % pattern.count], total)
            if slot % 2 == 0, end > cursor {
                var run: [CGPoint] = [point(at: cursor)]
                for i in 1..<(cum.count - 1) where cum[i] > cursor && cum[i] < end {
                    run.append(points[i])
                }
                run.append(point(at: end))
                if run.count >= 2 { runs.append(run) }
            }
            cursor = end
            slot += 1
        }
        return runs
    }

    /// Filled arrow triangle at `tip`, pointing along `angle` (radians, y-down
    /// screen space), with the same 8×5 dimensions as `EdgeRenderer`.
    mutating func arrowTriangle(tip: CGPoint, angle: CGFloat, color: SIMD4<Float>, width: CGFloat = 8, height: CGFloat = 5) {
        let dx = cos(angle), dy = sin(angle)
        let px = -dy, py = dx
        let bx = tip.x - dx * width, by = tip.y - dy * width
        fillConvexRing([
            tip,
            CGPoint(x: bx + px * height / 2, y: by + py * height / 2),
            CGPoint(x: bx - px * height / 2, y: by - py * height / 2),
        ], color: color)
    }

    /// Open (two-segment) arrowhead.
    mutating func arrowOpen(tip: CGPoint, angle: CGFloat, color: SIMD4<Float>, lineWidth: CGFloat, width: CGFloat = 8, height: CGFloat = 5) {
        let dx = cos(angle), dy = sin(angle)
        let px = -dy, py = dx
        let bx = tip.x - dx * width, by = tip.y - dy * width
        strokePolyline([tip, CGPoint(x: bx + px * height / 2, y: by + py * height / 2)], width: lineWidth, closed: false, color: color)
        strokePolyline([tip, CGPoint(x: bx - px * height / 2, y: by - py * height / 2)], width: lineWidth, closed: false, color: color)
    }

    /// Circle marker centered just behind the tip (mirrors `EdgeRenderer` `.circle`).
    mutating func circleMarker(tip: CGPoint, angle: CGFloat, color: SIMD4<Float>, lineWidth: CGFloat, height: CGFloat = 5) {
        let circleSize = height * 0.8
        let dx = cos(angle), dy = sin(angle)
        let c = CGPoint(x: tip.x - dx * (circleSize + lineWidth), y: tip.y - dy * (circleSize + lineWidth))
        fillEllipse(CGRect(x: c.x - circleSize / 2, y: c.y - circleSize / 2, width: circleSize, height: circleSize), color: color)
    }

    /// Cross marker (mirrors `EdgeRenderer` `.cross`).
    mutating func crossMarker(tip: CGPoint, angle: CGFloat, color: SIMD4<Float>, lineWidth: CGFloat, height: CGFloat = 5) {
        let crossSize = height * 0.4
        let dx = cos(angle), dy = sin(angle)
        let px = -dy, py = dx
        let bx = tip.x - dx * lineWidth, by = tip.y - dy * lineWidth
        let ax = tip.x - dx * (crossSize * 2 + lineWidth), ay = tip.y - dy * (crossSize * 2 + lineWidth)
        strokePolyline([
            CGPoint(x: ax + px * crossSize, y: ay + py * crossSize),
            CGPoint(x: bx - px * crossSize, y: by - py * crossSize),
        ], width: lineWidth, closed: false, color: color)
        strokePolyline([
            CGPoint(x: ax - px * crossSize, y: ay - py * crossSize),
            CGPoint(x: bx + px * crossSize, y: by + py * crossSize),
        ], width: lineWidth, closed: false, color: color)
    }

    /// Fills a simple polygon (convex or concave) via ear clipping, matching
    /// CG's nonzero-winding fill for the diagram shapes in use. Falls back to
    /// a centroid fan when no ear is found (degenerate input).
    mutating func fillSimplePolygon(_ points: [CGPoint], color: SIMD4<Float>) {
        let ring = Self.deduplicated(points)
        guard ring.count >= 3 else { return }
        var remaining = ring
        // Normalize to counterclockwise for stable ear tests.
        if Self.signedArea(remaining) < 0 { remaining.reverse() }
        var guardCount = remaining.count * remaining.count + 8
        while remaining.count > 3 && guardCount > 0 {
            guardCount -= 1
            var clipped = false
            for i in 0..<remaining.count {
                let a = remaining[(i + remaining.count - 1) % remaining.count]
                let b = remaining[i]
                let c = remaining[(i + 1) % remaining.count]
                guard Self.isConvex(a: a, b: b, c: c) else { continue }
                var contains = false
                for j in 0..<remaining.count where j != (i + remaining.count - 1) % remaining.count && j != i && j != (i + 1) % remaining.count {
                    if Self.pointInTriangle(remaining[j], a: a, b: b, c: c) {
                        contains = true
                        break
                    }
                }
                if contains { continue }
                vertex(x: a.x, y: a.y, color: color)
                vertex(x: b.x, y: b.y, color: color)
                vertex(x: c.x, y: c.y, color: color)
                remaining.remove(at: i)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if remaining.count == 3 {
            for p in remaining { vertex(x: p.x, y: p.y, color: color) }
        } else if remaining.count > 3 {
            fillConvexRing(remaining, color: color)
        }
    }

    private static func deduplicated(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in points {
            if let last = out.last, hypot(p.x - last.x, p.y - last.y) < 1e-9 { continue }
            out.append(p)
        }
        if out.count > 1, let first = out.first, let last = out.last,
           hypot(first.x - last.x, first.y - last.y) < 1e-9 {
            out.removeLast()
        }
        return out
    }

    private static func signedArea(_ ring: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    private static func isConvex(a: CGPoint, b: CGPoint, c: CGPoint) -> Bool {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) > 1e-9
    }

    private static func pointInTriangle(_ p: CGPoint, a: CGPoint, b: CGPoint, c: CGPoint) -> Bool {
        let d1 = (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)
        let d2 = (p.x - c.x) * (b.y - c.y) - (b.x - c.x) * (p.y - c.y)
        let d3 = (p.x - a.x) * (c.y - a.y) - (c.x - a.x) * (p.y - a.y)
        let hasNeg = d1 < -1e-9 || d2 < -1e-9 || d3 < -1e-9
        let hasPos = d1 > 1e-9 || d2 > 1e-9 || d3 > 1e-9
        return !(hasNeg && hasPos)
    }

    /// Filled annular sector (donut slice): quad strip between outer and
    /// inner arcs, matching CG's even-odd ring path.
    mutating func fillDonut(cx: Double, cy: Double, outerR: Double, innerR: Double,
        start: Double, end: Double, color: SIMD4<Float>) {
        var sweep = end - start
        while sweep < 0 { sweep += 2 * .pi }
        while sweep >= 2 * .pi { sweep -= 2 * .pi }
        let steps = max(8, Int(ceil(sweep / (2 * .pi) * 64)))
        var outer: [CGPoint] = [], inner: [CGPoint] = []
        for i in 0...steps {
            let a = start + sweep * Double(i) / Double(steps)
            outer.append(CGPoint(x: cx + outerR * cos(a), y: cy + outerR * sin(a)))
            inner.append(CGPoint(x: cx + innerR * cos(a), y: cy + innerR * sin(a)))
        }
        for i in 0..<steps {
            fillConvexRing([outer[i], outer[i + 1], inner[i + 1], inner[i]], color: color)
        }
    }

    /// Filled circular sector (pie slice): fan over the arc.
    mutating func fillWedge(cx: Double, cy: Double, radius: Double,
        start: Double, end: Double, color: SIMD4<Float>) {
        var sweep = end - start
        while sweep < 0 { sweep += 2 * .pi }
        while sweep >= 2 * .pi { sweep -= 2 * .pi }
        let steps = max(8, Int(ceil(sweep / (2 * .pi) * 64)))
        let center = CGPoint(x: cx, y: cy)
        var prev = CGPoint(x: cx + radius * cos(start), y: cy + radius * sin(start))
        for i in 1...steps {
            let a = start + sweep * Double(i) / Double(steps)
            let p = CGPoint(x: cx + radius * cos(a), y: cy + radius * sin(a))
            vertex(x: center.x, y: center.y, color: color)
            vertex(x: prev.x, y: prev.y, color: color)
            vertex(x: p.x, y: p.y, color: color)
            prev = p
        }
    }

    /// Diamond marker (mirrors `EdgeRenderer` `.diamond`).
    mutating func diamondMarker(tip: CGPoint, angle: CGFloat, color: SIMD4<Float>, width: CGFloat = 8, height: CGFloat = 5) {
        let dw = width * 1.2
        let dx = cos(angle), dy = sin(angle)
        let px = -dy, py = dx
        fillConvexRing([
            tip,
            CGPoint(x: tip.x - dx * dw / 2 + px * height / 2, y: tip.y - dy * dw / 2 + py * height / 2),
            CGPoint(x: tip.x - dx * dw, y: tip.y - dy * dw),
            CGPoint(x: tip.x - dx * dw / 2 - px * height / 2, y: tip.y - dy * dw / 2 - py * height / 2),
        ], color: color)
    }
}
