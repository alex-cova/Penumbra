import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Wall-clock + memory measurement helpers for the perf harness.
///
/// This is a headless CLI: it drives `TextView`/`TextViewState` directly without a window or run loop,
/// so it measures the engine-level costs identified in the audit (parse, line-index build, buffer
/// mutation, search) rather than real on-screen compositing. See PERFORMANCE_AUDIT.md Phase 5 for what
/// still needs an Instruments-driven pass on top of these numbers.
enum Measurement {
    /// Resident set size in bytes, via `task_info`/`mach_task_basic_info`.
    static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPtr -> kern_return_t in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }

    struct TimedResult<T> {
        let value: T
        let seconds: Double
    }

    static func time<T>(_ label: String? = nil, _ body: () throws -> T) rethrows -> TimedResult<T> {
        let start = DispatchTime.now()
        let value = try body()
        let end = DispatchTime.now()
        let seconds = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        if let label {
            FileHandle.standardError.write("  [\(label)] \(String(format: "%.4f", seconds))s\n".data(using: .utf8)!)
        }
        return TimedResult(value: value, seconds: seconds)
    }

    /// `TextView` defers some scroll-metric updates (e.g. `contentSize`) onto `DispatchQueue.main.async`
    /// (see `TextView.swift:1676`) to avoid mutating scroll state mid-layout-pass. A headless CLI has no
    /// running main-run-loop to service that, so anything that reads `contentSize` after a layout pass
    /// needs to pump the run loop briefly first.
    static func pumpRunLoop(seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Nearest-rank percentile. `p` is in (0, 1], e.g. `0.95`.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        let index = min(sorted.count, max(1, rank)) - 1
        return sorted[index]
    }

    /// Bytes currently in use in the default malloc zone.
    static func mallocBytesInUse() -> UInt64 {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(malloc_default_zone(), &stats)
        return UInt64(stats.size_in_use)
    }

    /// User + system CPU time of the calling thread, in seconds.
    static func threadCPUSeconds() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                thread_info(mach_thread_self(), thread_flavor_t(THREAD_BASIC_INFO), intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        return user + system
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb > 1024 {
            return String(format: "%.2f GB", mb / 1024)
        }
        return String(format: "%.2f MB", mb)
    }
}

/// Minimal CSV-row emitter so results can be piped into a spreadsheet or plotting script.
enum ResultLog {
    nonisolated(unsafe) static var didPrintHeader = false

    static func row(_ metric: String, file: String, sizeBytes: UInt64, seconds: Double, extra: String = "") {
        if !didPrintHeader {
            print("metric,file,size_bytes,seconds,extra")
            didPrintHeader = true
        }
        print("\(metric),\(file),\(sizeBytes),\(String(format: "%.6f", seconds)),\(extra)")
    }
}
