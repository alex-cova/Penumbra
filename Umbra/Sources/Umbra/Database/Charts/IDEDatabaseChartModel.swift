import DatabaseKit
import Foundation

enum IDEDatabaseChartKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case bar = "Bar", horizontalBar = "Horizontal Bar", stacked = "Stacked Bar"
    case line = "Line", area = "Area", scatter = "Scatter"
    case pie = "Pie", donut = "Donut", histogram = "Histogram", heatmap = "Heatmap"

    var id: Self { self }
    var usesContinuousAxis: Bool { self == .line || self == .area || self == .scatter || self == .histogram }
    var isSector: Bool { self == .pie || self == .donut }
}

enum IDEDatabaseChartAggregate: String, CaseIterable, Codable, Identifiable, Sendable {
    case none = "Individual Rows", count = "Count Rows", distinct = "Count Distinct"
    case sum = "Sum", mean = "Average", min = "Minimum", max = "Maximum", median = "Median"

    var id: Self { self }
}

enum IDEDatabaseChartDateUnit: String, CaseIterable, Codable, Identifiable, Sendable {
    case exact = "Exact", day = "Day", week = "Week", month = "Month", year = "Year"

    var id: Self { self }
}

enum IDEDatabaseChartNumberFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic = "Automatic", fixed = "Two Decimal Places", scientific = "Scientific"

    var id: Self { self }

    func label(_ value: Double) -> String {
        switch self {
        case .automatic: value.formatted(.number.precision(.fractionLength(0...6)))
        case .fixed: value.formatted(.number.precision(.fractionLength(2)))
        case .scientific: value.formatted(.number.notation(.scientific))
        }
    }
}

struct IDEDatabaseChartSettings: Equatable, Codable, Sendable {
    var kind: IDEDatabaseChartKind = .bar
    var x: Int? = nil
    var y: Int? = nil
    var series: Int? = nil
    var aggregate: IDEDatabaseChartAggregate = .count
    var dateUnit: IDEDatabaseChartDateUnit = .exact
    var numberFormat: IDEDatabaseChartNumberFormat = .automatic

    var requiresAggregate: Bool { kind.isSector || kind == .heatmap || kind == .stacked }
    var effectiveAggregate: IDEDatabaseChartAggregate { aggregate == .none && requiresAggregate ? .sum : aggregate }

    static func recommended(for source: IDEDatabaseVisualizationSource) async throws -> Self {
        let samples = try await source.sample(limit: 32) { row in
            row.map { (numeric: $0.visualizationNumber != nil, temporal: isDate($0)) }
        }
        let numeric = source.columns.indices.filter { column in
            samples.contains { $0.value.indices.contains(column) && $0.value[column].numeric }
        }
        let temporal = source.columns.indices.first { column in
            samples.contains { $0.value.indices.contains(column) && $0.value[column].temporal }
        }
        if let measure = numeric.first, let temporal { return Self(kind: .line, x: temporal, y: measure, aggregate: .none) }
        if numeric.count >= 2 { return Self(kind: .scatter, x: numeric[0], y: numeric[1], aggregate: .none) }
        if let measure = numeric.first, let category = source.columns.indices.first(where: { $0 != measure }) {
            return Self(kind: .bar, x: category, y: measure, aggregate: .sum)
        }
        if let measure = numeric.first { return Self(kind: .histogram, x: measure) }
        return Self(x: source.columns.indices.first)
    }

    private static func isDate(_ value: DatabaseValue) -> Bool {
        switch value {
        case .temporal(_, .date), .temporal(_, .timestamp), .temporal(_, .timestampWithZone): true
        default: false
        }
    }
}

struct IDEDatabaseChartData: Sendable {
    enum Axis: Hashable, Sendable {
        case number(Double), date(Date), category(String)

        var label: String {
            switch self {
            case .number(let value): IDEDatabaseChartNumberFormat.automatic.label(value)
            case .date(let value): value.ISO8601Format()
            case .category(let value): value
            }
        }

