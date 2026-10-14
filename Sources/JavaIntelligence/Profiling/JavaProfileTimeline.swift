import Foundation

/// A profile laid out over time: the activity of each thread in fixed-width buckets, the JVM's CPU
/// load and heap in use as series, and the garbage collections as bands. Pure values for a view to
/// draw; nothing here knows about a window.
public struct JavaProfileTimeline: Sendable {
    /// One thread's activity per bucket.
    public struct Lane: Equatable, Sendable {
        public var name: String
        /// Share of each bucket (0...1) the thread was sampled running: each CPU sample stands for
        /// one sampling period from its time on, the way a profiler paints a thread as running.
        public var running: [Float]
        /// Share of each bucket (0...1) the thread spent in a recorded wait (a monitor, a park, a
        /// sleep, a socket or file operation). Waits overlap their whole duration, not their start.
        public var waiting: [Float]
        /// Bytes the thread's sampled allocations stand for, per bucket.
        public var allocated: [Int32]
        /// The samples of every kind, for ordering lanes: busiest first.
        public var activity: Int

        public var maxRunning: Float { running.max() ?? 0 }
    }

    public struct GCBand: Equatable, Sendable {
        public var start: Int32
        public var milliseconds: Double
        public var name: String
    }

    /// The first and last millisecond covered, from the profile's origin.
    public let span: ClosedRange<Int32>
    public let bucketCount: Int
    public private(set) var lanes: [Lane]
    /// Threads left out because only the busiest ``maximumLanes`` are drawn.
    public private(set) var omittedLanes: Int
    public let cpuLoad: [JavaLoadPoint]
    public let heap: [JavaHeapPoint]
    public let gcBands: [GCBand]

    public static let defaultBuckets = 600
    public static let maximumLanes = 64

    /// Milliseconds one bucket covers.
    public var bucketMilliseconds: Double {
        Double(span.upperBound - span.lowerBound + 1) / Double(max(bucketCount, 1))
    }

    /// The bucket `time` falls in, clamped to the span.
    public func bucket(at time: Int32) -> Int {
        let offset = Double(time - span.lowerBound)
        return min(max(Int(offset / bucketMilliseconds), 0), bucketCount - 1)
    }

    /// The first whole millisecond of a bucket (rounded up, so ``bucket(at:)`` of it is the bucket).
    public func time(ofBucket bucket: Int) -> Int32 {
        span.lowerBound + Int32(ceil(Double(bucket) * bucketMilliseconds))
    }

