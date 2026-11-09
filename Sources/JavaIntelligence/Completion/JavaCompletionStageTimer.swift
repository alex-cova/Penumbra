import Foundation

/// Wall time per stage of a completion request, for the release harness
/// (`PerfHarness java-completion`). Off by default: a disabled `measure` costs one flag read and
/// runs the body directly, so the editor pays nothing. Stage names are the keys of ``snapshot()``.
///
/// The stages of one request nest (`request` contains `parse`), so the shares are read against the
/// harness's own total, not summed.
@_spi(Benchmarks)
public enum JavaCompletionStageTimer {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var totals: [String: UInt64] = [:]
    }

    private static let state = State()
    // Written only by the harness before and after a run; a stale read costs one missed sample.
    nonisolated(unsafe) private static var isEnabled = false

    public static func enable(_ on: Bool) {
        isEnabled = on
    }

    public static func reset() {
        state.lock.lock()
        state.totals.removeAll()
        state.lock.unlock()
    }

    /// Seconds spent in each stage since the last ``reset()``.
    public static func snapshot() -> [String: Double] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.totals.mapValues { Double($0) / 1e9 }
    }

    @inline(__always)
    static func measure<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let start = DispatchTime.now().uptimeNanoseconds
        defer { record(stage, since: start) }
        return try body()
    }

    @inline(__always)
    static func measure<T>(
        _ stage: String,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard isEnabled else { return try await body() }
        let start = DispatchTime.now().uptimeNanoseconds
        defer { record(stage, since: start) }
        return try await body()
    }

    private static func record(_ stage: String, since start: UInt64) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- start
        state.lock.lock()
        state.totals[stage, default: 0] &+= elapsed
        state.lock.unlock()
    }
}
