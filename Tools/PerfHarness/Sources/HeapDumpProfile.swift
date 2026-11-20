import Darwin
import Foundation
import JavaIntelligence

/// Release timings for reading a heap dump's histogram (phase 1 of `docs/HEAP_DUMP_PLAN.md`):
///
///   swift run -c release PerfHarness heap-dump-census <file.hprof> [--threads N]
///
/// Prints the elapsed time, throughput, peak memory footprint, the detected layout and the top
/// classes. The phase 1 gate is the 6.5 GB IntelliJ dump in under 15 s with a peak under 1 GB.
enum HeapDumpProfile {
    static func run(path: String, threads: Int?) throws {
        let url = URL(fileURLWithPath: path)
        let concurrency = threads ?? max(1, ProcessInfo.processInfo.activeProcessorCount)
        let start = ContinuousClock.now
        let overview = try blocking {
            try await HeapDumpCensus.read(url, maxConcurrency: concurrency)
        }
        let seconds = Double((ContinuousClock.now - start).components.attoseconds) / 1e18
            + Double((ContinuousClock.now - start).components.seconds)
        let gigabytes = Double(overview.fileSize) / 1e9
        print("command=heap-dump-census")
        print("file_bytes=\(overview.fileSize)")
        print("threads=\(concurrency)")
        print("elapsed_s=\(String(format: "%.2f", seconds))")
        print("throughput_gb_s=\(String(format: "%.2f", gigabytes / max(seconds, 0.001)))")
        print("peak_footprint_mb=\(peakFootprintMB())")
        print("objects=\(overview.objectCount) instances=\(overview.instanceCount) object_arrays=\(overview.objectArrayCount) primitive_arrays=\(overview.primitiveArrayCount) classes=\(overview.classCount)")
        print("roots=\(overview.rootCount) threads_in_dump=\(overview.threadCount) loaders=\(overview.classLoaderCount)")
        let confidence = overview.layoutConfidence.map { String(format: "%.1f%%", $0 * 100) } ?? "fallback"
        print("layout=\(overview.layout.shortDescription) confidence=\(confidence) samples=\(overview.layoutSampleCount)")
        print("shallow_total=\(overview.histogram.totalShallowBytes)")
        for problem in overview.problems { print("problem=\(problem)") }
        if let truncated = overview.truncatedAt { print("truncated_at=\(truncated)") }
        for row in overview.histogram.rows.prefix(15) {
            print(String(format: "%14lld  %11d  %@", row.shallowBytes, row.count, row.name))
        }
    }

    /// `heap-dump-index <file> [--into DIR] [--keep]`: builds the object index (phase 2) and reports
    /// each phase's time, the peak footprint, the index size and a few queries.
    static func runIndex(path: String, into: String?, keep: Bool) throws {
        let url = URL(fileURLWithPath: path)
        let overview = try blocking { try await HeapDumpCensus.read(url) }
        // `--into DIR` builds through a store rooted there (as Umbra does), so a test can reuse it.
        let store = HeapIndexStore(root: URL(fileURLWithPath: into ?? NSTemporaryDirectory()).appendingPathComponent(into == nil ? "heap-index-\(getpid())" : ""))
        let target = try store.directory(for: url)
        let log = PhaseLog()
        let start = ContinuousClock.now
        let index = try blocking {
            try await store.build(dump: url, layout: overview.layout) { log.note($0.phase.rawValue) }
        }
        let total = start.duration(to: .now)
        print("command=heap-dump-index")
        print("objects=\(index.objectCount) references=\(index.referenceCount) dangling=\(index.danglingReferences)")
        for (phase, seconds) in log.durations(until: .now) { print(String(format: "phase %@ %.2f s", phase, seconds)) }
        print(String(format: "build_s=%.2f", Double(total.components.seconds) + Double(total.components.attoseconds) / 1e18))
        print("peak_footprint_mb=\(peakFootprintMB())")
        print("index_mb=\(index.diskBytes / 1_048_576)")
        let reopenStart = ContinuousClock.now
        let reopened = try HeapIndex.open(directory: index.directory, dump: url)
        print(String(format: "reopen_ms=%.1f", milliseconds(since: reopenStart)))
        if let row = overview.histogram.rows.first(where: { $0.name == "java.lang.String" }),
           let group = reopened.groupIndex(for: row) {
            let queryStart = ContinuousClock.now
            let first = reopened.instances(ofGroup: group, limit: 1_000)
            let previews = first.prefix(20).compactMap { reopened.preview(of: $0) }
            print(String(format: "string_page_ms=%.1f", milliseconds(since: queryStart)))
            for text in previews.prefix(5) { print("preview \(text)") }
        }
        if let biggest = overview.histogram.rows.first(where: { $0.kind == .instance }),
           let group = reopened.groupIndex(for: biggest), let object = reopened.instances(ofGroup: group, limit: 1).first {
            let queryStart = ContinuousClock.now
            let referrers = reopened.inbound(of: object, range: 0..<100)
            let names = referrers.prefix(5).map { reopened.referenceName(from: $0.object, to: object) ?? "?" }
            print(String(format: "referrers_ms=%.1f", milliseconds(since: queryStart)))
            print("object \(reopened.title(of: object)) referrers=\(reopened.inboundCount(of: object)) via \(names)")
        }
        if !keep { try? FileManager.default.removeItem(at: into == nil ? store.root : target) }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private final class PhaseLog: @unchecked Sendable {
        private let lock = NSLock()
        private var marks: [(String, ContinuousClock.Instant)] = []

        func note(_ phase: String) {
            lock.lock()
            defer { lock.unlock() }
            if marks.last?.0 != phase { marks.append((phase, .now)) }
        }

        func durations(until end: ContinuousClock.Instant) -> [(String, Double)] {
            lock.lock()
            defer { lock.unlock() }
            return marks.enumerated().map { offset, mark in
                let next = offset + 1 < marks.count ? marks[offset + 1].1 : end
                let duration = mark.1.duration(to: next)
                return (mark.0, Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
            }
        }
    }

    private static func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        nonisolated(unsafe) var result: Result<T, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result!.get()
    }

    /// The process's peak physical footprint (what Activity Monitor calls Memory), in MB.
    private static func peakFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.ledger_phys_footprint_peak / 1_048_576)
    }
}
