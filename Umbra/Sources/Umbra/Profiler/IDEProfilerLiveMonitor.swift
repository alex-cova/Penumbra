import Darwin
import Foundation
import JavaIntelligence
import Observation
import SubprocessKit

/// Watches the JVM of a profiled run while it runs: CPU, memory and thread counts as series for the
/// profiler tab's charts, and the two things a profiler lets you do to a live process (write the
/// recording so far, run a collection).
///
/// Two cheap sources and one that costs a process: the OS's own accounting of the pid (`libproc`:
/// CPU time, resident memory, thread count, once a second, no JVM involved), and `jcmd` for what only
/// the JVM knows (heap, metaspace, Java thread counts), every other second. A JVM that refuses the
/// attach (`-XX:+DisableAttachMechanism`, another user) leaves the OS series and says why.
@MainActor
@Observable
final class IDEProfilerLiveMonitor {
    struct Sample: Identifiable, Equatable {
        var id: Int
        /// Seconds since the monitor attached.
        var seconds: Double
        /// Percent of one core: 100 is one core busy, a JVM with several busy threads goes over.
        var cpuPercent: Double?
        var residentBytes: Int?
        var osThreads: Int?
        var heapUsedBytes: Int?
        var heapCommittedBytes: Int?
        var heapMaxBytes: Int?
        var metaspaceUsedBytes: Int?
        var liveThreads: Int?
        var daemonThreads: Int?
    }

    enum Status: Equatable {
        /// Looking for the run's JVM (a Gradle build runs first).
        case waiting
        case attached(pid: Int32)
        /// The JVM ended; the last samples stay.
        case ended
    }

    private(set) var samples: [Sample] = []
    private(set) var status: Status = .waiting
    /// Why part of the data is missing, in a sentence; `nil` while everything is read.
    private(set) var notice: String?
    /// Recordings written by Capture Snapshot, oldest first.
    private(set) var snapshots: [URL] = []
    private(set) var isBusy = false

    static let maximumSamples = 1_800

    let runID: String
    private let jcmd: URL?
    private let jps: URL?
    private let snapshotDirectory: URL
    /// The pid when the caller started the process itself.
    private let knownProcessID: (@MainActor () -> Int32?)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var jcmdWorks = true

    init(
        runID: String, jcmd: URL?, jps: URL?, snapshotDirectory: URL, knownProcessID: (@MainActor () -> Int32?)?
    ) {
        self.runID = runID
        self.jcmd = jcmd
        self.jps = jps
        self.snapshotDirectory = snapshotDirectory
        self.knownProcessID = knownProcessID
    }

    deinit {
        task?.cancel()
    }

    var pid: Int32? {
        if case .attached(let pid) = status { return pid }
        return nil
    }

    var latest: Sample? { samples.last }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Tests

    /// Puts readings and a state in the monitor without a process behind it (view tests).
    func installForTesting(samples: [Sample], status: Status, notice: String? = nil) {
        self.samples = samples
        self.status = status
        self.notice = notice
    }

    // MARK: - Loop

