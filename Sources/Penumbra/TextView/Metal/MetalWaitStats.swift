import Foundation
import Metal

/// Every place the Metal path can block the calling thread on the GPU, counted and timed (F10).
///
/// A wait is rare by design, so the cost of the two clock reads and a lock per wait is irrelevant;
/// the point is that the benchmark and the development HUD can say how often each one fires on the
/// default path instead of arguing from the code.
@_spi(Benchmarks)
public enum MetalWaitSite: String, CaseIterable, Sendable {
    /// `PageBucket.advanceForWrite`: all three glyph-instance slots are in flight.
    case glyphSlot = "glyph_slot"
    /// `DecorationBuffer.advanceForWrite`: all three decoration slots are in flight.
    case decorationSlot = "decoration_slot"
    /// `encodePass` waits for the command buffer to be scheduled (deferred present off).
    case presentScheduled = "present_scheduled"
    /// `encodePass` waits for completion to read the drawable back (capture/readback only).
    case presentReadback = "present_readback"
    /// Atlas slot read back through a blit (tests and snapshots).
    case atlasReadback = "atlas_readback"
    /// Offscreen snapshot read back (tests and snapshots).
    case snapshotReadback = "snapshot_readback"
}

@_spi(Benchmarks)
public struct MetalWaitSummary: Sendable {
    public var count = 0
    public var totalSeconds = 0.0
    public var maxSeconds = 0.0
}

@_spi(Benchmarks)
public enum MetalWaitStats {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var summaries: [MetalWaitSite: MetalWaitSummary] = [:]

    /// Benchmarks only: build the glyph atlas as a discrete GPU would get it (private storage, so
    /// every upload and clear is a staging buffer, a blit and a `waitUntilCompleted`). Set before the
    /// first Metal text view is created; the atlas is process-wide and made once.
    nonisolated(unsafe) public static var simulatesDiscreteGPUAtlas = false

    public static func reset() {
        lock.withLock { summaries = [:] }
    }

    public static func snapshot() -> [MetalWaitSite: MetalWaitSummary] {
        lock.withLock { summaries }
    }

    /// Runs `wait`, which blocks, and records how long it did.
    @inline(__always)
    static func measure<T>(_ site: MetalWaitSite, _ wait: () -> T) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = wait()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
        lock.withLock {
            var summary = summaries[site, default: MetalWaitSummary()]
            summary.count += 1
            summary.totalSeconds += seconds
            summary.maxSeconds = max(summary.maxSeconds, seconds)
            summaries[site] = summary
        }
        return result
    }

    static func waitUntilCompleted(_ commandBuffer: MTLCommandBuffer, site: MetalWaitSite) {
        measure(site) { commandBuffer.waitUntilCompleted() }
    }

    static func waitUntilScheduled(_ commandBuffer: MTLCommandBuffer, site: MetalWaitSite) {
        measure(site) { commandBuffer.waitUntilScheduled() }
    }
}
