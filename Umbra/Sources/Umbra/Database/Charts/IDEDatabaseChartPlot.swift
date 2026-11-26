import Charts
import SwiftUI

struct IDEDatabaseChartPlot: View {
    let settings: IDEDatabaseChartSettings
    let points: [IDEDatabaseChartData.Point]
    let xTitle: String
    let yTitle: String
    var onHover: ((IDEDatabaseChartData.Point?) -> Void)?
    var onSelect: ((IDEDatabaseChartData.Point) -> Void)?
    @State private var selectedAngle: Double?

    var body: some View {
        if settings.kind.isSector, let onSelect {
            chart.chartAngleSelection(value: $selectedAngle)
                .onChange(of: selectedAngle) { _, angle in
                    guard let angle else { return }
                    var end = 0.0
                    if let point = points.first(where: { end += $0.y; return angle <= end }) {
                        onSelect(point)
                    }
                }
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart(points) { point in marks(point) }
            .chartLegend(settings.series != nil || settings.kind.isSector || settings.kind == .heatmap ? .automatic : .hidden)
            .chartXAxis {
                if settings.kind == .horizontalBar || (settings.kind.usesContinuousAxis && isNumericX) {
                    formattedAxis
                } else if !settings.kind.isSector {
                    AxisMarks(values: .automatic(desiredCount: 8))
                }
            }
            .chartYAxis {
                if settings.kind == .horizontalBar || settings.kind == .heatmap {
                    AxisMarks(values: .automatic(desiredCount: 8))
                } else if !settings.kind.isSector {
                    formattedAxis
                }
            }
            .chartOverlay { proxy in
                if !settings.kind.isSector, onHover != nil || onSelect != nil {
                    GeometryReader { geometry in
                        Rectangle().fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location): onHover?(hit(location, proxy: proxy, geometry: geometry))
                                case .ended: onHover?(nil)
                                }
                            }
                            .gesture(SpatialTapGesture().onEnded { event in
                                if let point = hit(event.location, proxy: proxy, geometry: geometry) { onSelect?(point) }
                            })
                    }
                }
            }
            .accessibilityLabel("\(settings.kind.rawValue) chart")
            .accessibilityValue("\(points.count.formatted()) marks")
    }

    private var isNumericX: Bool {
        if case .number? = points.first?.x { return true }
        return false
    }

    private var formattedAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 8)) { tick in
            AxisGridLine()
            AxisTick()
            if let value = tick.as(Double.self) {
                AxisValueLabel { Text(settings.numberFormat.label(value)) }
            }
        }
    }

    @ChartContentBuilder private func marks(_ point: IDEDatabaseChartData.Point) -> some ChartContent {
        switch settings.kind {
        case .pie, .donut:
            SectorMark(angle: .value(yTitle, point.y), innerRadius: .ratio(settings.kind == .donut ? 0.55 : 0))
                .foregroundStyle(by: .value(xTitle, point.x.label))
        case .horizontalBar:
            BarMark(x: .value(yTitle, point.y), y: .value(xTitle, point.x.label))
                .position(by: .value("Series", point.series))
                .foregroundStyle(by: .value("Series", point.series))
        case .bar:
            BarMark(x: .value(xTitle, point.x.label), y: .value(yTitle, point.y))
                .position(by: .value("Series", point.series))
                .foregroundStyle(by: .value("Series", point.series))
        case .stacked:
            BarMark(x: .value(xTitle, point.x.label), y: .value(yTitle, point.y))
                .foregroundStyle(by: .value("Series", point.series))
        case .heatmap:
            RectangleMark(x: .value(xTitle, point.x.label), y: .value("Group", point.series))
                .foregroundStyle(by: .value(yTitle, point.y))
        case .histogram, .line, .area, .scatter:
            switch point.x {
            case .number(let value): continuous(point, x: .value(xTitle, value))
            case .date(let value): continuous(point, x: .value(xTitle, value))
            case .category: ChartContentBuilder.buildBlock()
            }
        }
    }

    @ChartContentBuilder private func continuous<X: Plottable>(
        _ point: IDEDatabaseChartData.Point, x: PlottableValue<X>
    ) -> some ChartContent {
        switch settings.kind {
        case .line:
            if points.count == 1 {
                PointMark(x: x, y: .value(yTitle, point.y)).foregroundStyle(by: .value("Series", point.series))
            } else {
                LineMark(x: x, y: .value(yTitle, point.y), series: .value("Series", point.series))
                    .foregroundStyle(by: .value("Series", point.series))
            }
        case .area:
            AreaMark(x: x, y: .value(yTitle, point.y))
                .foregroundStyle(by: .value("Series", point.series))
        case .scatter:
            PointMark(x: x, y: .value(yTitle, point.y))
                .foregroundStyle(by: .value("Series", point.series))
        default:
            BarMark(x: x, y: .value(yTitle, point.y)).foregroundStyle(IDEAppearance.ColorToken.accent)
        }
    }

    private func hit(_ location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> IDEDatabaseChartData.Point? {
        guard let anchor = proxy.plotFrame else { return nil }
        let frame = geometry[anchor]
        guard frame.contains(location), let first = points.first else { return nil }
        let x = location.x - frame.minX
        let y = location.y - frame.minY
        switch settings.kind {
        case .horizontalBar:
            guard let label: String = proxy.value(atY: y) else { return nil }
            return points.first { $0.x.label == label }
        case .bar, .stacked, .heatmap:
            guard let label: String = proxy.value(atX: x) else { return nil }
            if settings.kind == .heatmap, let series: String = proxy.value(atY: y) {
                return points.first { $0.x.label == label && $0.series == series }
            }
            return points.first { $0.x.label == label }
        default:
            let candidate: Double?
            if case .date = first.x {
                let value: Date? = proxy.value(atX: x)
                candidate = value?.timeIntervalSince1970
            } else {
                candidate = proxy.value(atX: x)
            }
            guard let candidate else { return nil }
            var nearest: IDEDatabaseChartData.Point?
            var closest = Double.infinity
            for point in points where point.rowCount > 0 {
                let distance: Double
                if settings.kind != .histogram, let px = proxy.position(forX: point.x), let py = proxy.position(forY: point.y) {
                    distance = hypot(px - x, py - y)
                } else if let position = point.x.position {
                    distance = abs(position - candidate)
                } else {
                    continue
                }
                if distance < closest { closest = distance; nearest = point }
            }
            return nearest
        }
    }
}

private extension ChartProxy {
    func position(forX axis: IDEDatabaseChartData.Axis) -> CGFloat? {
        switch axis {
        case .number(let value): position(forX: value)
        case .date(let value): position(forX: value)
        case .category: nil
        }
    }
}
