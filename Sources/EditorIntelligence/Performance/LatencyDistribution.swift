import Foundation

/// Median, p95, p99, and worst case of a latency sample, in seconds.
///
/// Nearest-rank percentile: the rank is `ceil(p * count)`, clamped to the sample list.
/// An empty list is a zero distribution so callers can print a numeric row either way.
public struct LatencyDistribution: Equatable, Sendable {
    public var count: Int
    public var median: Double
    public var p95: Double
    public var p99: Double
    public var worst: Double

    public init(count: Int, median: Double, p95: Double, p99: Double, worst: Double) {
        self.count = count
        self.median = median
        self.p95 = p95
        self.p99 = p99
        self.worst = worst
    }
}

/// Pure reducer from raw seconds to a ``LatencyDistribution``. No file I/O and no AppKit.
public enum LatencyDistributionReducer {
    public static func reduce(_ samples: [Double]) -> LatencyDistribution {
        let finite = samples.filter(\.isFinite)
        guard !finite.isEmpty else {
            return LatencyDistribution(count: 0, median: 0, p95: 0, p99: 0, worst: 0)
        }
        return LatencyDistribution(
            count: finite.count,
            median: percentile(finite, 0.50),
            p95: percentile(finite, 0.95),
            p99: percentile(finite, 0.99),
            worst: finite.max() ?? 0
        )
    }

    /// `p` is in (0, 1].
    public static func percentile(_ samples: [Double], _ p: Double) -> Double {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        let index = min(sorted.count, max(1, rank)) - 1
        return sorted[index]
    }
}

/// Gross-freeze check used by the release harness. A single-character mutation or visible
/// update at or above one second is a failed interactive path, independent of the tighter budgets.
public enum EditorPerformanceGuard {
    public static let grossFreezeSeconds: Double = 1

    public static func isGrossFreeze(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds >= grossFreezeSeconds
    }

    /// Stages whose worst sample is a gross freeze. `stages` maps a stable name to its worst seconds.
    public static func grossFreezes(_ worstByStage: [String: Double]) -> [String] {
        worstByStage.compactMap { name, worst in
            isGrossFreeze(worst) ? name : nil
        }.sorted()
    }
}
