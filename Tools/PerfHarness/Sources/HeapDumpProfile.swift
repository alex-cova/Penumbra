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
        print("reachable=\(reopened.reachableCount) reachable_bytes=\(reopened.reachableBytes) weakly_reachable=\(reopened.weaklyReachableCount) weakly_bytes=\(reopened.weaklyReachableBytes) unreachable=\(reopened.unreachableCount) unreachable_bytes=\(reopened.unreachableBytes)")
        let domStart = ContinuousClock.now
        let top = reopened.dominatorChildren(of: 0, range: 0..<10)
        print(String(format: "top_dominators_ms=%.1f", milliseconds(since: domStart)))
        for n in top {
            let share = Double(reopened.retainedSize(of: n)) / Double(max(reopened.reachableBytes, 1)) * 100
            print(String(format: "dominator %6.2f%% %12lld  %@", share, reopened.retainedSize(of: n), reopened.title(of: n)))
        }
        for total in reopened.weaklyReachableClasses(limit: 5) {
            print("weakly \(total.count) \(total.bytes) \(total.name)")
        }
        if let first = top.first {
            let retainsStart = ContinuousClock.now
            let held = reopened.retainedClasses(of: first)
            print(String(format: "retains_ms=%.0f classes=%d complete=%@", milliseconds(since: retainsStart), held.classes.count, held.complete ? "yes" : "no"))
            let mergedStart = ContinuousClock.now
            if let row = overview.histogram.rows.first(where: { $0.kind == .instance && $0.name != "java.lang.String" }),
               let group = reopened.groupIndex(for: row) {
                let merged = reopened.mergedPathsToRoots(of: reopened.instances(ofGroup: group, order: .largestRetainedFirst, limit: 10_000))
                print(String(format: "merged_paths_ms=%.0f lines=%d class=%@", milliseconds(since: mergedStart), merged.count, row.name))
            }
            let pathStart = ContinuousClock.now
            let path = reopened.pathToRoot(of: reopened.dominatorChildren(of: first, range: 0..<1).first ?? first)
            print(String(format: "path_ms=%.2f length=%d root=%@", milliseconds(since: pathStart), path.count,
                         reopened.roots(of: path.last ?? 0).first?.kind.rawValue ?? "?"))
        }
        if !keep { try? FileManager.default.removeItem(at: into == nil ? store.root : target) }
    }

    /// `heap-dump-reports <file> [--into DIR]`: phase 4 on an index (built, or reused from a store
    /// at DIR): leak suspects, the three inspections and the threads, each timed.
    static func runReports(path: String, into: String?) throws {
        let url = URL(fileURLWithPath: path)
        let store = HeapIndexStore(root: URL(fileURLWithPath: into ?? (NSTemporaryDirectory() + "heap-reports-\(getpid())")))
        let index: HeapIndex
        if let existing = store.openExisting(for: url) {
            index = existing
        } else {
            let overview = try blocking { try await HeapDumpCensus.read(url) }
            index = try blocking { try await store.build(dump: url, layout: overview.layout) }
        }
        defer { if into == nil { try? FileManager.default.removeItem(at: store.root) } }
        for name in ["duplicate-strings", "wasted-collections", "zero-arrays"] {
            try? FileManager.default.removeItem(at: index.directory.appendingPathComponent("report-\(name).json"))
        }
        var start = ContinuousClock.now
        let suspects = HeapLeakSuspects.find(in: index)
        print(String(format: "suspects_ms=%.0f count=%d", milliseconds(since: start), suspects.count))
        for suspect in suspects { print("suspect \(suspect.summary)") }
        start = .now
        let duplicates = try HeapInspections.duplicateStrings(in: index)
        print(String(format: "duplicate_strings_ms=%.0f strings=%d distinct=%d wasted=%lld", milliseconds(since: start), duplicates.stringCount, duplicates.distinctCount, duplicates.wastedBytes))
        for group in duplicates.groups.prefix(5) { print("duplicate ×\(group.count) \(group.wastedBytes) \(group.text.prefix(60))") }
        start = .now
        let collections = try HeapInspections.wastedCollections(in: index)
        print(String(format: "collections_ms=%.0f wasted=%lld", milliseconds(since: start), collections.wastedBytes))
        for row in collections.rows.prefix(6) { print("collection \(row.className) \(row.problem) ×\(row.count) \(row.wastedBytes)") }
        start = .now
        let zeros = try HeapInspections.zeroArrays(in: index)
        print(String(format: "zero_arrays_ms=%.0f bytes=%lld", milliseconds(since: start), zeros.bytes))
        for row in zeros.rows.prefix(4) { print("zeros \(row.className) ×\(row.count) \(row.bytes)") }
        start = .now
        let threads = index.threads()
        let named = threads.compactMap { $0.object }.map { (index.threadName($0) ?? "?", index.threadState($0)?.rawValue ?? "?", index.retainedSize(of: $0)) }
        print(String(format: "threads_ms=%.0f count=%d frames=%d", milliseconds(since: start), threads.count, threads.reduce(0) { $0 + $1.frames.count }))
        for (name, state, retained) in named.sorted(by: { $0.2 > $1.2 }).prefix(5) { print("thread \(name) \(state) retains \(retained)") }
        if let main = threads.first(where: { $0.object.flatMap(index.threadName) == "AWT-EventQueue-0" }) ?? threads.first {
            for frame in main.frames.prefix(6) { print("  at \(frame.description) locals=\(frame.locals.count)") }
        }
        print("peak_footprint_mb=\(peakFootprintMB())")
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
