import Foundation

/// The heap of a running JVM, as `jcmd <pid> GC.heap_info` reports it.
public struct JavaLiveHeap: Equatable, Sendable {
    public var usedBytes: Int
    /// What the JVM has committed from the OS for the heap, when the collector says.
    public var committedBytes: Int?
    /// The most the heap can grow to (`-Xmx`, or what the JVM chose).
    public var maxBytes: Int?

    public init(usedBytes: Int, committedBytes: Int? = nil, maxBytes: Int? = nil) {
        self.usedBytes = usedBytes
        self.committedBytes = committedBytes
        self.maxBytes = maxBytes
    }
}

/// The counters of `jcmd <pid> PerfCounter.print` the live charts use.
public struct JavaLivePerfCounters: Equatable, Sendable {
    public var liveThreads: Int?
    public var daemonThreads: Int?
    public var peakThreads: Int?
    public var metaspaceUsedBytes: Int?

    public init(liveThreads: Int? = nil, daemonThreads: Int? = nil, peakThreads: Int? = nil, metaspaceUsedBytes: Int? = nil) {
        self.liveThreads = liveThreads
        self.daemonThreads = daemonThreads
        self.peakThreads = peakThreads
        self.metaspaceUsedBytes = metaspaceUsedBytes
    }
}

/// The `jcmd` and `jps` calls the live view makes, and how a run's JVM is found among the machine's.
public enum JavaLiveCommands {
    /// The system property a profiled run's JVM carries, so `jps -v` can tell it from the others.
    public static let runProperty = "umbra.profile.run"

    /// `-Dumbra.profile.run=<id>`.
    public static func runArgument(runID: String) -> String { "-D\(runProperty)=\(runID)" }

    public static func heapInfo(jcmd: URL, pid: Int32) -> JavaToolInvocation {
        JavaToolInvocation(executable: jcmd, arguments: [String(pid), "GC.heap_info"])
    }

    public static func perfCounters(jcmd: URL, pid: Int32) -> JavaToolInvocation {
        JavaToolInvocation(executable: jcmd, arguments: [String(pid), "PerfCounter.print"])
    }

    /// Writes the running recording (the one named ``JavaFlightRecorder/recordingName``) to `file`
    /// without stopping it.
    public static func dumpRecording(jcmd: URL, pid: Int32, file: URL) -> JavaToolInvocation {
        JavaToolInvocation(
            executable: jcmd,
            arguments: [String(pid), "JFR.dump", "name=\(JavaFlightRecorder.recordingName)", "filename=\(file.path)"]
        )
    }

    public static func collectGarbage(jcmd: URL, pid: Int32) -> JavaToolInvocation {
        JavaToolInvocation(executable: jcmd, arguments: [String(pid), "GC.run"])
    }

    public static func listJVMs(jps: URL) -> JavaToolInvocation {
        JavaToolInvocation(executable: jps, arguments: ["-v"])
    }

    /// The process ids in `jps -v` output whose options carry this run's marker, newest (highest
    /// id) first: a test task may fork several JVMs, and the last one started is the one running.
    public static func pids(inJPSOutput output: String, runID: String) -> [Int32] {
        let marker = runArgument(runID: runID)
        var result: [Int32] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            // Match the whole option, so `run=ab` does not match `run=abc`.
            if parts[1].split(separator: " ").contains(where: { $0 == marker }) { result.append(pid) }
        }
        return result.sorted(by: >)
    }
}

/// Reads what `jcmd` prints about a running JVM. The commands are `GC.heap_info` and
/// `PerfCounter.print`; neither has a fixed format across collectors and JDKs, so this reads the
/// shapes of G1 (both spellings), Parallel, Serial, ZGC and Shenandoah, and gives `nil` for the rest
/// rather than a wrong number.
public enum JavaLiveMetricsParser {
    // MARK: - GC.heap_info