        var position: Double? {
            switch self {
            case .number(let value): value
            case .date(let value): value.timeIntervalSince1970
            case .category: nil
            }
        }
    }

    struct Point: Identifiable, Sendable {
        let id: Int
        let x: Axis
        let y: Double
        let series: String
        let sourceRow: Int
        let rowCount: Int
    }

    private struct Input: Sendable {
        let x: Coordinate
        let y: Double?
        let yKey: DistinctKey?
        let series: String
    }

    private enum DistinctKey: Hashable, Sendable {
        case number(String), text(String), uuid(String), temporal(String, DatabaseValue.TemporalKind), boolean(Bool)

        init?(_ value: DatabaseValue) {
            switch value {
            case .text(let text) where text.utf8.count <= 256: self = .text(text)
            case .uuid(let text): self = .uuid(text)
            case .temporal(let text, let kind) where text.utf8.count <= 256: self = .temporal(text, kind)
            case .bool(let value): self = .boolean(value)
            case .int(let value): self = .number(String(value))
            case .uint(let value): self = .number(String(value))
            case .decimal(let text) where text.utf8.count <= 256: self = .number(text)
            case .double(let value) where value.isFinite:
                self = .number(Int64(exactly: value).map(String.init) ?? String(value))
            default: return nil
            }
        }
    }

    private enum Coordinate: Sendable {
        case missing, row, axis(Axis)
    }

    private struct Group: Hashable {
        let x: Axis
        let series: String
    }

    static let markLimit = 5_000
    let points: [Point]
    let sampledRows: Int
    let omittedRows: Int
    var reduced = false

    static func load(from source: IDEDatabaseVisualizationSource, settings: IDEDatabaseChartSettings) async throws -> Self {
        let samples = try await source.sample(limit: markLimit) { row in
            let x = settings.x.flatMap { row.indices.contains($0) ? row[$0] : nil }
            let y = settings.y.flatMap { row.indices.contains($0) ? row[$0] : nil }
            let series = settings.series.flatMap { row.indices.contains($0) ? row[$0] : nil }
            return Input(
                x: settings.x == nil ? .row : x.flatMap { axis(for: $0, unit: settings.dateUnit) }.map(Coordinate.axis) ?? .missing,
                y: y?.visualizationNumber,
                yKey: settings.aggregate == .distinct ? y.flatMap(DistinctKey.init) : nil,
                series: series.flatMap(category) ?? "All Rows"
            )
        }
        try Task.checkCancellation()
        if settings.kind == .histogram { return histogram(samples) }

        var groups: [Group: [IDEIndexedSample<Input>]] = [:]
        var points: [Point] = []
        var omitted = 0
        var dateAxis: Bool?
        let aggregate = settings.effectiveAggregate
        for sample in samples {
            let axis: Axis
            switch sample.value.x {
            case .missing: omitted += 1; continue
            case .row: axis = .number(Double(sample.row + 1))
            case .axis(let value): axis = value
            }
            if settings.kind.usesContinuousAxis {
                let isDate: Bool
                switch axis {
                case .category: omitted += 1; continue
                case .date: isDate = true
                case .number: isDate = false
                }
                if let dateAxis, dateAxis != isDate { omitted += 1; continue }
                dateAxis = isDate
            }
            if aggregate == .none {
                guard let y = sample.value.y else { omitted += 1; continue }
                points.append(Point(id: sample.row, x: axis, y: y, series: sample.value.series, sourceRow: sample.row, rowCount: 1))
            } else {
                let accepted = aggregate == .count || (aggregate == .distinct ? sample.value.yKey != nil : sample.value.y != nil)
                guard accepted else { omitted += 1; continue }
                let series = settings.kind.isSector ? "All Rows" : sample.value.series
                groups[Group(x: axis, series: series), default: []].append(sample)
            }
        }
        for (group, rows) in groups {
            guard let first = rows.first,
                  let y = aggregateValue(aggregate, rows: rows), y.isFinite,
                  !settings.kind.isSector || y > 0 else {
                omitted += rows.count
                continue
            }
            points.append(Point(id: first.row, x: group.x, y: y, series: group.series, sourceRow: first.row, rowCount: rows.count))
        }
        points.sort {
            let a = settings.kind.usesContinuousAxis ? $0.x.position ?? 0 : 0
            let b = settings.kind.usesContinuousAxis ? $1.x.position ?? 0 : 0
            return a == b ? $0.sourceRow < $1.sourceRow : a < b
        }
        let display: [Point]
        switch settings.kind {
        case .line, .area:
            display = Dictionary(grouping: points, by: \.series).sorted { $0.key < $1.key }
                .flatMap { downsample($0.value, limit: 1_000) }
        case .scatter: display = scatter(points)
        default: display = points
        }
        return Self(points: display, sampledRows: samples.count, omittedRows: omitted, reduced: display.count < points.count)
    }