    /// `nil` when the profile has no timestamps (a hand-built one, or an old export).
    public static func build(
        from profile: JavaProfile, buckets: Int = defaultBuckets, maximumLanes: Int = maximumLanes,
        samplePeriodMilliseconds: Double? = nil
    ) -> JavaProfileTimeline? {
        guard let observed = profile.timeSpan else { return nil }
        // A wait that began last is still running after its start time.
        var upper = observed.upperBound
        let waits = profile.samples(of: .contention)
        for row in 0..<waits.count {
            let end = Int64(waits.times[row]) + Int64(waits.weights[row]) / 1_000
            if end > Int64(upper) { upper = Int32(clamping: end) }
        }
        let span = observed.lowerBound...max(upper, observed.lowerBound + 1)
        let count = max(buckets, 1)
        let width = Double(span.upperBound - span.lowerBound + 1) / Double(count)

        func bucket(_ time: Int32) -> Int {
            min(max(Int(Double(time - span.lowerBound) / width), 0), count - 1)
        }

        let period = max(samplePeriodMilliseconds ?? profile.estimatedCPUSamplePeriodMilliseconds() ?? 10, 1)
        var running: [Int: [Float]] = [:]
        var waiting: [Int: [Float]] = [:]
        var allocated: [Int: [Int32]] = [:]
        var activity: [Int: Int] = [:]
        let noThread = Int(JavaProfile.noThread)

        let cpu = profile.samples(of: .cpu)
        for row in 0..<cpu.count {
            let thread = Int(cpu.threads[row])
            if thread == noThread { continue }
            let start = Double(cpu.times[row] - span.lowerBound)
            var series = running[thread] ?? [Float](repeating: 0, count: count)
            spread(from: start, to: start + period, width: width, into: &series)
            running[thread] = series
            activity[thread, default: 0] += 1
        }

        let alloc = profile.samples(of: .allocation)
        for row in 0..<alloc.count {
            let thread = Int(alloc.threads[row])
            if thread == noThread { continue }
            let index = bucket(alloc.times[row])
            var series = allocated[thread] ?? [Int32](repeating: 0, count: count)
            series[index] = Int32(clamping: Int64(series[index]) + Int64(alloc.weights[row]))
            allocated[thread] = series
            activity[thread, default: 0] += 1
        }

        // A wait is spread over the buckets it covers, each by the share of the bucket it fills.
        for row in 0..<waits.count {
            let thread = Int(waits.threads[row])
            if thread == noThread { continue }
            let start = Double(waits.times[row] - span.lowerBound)
            var series = waiting[thread] ?? [Float](repeating: 0, count: count)
            spread(from: start, to: start + Double(waits.weights[row]) / 1_000, width: width, into: &series)
            waiting[thread] = series
            activity[thread, default: 0] += 1
        }

        let ordered = activity.keys.sorted {
            activity[$0]! != activity[$1]! ? activity[$0]! > activity[$1]! : $0 < $1
        }
        let kept = ordered.prefix(max(maximumLanes, 1))
        let names = profile.threadNames
        let lanes = kept.map { thread in
            Lane(
                name: thread < names.count ? names[thread] : "thread \(thread)",
                running: running[thread] ?? [Float](repeating: 0, count: count),
                waiting: waiting[thread] ?? [Float](repeating: 0, count: count),
                allocated: allocated[thread] ?? [Int32](repeating: 0, count: count),
                activity: activity[thread] ?? 0
            )
        }
        let bands = profile.gcPauses.compactMap { pause -> GCBand? in
            guard let start = pause.startMilliseconds else { return nil }
            return GCBand(start: start, milliseconds: Double(pause.nanoseconds) / 1_000_000, name: pause.name)
        }
        return JavaProfileTimeline(
            span: span, bucketCount: count, lanes: lanes, omittedLanes: max(ordered.count - kept.count, 0),
            cpuLoad: profile.cpuLoad.sorted { $0.time < $1.time },
            heap: profile.heap.sorted { $0.time < $1.time },
            gcBands: bands
        )
    }
}

/// Adds to each bucket the share of it that `start...end` (milliseconds from the span's start)
/// covers, up to 1.
private func spread(from start: Double, to end: Double, width: Double, into series: inout [Float]) {
    let count = series.count
    guard count > 0, end >= start else { return }
    let first = min(max(Int(start / width), 0), count - 1)
    let last = min(max(Int(end / width), 0), count - 1)
    for index in first...last {
        let low = max(start, Double(index) * width)
        let high = min(end, Double(index + 1) * width)
        if high > low { series[index] = min(1, series[index] + Float((high - low) / width)) }
    }
}

extension JavaProfile {
    /// The sample of `thread` nearest to `time` within `tolerance` milliseconds, over every kind: what
    /// a click on the timeline lands on. A wait counts while it lasts, not only at its start.
    public func nearestSample(
        thread: String, time: Int32, tolerance: Int32
    ) -> (kind: JavaSampleKind, node: Int, time: Int32)? {
        guard let index = threadNames.firstIndex(of: thread) else { return nil }
        let wanted = UInt16(truncatingIfNeeded: index)
        var best: (kind: JavaSampleKind, node: Int, time: Int32, distance: Int32)?
        for kind in JavaSampleKind.allCases {
            let table = samples(of: kind)
            for row in 0..<table.count where table.threads[row] == wanted {
                let start = table.times[row]
                var distance = abs(start - time)
                if kind == .contention {
                    let end = start + Int32(clamping: Int64(table.weights[row]) / 1_000)
                    if time >= start, time <= end { distance = 0 }
                }
                guard distance <= tolerance else { continue }
                if best == nil || distance < best!.distance {
                    best = (kind, Int(table.nodes[row]), start, distance)
                }
            }
        }
        return best.map { ($0.kind, $0.node, $0.time) }
    }
}
