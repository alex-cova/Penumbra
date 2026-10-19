import Foundation
import CoreGraphics
import Metal

/// Series color for XY charts, mirroring `_xySeriesColor` (index 0 is the
/// accent; the rest go through `getSeriesColor` like the extras encoder).
func metalXYSeriesColor(_ index: Int, theme: DiagramTheme) -> BMColor {
    if index == 0 { return theme.effectiveAccent() }
    let hex = getSeriesColor(
        index,
        _hex(theme.effectiveAccent()) ?? "#3b82f6",
        _hex(theme.background)
    )
    return BMColor(hex: hex)
}

/// Metal encoder for positioned XY charts: mirrors
/// `DiagramRenderer+XYChart._drawXYChart` (grid dots, bars, spline lines,
/// ticks, titles, legend).
///
/// The CG path draws in a y-up flipped context (`fy` maps stored y-down
/// coords). This encoder works y-down throughout: a stored SVG y-down
/// coordinate maps to device pixel `(x, y) * scale`, and y-up intermediates
/// are converted with `dy(_:)` before tessellation.
///
/// Limitation: rotated axis titles (`rotate: -90` on y titles) are drawn
/// unrotated at their anchor — the label atlas only holds axis-aligned quads.
struct MetalXYEncoder {
    var ctx: MetalEncodeContext
    /// Content height, for y-up → y-down conversion.
    var ch: Double = 0

    mutating func encode(positioned: PositionedGraph) throws {
        guard case .xyChart(let chart) = positioned.content else {
            throw MetalDiagramError.encodeFailed("Metal XY renderer needs XY content")
        }
        guard chart.width > 0, chart.height > 0 else { return }
        ch = chart.height
        drawGridDots(chart)
        drawBars(chart)
        try drawLines(chart)
        try drawTicks(chart)
        try drawTitles(chart)
        try drawLegend(chart)
    }