    public static func parseHeapInfo(_ text: String) -> JavaLiveHeap? {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0) }

        // G1: `garbage-first heap   total 524288K, used 37931K [0x…, 0x…)` (JDK 21), or
        // `garbage-first heap   total reserved 524288K, committed 43008K, used 33313K [0x…, 0x…)`.
        if let line = lines.first(where: { $0.contains("garbage-first heap") }) {
            guard let used = size(after: "used", in: line) else { return nil }
            if line.contains("total reserved") {
                return JavaLiveHeap(
                    usedBytes: used, committedBytes: size(after: "committed", in: line),
                    maxBytes: size(after: "total reserved", in: line)
                )
            }
            return JavaLiveHeap(usedBytes: used, committedBytes: size(after: "total", in: line), maxBytes: addressSpan(of: line))
        }

        // ZGC: ` ZHeap   used 36M, capacity 512M, max capacity 512M`.
        if let line = lines.first(where: { $0.contains("ZHeap") }) {
            guard let used = size(after: "used", in: line) else { return nil }
            return JavaLiveHeap(
                usedBytes: used, committedBytes: size(after: "capacity", in: line), maxBytes: size(after: "max capacity", in: line)
            )
        }

        // Shenandoah: `65536K max, 8192K soft max, 65536K committed, 3000K used`.
        if lines.contains(where: { $0.contains("Shenandoah") }),
           let line = lines.first(where: { $0.contains(" used") && $0.contains(" committed") }) {
            guard let used = size(before: " used", in: line) else { return nil }
            return JavaLiveHeap(
                usedBytes: used, committedBytes: size(before: " committed", in: line), maxBytes: size(before: " max,", in: line)
            )
        }

        // Generational collectors: one line per generation, `PSYoungGen      total 153088K, used 41135K
        // [0x…, 0x…, 0x…)`; Parallel and Serial, summed.
        var used = 0
        var committed = 0
        var maximum = 0
        var found = 0
        for line in lines where line.contains(" total ") && line.contains(" used ") && line.contains("[0x") {
            guard let lineUsed = size(after: "used", in: line) else { continue }
            used += lineUsed
            committed += size(after: "total", in: line) ?? 0
            maximum += addressSpan(of: line) ?? 0
            found += 1
        }
        guard found > 0 else { return nil }
        return JavaLiveHeap(usedBytes: used, committedBytes: committed, maxBytes: maximum > 0 ? maximum : nil)
    }

    // MARK: - PerfCounter.print

    public static func parsePerfCounters(_ text: String) -> JavaLivePerfCounters {
        var result = JavaLivePerfCounters()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard let value = Int(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)) else { continue }
            switch key {
            case "java.threads.live": result.liveThreads = value
            case "java.threads.daemon": result.daemonThreads = value
            case "java.threads.livePeak": result.peakThreads = value
            case "sun.gc.metaspace.used": result.metaspaceUsedBytes = value
            default: break
            }
        }
        return result
    }

    // MARK: - Pieces

    /// `used 37931K` → 37 931 × 1024. Units K, M, G; a bare number is bytes.
    static func size(after keyword: String, in line: String) -> Int? {
        var search = line.startIndex..<line.endIndex
        while let range = line.range(of: keyword, range: search) {
            var index = range.upperBound
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
            if let value = number(at: index, in: line) { return value }
            search = range.upperBound..<line.endIndex
        }
        return nil
    }

    /// `3000K used` → the number just before `keyword`.
    static func size(before keyword: String, in line: String) -> Int? {
        guard let range = line.range(of: keyword) else { return nil }
        var start = range.lowerBound
        // Walk back over the unit and the digits.
        while start > line.startIndex {
            let previous = line.index(before: start)
            let character = line[previous]
            guard character.isNumber || "KMGkmg".contains(character) else { break }
            start = previous
        }
        return number(at: start, in: line)
    }

    private static func number(at index: String.Index, in line: String) -> Int? {
        var cursor = index
        var digits = ""
        while cursor < line.endIndex, line[cursor].isNumber {
            digits.append(line[cursor])
            cursor = line.index(after: cursor)
        }
        guard let value = Int(digits) else { return nil }
        var scale = 1
        if cursor < line.endIndex {
            switch line[cursor] {
            case "K", "k": scale = 1_024
            case "M", "m": scale = 1_024 * 1_024
            case "G", "g": scale = 1_024 * 1_024 * 1_024
            default: break
            }
        }
        return value * scale
    }

    /// `[0x000000011d000000, 0x000000013d000000)` → the bytes between the first two addresses.
    static func addressSpan(of line: String) -> Int? {
        guard let open = line.range(of: "[0x") else { return nil }
        let addresses = line[open.lowerBound...]
            .split(whereSeparator: { $0 == "," || $0 == ")" || $0 == "[" || $0 == " " })
            .compactMap { part -> UInt64? in
                guard part.hasPrefix("0x") else { return nil }
                return UInt64(part.dropFirst(2), radix: 16)
            }
        guard addresses.count >= 2, addresses[1] > addresses[0] else { return nil }
        return Int(clamping: addresses[1] - addresses[0])
    }
}
