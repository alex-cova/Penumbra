import Foundation

/// Snapshot of `LineManager`'s handle table, for benchmarks (PerfHarness `enter-session`).
/// Not part of the regular API: `@_spi(Benchmarks) import Penumbra`.
@_spi(Benchmarks)
public struct LineHandleStatistics: Sendable, Equatable {
    /// Lines in the document.
    public let lineCount: Int
    /// `DocumentLineNode` handles currently kept by the line manager.
    public let liveHandles: Int
    /// Handles created since the last `TextView.resetLineHandleCounters()`.
    public let handlesCreated: Int
    /// Handles visited by row fix-ups on line insert/removal since the last reset.
    public let shiftVisits: Int
}