    /// Largest-Triangle-Three-Buckets keeps the endpoints and the strongest changes in each bucket.
    private static func downsample(_ points: [Point], limit: Int) -> [Point] {
        guard points.count > limit, let first = points.first, let last = points.last else { return points }
        let xScale = max(1, points.map { abs($0.x.position ?? 0) }.max() ?? 1)
        let yScale = max(1, points.map { abs($0.y) }.max() ?? 1)
        let coordinates = points.map { (x: ($0.x.position ?? 0) / xScale, y: $0.y / yScale) }
        let step = Double(points.count - 2) / Double(limit - 2)
        var kept = [first]
        var previous = 0
        for bucket in 0..<(limit - 2) {
            let start = Int(Double(bucket) * step) + 1
            let end = Int(Double(bucket + 1) * step) + 1
            let nextEnd = min(points.count, max(end + 1, Int(Double(bucket + 2) * step) + 1))
            let next = coordinates[end..<nextEnd]
            let average = next.reduce((x: 0.0, y: 0.0)) { ($0.x + $1.x, $0.y + $1.y) }
            let center = (x: average.x / Double(next.count), y: average.y / Double(next.count))
            let origin = coordinates[previous]
            var best = start
            var bestArea = -1.0
            for index in start..<end {
                let point = coordinates[index]
                let area = abs((point.x - origin.x) * (center.y - origin.y) - (center.x - origin.x) * (point.y - origin.y))
                if area > bestArea { best = index; bestArea = area }
            }
            previous = best
            kept.append(points[best])
        }
        kept.append(last)
        return kept
    }

    private struct ScatterBin: Hashable {
        let x: Int
        let y: Int
        let series: String
    }

    private static func scatter(_ points: [Point]) -> [Point] {
        guard points.count > 1_000 else { return points }
        let xValues = points.map { $0.x.position ?? 0 }
        let yValues = points.map(\.y)
        func bins(_ values: [Double]) -> [Int] {
            let scale = values.map(abs).max() ?? 0
            guard scale > 0 else { return values.map { _ in 0 } }
            let normalized = values.map { $0 / scale }
            guard let min = normalized.min(), let max = normalized.max(), max > min else {
                return values.map { _ in 0 }
            }
            return normalized.map { Swift.min(39, Int(($0 - min) / (max - min) * 40)) }
        }
        let xBins = bins(xValues)
        let yBins = bins(yValues)
        let groups = Dictionary(grouping: points.indices) {
            ScatterBin(x: xBins[$0], y: yBins[$0], series: points[$0].series)
        }
        return groups.values.compactMap { indices in
            guard let first = indices.first else { return nil }
            let weight = indices.reduce(0) { $0 + points[$1].rowCount }
            let centroid = indices.reduce((x: 0.0, y: 0.0)) { sum, index in
                let ratio = Double(points[index].rowCount) / Double(weight)
                return (sum.x + xValues[index] * ratio, sum.y + yValues[index] * ratio)
            }
            let x: Axis
            if case .date = points[first].x { x = .date(Date(timeIntervalSince1970: centroid.x)) }
            else { x = .number(centroid.x) }
            guard centroid.x.isFinite, centroid.y.isFinite else { return points[first] }
            return Point(id: points[first].id, x: x, y: centroid.y, series: points[first].series,
                         sourceRow: points[first].sourceRow, rowCount: weight)
        }.sorted { $0.sourceRow < $1.sourceRow }
    }