    /// Stored y-down → device pixels.
    func D(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x * ctx.scale, y: y * ctx.scale)
    }

    /// y-up content → device pixels.
    func U(_ x: Double, _ yUp: Double) -> CGPoint {
        CGPoint(x: x * ctx.scale, y: (ch - yUp) * ctx.scale)
    }

    // MARK: Grid dots

    /// Replicates the CG dot lattice accumulation exactly (same Double order).
    mutating func drawGridDots(_ chart: PositionedXYChart) {
        let s = ctx.scale
        let plotArea = chart.plotArea
        let xTicks = chart.xAxis.ticks.map(\.x)
        let yVals = chart.horizontal
            ? chart.yAxis.ticks.map(\.y)
            : chart.gridLines.map(\.y1)
        let xBase = xTicks.count > 1 ? abs(xTicks[1] - xTicks[0]) : plotArea.width / 6
        let yBase = yVals.count > 1 ? abs(yVals[1] - yVals[0]) : plotArea.height / 6
        let xGap = xBase / Double(max(1, Int((xBase / 20).rounded())))
        let yGap = yBase / Double(max(1, Int((yBase / 20).rounded())))
        let xAnchor = xTicks.first ?? plotArea.x
        let yAnchor = yVals.first ?? plotArea.y
        let xStart = xAnchor - ceil((xAnchor - plotArea.x) / xGap) * xGap
        let yStart = yAnchor - ceil((yAnchor - plotArea.y) / yGap) * yGap
        var dot = ctx.color(ctx.theme.effectiveMuted())
        dot.w *= 0.3
        var dotY = yStart
        while dotY <= plotArea.y + plotArea.height + 0.5 {
            var dotX = xStart
            while dotX <= plotArea.x + plotArea.width + 0.5 {
                // Stored coords are y-down SVG: device = P, like CG's fy + flip.
                let c = D(dotX, dotY)
                let r = 1.5 * s
                ctx.solid.fillEllipse(CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2),
                    color: dot)
                dotX += xGap
            }
            dotY += yGap
        }
    }

    // MARK: Bars

    mutating func drawBars(_ chart: PositionedXYChart) {
        let s = ctx.scale
        let bg = ctx.color(ctx.theme.background)
        for bar in chart.bars {
            let series = ctx.color(metalXYSeriesColor(bar.colorIndex, theme: ctx.theme))
            let fill = Self.mix(bg, series, ratio: 0.25)
            let rect = ctx.R(CGRect(x: bar.x, y: bar.y, width: bar.width, height: bar.height))
            let cr = min(8 * s, rect.width / 2, rect.height / 2)
            ctx.solid.fillRoundedRect(rect, radius: cr, color: fill)
            ctx.solid.strokePolyline(ctx.closedRingOfRounded(rect, radius: cr),
                width: 1.5 * s, closed: true, color: series)
        }
    }

    // MARK: Lines

    mutating func drawLines(_ chart: PositionedXYChart) throws {
        let s = ctx.scale
        let bg = ctx.color(ctx.theme.background)
        for line in chart.lines {
            guard !line.points.isEmpty else { continue }
            let series = ctx.color(metalXYSeriesColor(line.colorIndex, theme: ctx.theme))
            // Natural cubic spline in y-up content coords (mirrors _addCurvePath).
            let spans = Self.splineSpans(line.points.map { ($0.x, ch - $0.y) })
            let flat: [CGPoint] = spans.flatMap { Self.flattenCubic($0, segments: 12) }
                .map { U($0.x, $0.y) }
            guard flat.count >= 2 else { continue }
            // Shadow (offset -2 in y-up, alpha 0.12, width 5).
            var shadow = series
            shadow.w *= 0.12
            let shadowFlat = spans.flatMap { Self.flattenCubic($0, offsetY: -2, segments: 12) }
                .map { U($0.x, $0.y) }
            ctx.solid.strokePolyline(shadowFlat, width: 5 * s, closed: false, color: shadow)
            // Main line (round caps/joins like CG).
            ctx.solid.strokePolyline(flat, width: 2.5 * s, closed: false, color: series)
            // Dots for sparse lines.
            if line.points.count <= 12 {
                for p in line.points {
                    let c = D(p.x, p.y)
                    for (diameter, color) in [(10.0, series), (6.0, bg), (4.0, series)] {
                        let r = diameter / 2 * s
                        ctx.solid.fillEllipse(
                            CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2),
                            color: color)
                    }
                }
            }
        }
    }

    /// Natural-cubic-spline bezier spans for y-up points, mirroring
    /// `_addCurvePath` control-point math exactly (1- and 2-point fast paths
    /// return straight spans).
    static func splineSpans(_ points: [(x: Double, y: Double)])
        -> [(p0: SIMD2<Double>, c1: SIMD2<Double>, c2: SIMD2<Double>, p3: SIMD2<Double>)] {
        guard points.count >= 2 else { return [] }
        if points.count == 2 {
            let a = SIMD2<Double>(points[0].x, points[0].y)
            let b = SIMD2<Double>(points[1].x, points[1].y)
            return [(a, a, b, b)]
        }
        let n = points.count
        var h: [Double] = [], delta: [Double] = []
        for i in 0..<(n - 1) {
            let hi = points[i + 1].x - points[i].x
            h.append(hi)
            delta.append(hi == 0 ? 0 : (points[i + 1].y - points[i].y) / hi)
        }
        var c = [Double](repeating: 0, count: n)
        if n > 2 {
            var cp = [Double](repeating: 0, count: n)
            var dp = [Double](repeating: 0, count: n)
            for i in 1..<(n - 1) {
                let diag = 2 * (h[i - 1] + h[i])
                let rhs = 3 * (delta[i] - delta[i - 1])
                if i == 1 {
                    cp[i] = h[i] / diag
                    dp[i] = rhs / diag
                } else {
                    let w = diag - h[i - 1] * cp[i - 1]
                    cp[i] = h[i] / w
                    dp[i] = (rhs - h[i - 1] * dp[i - 1]) / w
                }
            }
            for i in stride(from: n - 2, through: 1, by: -1) {
                c[i] = dp[i] - cp[i] * c[i + 1]
            }
        }
        var slopes = [Double](repeating: 0, count: n)
        for i in 0..<(n - 1) {
            slopes[i] = delta[i] - h[i] * (2 * c[i] + c[i + 1]) / 3
        }
        slopes[n - 1] = delta[n - 2] + h[n - 2] * c[n - 2] / 3
        var spans: [(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)] = []
        for i in 0..<(n - 1) {
            let seg = h[i] / 3
            let p0 = SIMD2<Double>(points[i].x, points[i].y)
            let p3 = SIMD2<Double>(points[i + 1].x, points[i + 1].y)
            let c1 = SIMD2<Double>(points[i].x + seg, points[i].y + slopes[i] * seg)
            let c2 = SIMD2<Double>(points[i + 1].x - seg, points[i + 1].y - slopes[i + 1] * seg)
            spans.append((p0, c1, c2, p3))
        }
        return spans
    }

    /// Flattens one cubic span (y-up content) to a polyline; CG flattens
    /// beziers at device resolution, 12 subdivisions is visually identical.
    static func flattenCubic(
        _ span: (p0: SIMD2<Double>, c1: SIMD2<Double>, c2: SIMD2<Double>, p3: SIMD2<Double>),
        offsetY: Double = 0,
        segments: Int
    ) -> [CGPoint] {
        (0...max(1, segments)).map { i in
            let t = Double(i) / Double(max(1, segments))
            let mt = 1 - t
            let x = mt * mt * mt * span.p0.x + 3 * mt * mt * t * span.c1.x
                + 3 * mt * t * t * span.c2.x + t * t * t * span.p3.x
            let y = mt * mt * mt * span.p0.y + 3 * mt * mt * t * span.c1.y
                + 3 * mt * t * t * span.c2.y + t * t * t * span.p3.y + offsetY
            return CGPoint(x: x, y: y)
        }
    }

    // MARK: Ticks, titles, legend

    mutating func drawTicks(_ chart: PositionedXYChart) throws {
        let labelFont = BMFont.systemFont(ofSize: 12, weight: .regular)
        for tick in chart.xAxis.ticks + chart.yAxis.ticks {
            let alignment: TextAlignment
            switch tick.textAnchor {
            case "end": alignment = .right
            case "start": alignment = .left
            default: alignment = .center
            }
            try ctx.emitTextAt(tick.label, point: CGPoint(x: tick.labelX, y: tick.labelY),
                color: ctx.theme.effectiveMuted(), font: labelFont, alignment: alignment)
        }
    }

    mutating func drawTitles(_ chart: PositionedXYChart) throws {
        let axisTitleFont = BMFont.systemFont(ofSize: 15, weight: .medium)
        if let t = chart.xAxis.title, t.rotate == nil {
            try ctx.emitTextAt(t.text, point: CGPoint(x: t.x, y: t.y),
                color: ctx.theme.foreground, font: axisTitleFont, alignment: .center)
        } else if let t = chart.xAxis.title {
            // Rotated titles are a known approximation (see y-axis title),
            // excluded from the per-label backstop.
            ctx.recordDebugRects = false
            try ctx.emitTextAt(t.text, point: CGPoint(x: t.x, y: t.y),
                color: ctx.theme.foreground, font: axisTitleFont, alignment: .center)
            ctx.recordDebugRects = true
        }
        if let t = chart.yAxis.title, t.rotate != nil {
            // Rotated titles have no atlas equivalent: draw unrotated at
            // anchor (known approximation, covered by global parity only —
            // no axis-aligned quad can match CG's vertical word).
            ctx.recordDebugRects = false
            try ctx.emitTextAt(t.text, point: CGPoint(x: t.x, y: t.y),
                color: ctx.theme.foreground, font: axisTitleFont, alignment: .center)
            ctx.recordDebugRects = true
        } else if let t = chart.yAxis.title {
            try ctx.emitTextAt(t.text, point: CGPoint(x: t.x, y: t.y),
                color: ctx.theme.foreground, font: axisTitleFont, alignment: .center)
        }
        if let title = chart.title {
            let titleFont = BMFont.systemFont(ofSize: 16, weight: .semibold)
            try ctx.emitTextAt(title.text, point: CGPoint(x: title.x, y: title.y),
                color: ctx.theme.foreground, font: titleFont, alignment: .center)
        }
    }

    mutating func drawLegend(_ chart: PositionedXYChart) throws {
        let s = ctx.scale
        let legendFont = BMFont.systemFont(ofSize: 12, weight: .regular)
        for item in chart.legend {
            let series = ctx.color(metalXYSeriesColor(item.colorIndex, theme: ctx.theme))
            if item.type == .bar {
                let fill = Self.mix(ctx.color(ctx.theme.background), series, ratio: 0.25)
                let swatchRect = ctx.R(CGRect(x: item.x, y: item.y - 5, width: 12, height: 10))
                ctx.solid.fillRoundedRect(swatchRect, radius: 2 * s, color: fill)
                ctx.solid.strokePolyline(ctx.closedRingOfRounded(swatchRect, radius: 2 * s),
                    width: 1.5 * s, closed: true, color: series)
            } else {
                ctx.solid.strokePolyline(
                    [D(item.x, item.y), D(item.x + 12, item.y)],
                    width: 2.5 * s, closed: false, color: series)
            }
            try ctx.emitTextAt(item.label, point: CGPoint(x: item.x + 17, y: item.y),
                color: ctx.theme.effectiveMuted(), font: legendFont, alignment: .left)
        }
    }

    /// Mirrors `_mixCGColors` (bg weighted 1 - ratio, alpha forced to 1).
    static func mix(_ bg: SIMD4<Float>, _ fg: SIMD4<Float>, ratio: Float) -> SIMD4<Float> {
        SIMD4<Float>(
            bg.x * (1 - ratio) + fg.x * ratio,
            bg.y * (1 - ratio) + fg.y * ratio,
            bg.z * (1 - ratio) + fg.z * ratio,
            1)
    }
}