    private func run() async {
        guard let pid = await findProcess() else { return }
        status = .attached(pid: pid)
        if jcmd == nil {
            notice = "This JDK has no jcmd, so heap and thread charts are unavailable."
            jcmdWorks = false
        }
        let origin = Date()
        var previous: (cpu: UInt64, at: Date)?
        var tick = 0
        while !Task.isCancelled {
            guard let info = Self.taskInfo(of: pid) else {
                status = .ended
                return
            }
            let now = Date()
            var sample = Sample(id: nextID, seconds: now.timeIntervalSince(origin))
            nextID += 1
            sample.residentBytes = Int(clamping: info.resident)
            sample.osThreads = info.threads
            if let previous {
                let wall = now.timeIntervalSince(previous.at)
                if wall > 0, info.cpuNanoseconds >= previous.cpu {
                    sample.cpuPercent = Double(info.cpuNanoseconds - previous.cpu) / (wall * 1_000_000_000) * 100
                }
            }
            previous = (info.cpuNanoseconds, now)

            if tick % 2 == 0, jcmdWorks, let jcmd {
                async let heapText = Self.output(of: JavaLiveCommands.heapInfo(jcmd: jcmd, pid: pid))
                async let counterText = Self.output(of: JavaLiveCommands.perfCounters(jcmd: jcmd, pid: pid))
                let (heap, counters) = await (heapText, counterText)
                if let heap, let parsed = JavaLiveMetricsParser.parseHeapInfo(heap) {
                    sample.heapUsedBytes = parsed.usedBytes
                    sample.heapCommittedBytes = parsed.committedBytes
                    sample.heapMaxBytes = parsed.maxBytes
                } else if heap == nil, counters == nil {
                    // Both failed: the attach is refused. Say so once and stop asking.
                    jcmdWorks = false
                    notice = "The JVM does not accept jcmd (attach is disabled or refused), so only CPU and memory are shown."
                }
                if let counters {
                    let parsed = JavaLiveMetricsParser.parsePerfCounters(counters)
                    sample.liveThreads = parsed.liveThreads
                    sample.daemonThreads = parsed.daemonThreads
                    sample.metaspaceUsedBytes = parsed.metaspaceUsedBytes
                }
            } else if let last = samples.last {
                // Between jcmd readings the series keep their last value, so the lines are continuous.
                sample.heapUsedBytes = last.heapUsedBytes
                sample.heapCommittedBytes = last.heapCommittedBytes
                sample.heapMaxBytes = last.heapMaxBytes
                sample.metaspaceUsedBytes = last.metaspaceUsedBytes
                sample.liveThreads = last.liveThreads
                sample.daemonThreads = last.daemonThreads
            }
            samples.append(sample)
            if samples.count > Self.maximumSamples { samples.removeFirst(samples.count - Self.maximumSamples) }
            tick += 1
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// The run's JVM: the pid the caller knows, else the one `jps -v` shows with this run's marker.
    private func findProcess() async -> Int32? {
        while !Task.isCancelled {
            if let known = knownProcessID?(), known > 0 { return known }
            if let jps, let text = await Self.output(of: JavaLiveCommands.listJVMs(jps: jps)),
               let pid = JavaLiveCommands.pids(inJPSOutput: text, runID: runID).first {
                return pid
            }
            try? await Task.sleep(for: .milliseconds(700))
        }
        return nil
    }

    // MARK: - Actions

    /// Writes the recording so far next to the run's other files and returns it. `nil`, with
    /// ``notice`` saying why, when the JVM is not reachable.
    func captureSnapshot() async -> URL? {
        guard let pid, let jcmd, !isBusy else {
            notice = "A snapshot needs the running JVM and jcmd."
            return nil
        }
        isBusy = true
        defer { isBusy = false }
        try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        let file = snapshotDirectory.appendingPathComponent(
            "snapshot-\(snapshots.count + 1)-\(Int(Date().timeIntervalSince1970)).jfr"
        )
        let call = JavaLiveCommands.dumpRecording(jcmd: jcmd, pid: pid, file: file)
        guard await Self.output(of: call, timeout: .seconds(60)) != nil,
              FileManager.default.fileExists(atPath: file.path) else {
            notice = "The JVM did not write a snapshot."
            return nil
        }
        snapshots.append(file)
        return file
    }

    func collectGarbage() async {
        guard let pid, let jcmd, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        _ = await Self.output(of: JavaLiveCommands.collectGarbage(jcmd: jcmd, pid: pid), timeout: .seconds(30))
    }

    // MARK: - Reading

    private static func output(of call: JavaToolInvocation, timeout: Duration = .seconds(8)) async -> String? {
        var request = SubprocessRequest(executable: call.executable.path, arguments: call.arguments)
        request.timeout = timeout
        request.stderrCapture = .bounded(head: 2_000, tail: 2_000)
        guard let result = try? await SubprocessRunner.run(request),
              result.exit.succeeded, !result.timedOut, !result.cancelled else { return nil }
        return result.stdout.text
    }

    struct TaskInfo {
        var cpuNanoseconds: UInt64
        var resident: UInt64
        var threads: Int
    }

    /// The OS's accounting of a process of this user: CPU time (converted from Mach absolute time),
    /// resident size and thread count. `nil` once the process is gone.
    static func taskInfo(of pid: Int32) -> TaskInfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = info.pti_total_user &+ info.pti_total_system
        let nanoseconds = timebase.denom == 0 ? ticks : ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
        return TaskInfo(cpuNanoseconds: nanoseconds, resident: info.pti_resident_size, threads: Int(info.pti_threadnum))
    }
}