    private static func aggregateValue(_ aggregate: IDEDatabaseChartAggregate, rows: [IDEIndexedSample<Input>]) -> Double? {
        switch aggregate {
        case .count: return Double(rows.count)
        case .distinct: return Double(Set(rows.compactMap { $0.value.yKey }).count)
        default: break
        }
        let values = rows.compactMap { $0.value.y }
        switch aggregate {
        case .none: return values.first
        case .sum: return values.reduce(0, +)
        case .mean: return values.isEmpty ? nil : values.reduce(0) { $0 + $1 / Double(values.count) }
        case .min: return values.min()
        case .max: return values.max()
        case .median:
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let mid = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? sorted[mid - 1] / 2 + sorted[mid] / 2 : sorted[mid]
        case .count, .distinct: return nil
        }
    }

    private static func histogram(_ samples: [IDEIndexedSample<Input>]) -> Self {
        let values: [(number: Double, row: Int)] = samples.compactMap {
            switch $0.value.x {
            case .axis(.number(let value)): (value, $0.row)
            case .row: (Double($0.row + 1), $0.row)
            default: nil
            }
        }
        guard let min = values.map(\.number).min(), let max = values.map(\.number).max() else {
            return Self(points: [], sampledRows: samples.count, omittedRows: samples.count)
        }
        let step = (max - min) / 20
        let bins = step > 0 && step.isFinite ? 20 : 1
        let width = bins == 1 ? 0 : step
        var counts = Array(repeating: 0, count: bins)
        var firstRows = Array(repeating: 0, count: bins)
        for value in values {
            let index = width > 0 ? Swift.min(bins - 1, Int((value.number - min) / width)) : 0
            if counts[index] == 0 { firstRows[index] = value.row }
            counts[index] += 1
        }
        let points = counts.indices.map { index in
            Point(id: index, x: .number(min + (Double(index) + 0.5) * width), y: Double(counts[index]),
                  series: "Frequency", sourceRow: firstRows[index], rowCount: counts[index])
        }
        return Self(points: points, sampledRows: samples.count, omittedRows: samples.count - values.count)
    }

    private static func axis(for value: DatabaseValue, unit: IDEDatabaseChartDateUnit) -> Axis? {
        if let number = value.visualizationNumber { return .number(number) }
        if case .temporal(let text, let kind) = value, let date = date(text, kind: kind) {
            guard unit != .exact else { return .date(date) }
            var calendar = Calendar(identifier: .iso8601)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let component: Calendar.Component = switch unit {
            case .exact: .second
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
            return .date(calendar.dateInterval(of: component, for: date)?.start ?? date)
        }
        return category(value).map(Axis.category)
    }

    private static func category(_ value: DatabaseValue) -> String? {
        guard value.presence == .value || value.presence == .empty else { return nil }
        // Long, unsupported and partial values cannot be silently merged into a group.
        switch value {
        case .text(let text), .uuid(let text), .decimal(let text), .temporal(let text, _):
            guard text.utf8.count <= 256 else { return nil }
            return text.isEmpty ? "⟨empty⟩" : text
        case .int, .uint, .double, .bool:
            return value.rawText
        default:
            return nil
        }
    }

    private static func date(_ text: String, kind: DatabaseValue.TemporalKind) -> Date? {
        switch kind {
        case .date: return try? Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash).parse(text)
        case .timestamp, .timestampWithZone:
            var input = text.replacingOccurrences(of: " ", with: "T", options: .literal)
            if kind == .timestamp {
                input += "Z"
            } else if input.count > 13, let suffix = input.suffix(3).first, suffix == "+" || suffix == "-" {
                input += ":00"
            }
            let style = Date.ISO8601FormatStyle()
            return (try? style.parse(input)) ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(input))
        default: return nil
        }
    }
}
