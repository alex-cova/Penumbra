import Foundation

/// The JVM option that records a run with Java Flight Recorder, and what is needed to read the
/// result. JFR ships with the JDK (11 and later), so nothing is bundled and no agent is loaded.
public enum JavaFlightRecorder {
    /// The first Java feature version whose open-source JDK has Flight Recorder and the `jfr` tool.
    public static let minimumFeatureVersion = 11

    /// The first Java that accepts `jdk.ExecutionSample#period=` on the command line.
    public static let periodOptionFeatureVersion = 17

    /// Whether a JFR file name can sit in the option: JFR splits options on commas.
    public static func isSafe(_ path: String) -> Bool {
        !path.contains(",") && !path.contains("\n") && !path.contains("\"")
    }

    /// `-XX:StartFlightRecording=filename=<file>,settings=profile,dumponexit=true`.
    ///
    /// `dumponexit` writes the file when the JVM ends normally or on SIGTERM, which is what Stop
    /// sends; a SIGKILL leaves no file. `file` may hold `%p` (the process id) for a task that starts
    /// several JVMs. `samplePeriodMilliseconds` is only honoured on Java 17 and later, and `nil`
    /// keeps the `profile` setting's 10 ms. Returns `nil` for a path the option cannot carry.
    public static func vmArgument(
        file: String,
        settings: String = "profile",
        samplePeriodMilliseconds: Int? = nil,
        jdkFeatureVersion: Int? = nil
    ) -> String? {
        guard isSafe(file), isSafe(settings) else { return nil }
        var options = ["filename=\(file)", "settings=\(settings)", "dumponexit=true"]
        if let period = samplePeriodMilliseconds, period > 0,
           let version = jdkFeatureVersion, version >= periodOptionFeatureVersion {
            options.append("jdk.ExecutionSample#period=\(period)ms")
        }
        return "-XX:StartFlightRecording=" + options.joined(separator: ",")
    }

    /// A sentence when `featureVersion` cannot record, `nil` when it can (or is unknown).
    public static func unsupportedReason(featureVersion: Int?) -> String? {
        guard let featureVersion, featureVersion < minimumFeatureVersion else { return nil }
        return "Profiling uses Java Flight Recorder, which comes with Java \(minimumFeatureVersion) or newer "
            + "(this is Java \(featureVersion)). Choose a newer JDK for this configuration."
    }

    /// The event types the profiler tabs read.
    public enum EventType {
        public static let executionSample = "jdk.ExecutionSample"
        public static let allocationSample = "jdk.ObjectAllocationSample"
        public static let monitorEnter = "jdk.JavaMonitorEnter"
        public static let threadPark = "jdk.ThreadPark"
        public static let garbageCollection = "jdk.GarbageCollection"
        public static let gcPhasePause = "jdk.GCPhasePause"
        public static let cpuLoad = "jdk.CPULoad"
    }

    /// `jfr print --events … --stack-depth <depth> <file>`. JFR truncates a printed stack at 5
    /// frames unless told otherwise, so the depth is always passed.
    public static func printInvocation(
        jfr: URL, recording: URL, events: [String], stackDepth: Int = 128
    ) -> JavaToolInvocation {
        JavaToolInvocation(
            executable: jfr,
            arguments: ["print", "--events", events.joined(separator: ","), "--stack-depth", String(stackDepth), recording.path]
        )
    }

    /// `jfr summary <file>`: a header read that lists the event counts.
    public static func summaryInvocation(jfr: URL, recording: URL) -> JavaToolInvocation {
        JavaToolInvocation(executable: jfr, arguments: ["summary", recording.path])
    }
}

/// Whether a file is a Flight Recorder recording.
public enum JavaFlightRecordingDetector {
    /// `FLR\0`, the first four bytes of every recording.
    public static let magic: [UInt8] = [0x46, 0x4C, 0x52, 0x00]

    public static func hasRecordingExtension(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "jfr"
    }

    public static func hasMagic(_ bytes: [UInt8]) -> Bool {
        bytes.count >= magic.count && Array(bytes.prefix(magic.count)) == magic
    }

    /// The magic wins over the name, so a renamed recording opens and a text file named `.jfr`
    /// does not.
    public static func isRecording(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: magic.count) else { return false }
        return hasMagic(Array(data))
    }

    /// Whether to route `url` to the profiler without reading it: by name only, for a place that
    /// has not read the file yet. A file that then turns out not to be a recording is for the
    /// caller to open as text.
    public static func looksLikeRecording(_ url: URL) -> Bool {
        hasRecordingExtension(url) || isRecording(at: url)
    }
}

/// What `jfr summary` says about a recording.
public struct JFRSummary: Equatable, Sendable {
    public var version: String?
    public var chunks: Int
    public var durationDescription: String?
    /// Event type to count.
    public var eventCounts: [String: Int]

    public var executionSamples: Int { eventCounts[JavaFlightRecorder.EventType.executionSample] ?? 0 }
    public var allocationSamples: Int { eventCounts[JavaFlightRecorder.EventType.allocationSample] ?? 0 }

    public init(version: String? = nil, chunks: Int = 0, durationDescription: String? = nil, eventCounts: [String: Int] = [:]) {
        self.version = version
        self.chunks = chunks
        self.durationDescription = durationDescription
        self.eventCounts = eventCounts
    }

    public static func parse(_ text: String) -> JFRSummary {
        var summary = JFRSummary()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Version:") {
                summary.version = line.dropFirst("Version:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Chunks:") {
                summary.chunks = Int(line.dropFirst("Chunks:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("Duration:") {
                summary.durationDescription = line.dropFirst("Duration:".count).trimmingCharacters(in: .whitespaces)
            } else {
                // `jdk.ExecutionSample        255        2670`
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if parts.count == 3, parts[0].contains("."), let count = Int(parts[1]), Int(parts[2]) != nil {
                    summary.eventCounts[String(parts[0])] = count
                }
            }
        }
        return summary
    }
}
