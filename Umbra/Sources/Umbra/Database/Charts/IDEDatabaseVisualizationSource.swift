import DatabaseKit
import Foundation

struct IDEDatabaseVisualizationSource: Identifiable, Sendable {
    let id = UUID()
    let storage: IDEDatabaseResultStorage
    let columns: [String]
    let rowCount: Int
    let complete: Bool

    /// Uses contiguous windows spread through the result. A spill chunk is decoded once per
    /// window, and only the caller's compact projection leaves the store actor.
    func sample<T: Sendable>(
        limit: Int, _ project: @Sendable ([DatabaseValue]) -> T
    ) async throws -> [IDEIndexedSample<T>] {
        guard rowCount > 0, limit > 0 else { return [] }
        let windows = rowCount <= limit ? 1 : min(16, limit)
        var samples: [IDEIndexedSample<T>] = []
        samples.reserveCapacity(min(limit, rowCount))
        for window in 0..<windows {
            try Task.checkCancellation()
            let start = rowCount / windows * window
            let end = window + 1 == windows ? rowCount : rowCount / windows * (window + 1)
            let take = min(end - start, limit / windows + (window < limit % windows ? 1 : 0))
            let lower = windows == 1 ? start : start + (end - start - take) * window / (windows - 1)
            let values = try await storage.store.mapRows(in: lower..<(lower + take), project)
            samples.append(contentsOf: values.enumerated().map { IDEIndexedSample(row: lower + $0.offset, value: $0.element) })
        }
        return samples
    }

    func scope(sampleCount: Int) -> String {
        if sampleCount < rowCount { return "Sample of \(sampleCount.formatted()) of \(rowCount.formatted()) loaded rows" }
        return complete ? "All \(rowCount.formatted()) result rows" : "\(rowCount.formatted()) loaded rows"
    }
}

struct IDEIndexedSample<Value: Sendable>: Sendable {
    let row: Int
    let value: Value
}

extension DatabaseValue {
    /// Charts and maps use floating-point coordinates. The grid's original value stays exact.
    var visualizationNumber: Double? {
        let number: Double?
        switch self {
        case .int(let value): number = Double(value)
        case .uint(let value): number = Double(value)
        case .double(let value): number = value
        case .decimal(let value): number = Double(value)
        default: number = nil
        }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }
}
