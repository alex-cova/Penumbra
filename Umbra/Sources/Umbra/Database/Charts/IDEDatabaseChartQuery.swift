import DatabaseKit
import Foundation

struct IDEDatabaseChartQuery: Sendable {
    let statement: String
    let engine: DatabaseEngine
    let binding: IDEDatabaseConsoleBinding

    func sql(columns: [String], settings: IDEDatabaseChartSettings) throws -> String? {
        guard let dialect = SQLDialect(engine: engine), DatabaseQuery.canPage(statement),
              settings.kind != .histogram, settings.dateUnit == .exact,
              let x = settings.x, columns.indices.contains(x) else { return nil }
        let statements = SQLStatementSplitter.split(statement, dialect: dialect)
        guard statements.count == 1, let base = statements.first?.text else { return nil }

        func field(_ index: Int) throws -> String? {
            guard columns.indices.contains(index),
                  columns.filter({ $0.caseInsensitiveCompare(columns[index]) == .orderedSame }).count == 1 else { return nil }
            return try "chart_source." + SQLIdentifiers.quote(columns[index], engine: engine)
        }

        guard let xField = try field(x) else { return nil }
        var dimensions = [xField]
        if let series = settings.series, !settings.kind.isSector {
            guard let group = try field(series) else { return nil }
            if group != xField { dimensions.append(group) }
        }
        let aggregate: String
        if settings.effectiveAggregate == .count {
            aggregate = "COUNT(*)"
        } else {
            guard let y = settings.y, let measure = try field(y) else { return nil }
            switch settings.effectiveAggregate {
            case .none, .count: return nil
            case .distinct: aggregate = "COUNT(DISTINCT \(measure))"
            case .sum: aggregate = "SUM(\(measure))"
            case .mean: aggregate = "AVG(\(measure))"
            case .min: aggregate = "MIN(\(measure))"
            case .max: aggregate = "MAX(\(measure))"
            case .median:
                guard engine == .postgres else { return nil }
                aggregate = "PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY \(measure))"
            }
        }
        let projections = dimensions.enumerated().map { index, value in
            "\(value) AS \(index == 0 ? "chart_x" : "chart_series")"
        }
        return """
        SELECT \((projections + ["\(aggregate) AS chart_value"]).joined(separator: ", "))
        FROM (
        \(base)
        ) AS chart_source
        GROUP BY \(dimensions.joined(separator: ", "))
        """
    }
}
