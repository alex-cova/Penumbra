import Foundation

/// The shared parse memo's counters for the release harness: how often a request found its tree, how many parses
/// it made, how many of those were of text it had just pushed out, and how much it holds.
@_spi(Benchmarks)
public enum JavaParseMemoStatistics {
    public struct Snapshot: Sendable {
        public let hits: Int, parses: Int, evictions: Int, avoidableParses: Int
        public let parseSeconds: Double, avoidableSeconds: Double
        public let entries: Int, bytes: Int, peakBytes: Int, distinctTexts: Int
        public var hitRate: Double { hits + parses == 0 ? 0 : Double(hits) / Double(hits + parses) }
    }

    public static func snapshot() -> Snapshot {
        let value = JavaParseMemo.shared.statistics
        return Snapshot(
            hits: value.hits, parses: value.parses, evictions: value.evictions, avoidableParses: value.avoidableParses,
            parseSeconds: value.parseSeconds, avoidableSeconds: value.avoidableSeconds,
            entries: value.entries, bytes: value.bytes, peakBytes: value.peakBytes, distinctTexts: value.distinctTexts
        )
    }

    public static func reset() { JavaParseMemo.shared.resetStatistics() }
}
