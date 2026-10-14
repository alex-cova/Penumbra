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

    /// The name the recording is given, which is how `jcmd <pid> JFR.dump name=umbra` finds it.
    public static let recordingName = "umbra"

    /// `-XX:StartFlightRecording=name=umbra,filename=<file>,settings=profile,dumponexit=true`.
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
        var options = JavaFlightRecorderOptions()
        options.template = JavaFlightRecorderOptions.Template(settingsValue: settings)
        options.samplePeriodMilliseconds = samplePeriodMilliseconds
        return vmArguments(file: file, options: options, jdkFeatureVersion: jdkFeatureVersion)?.first
    }

    /// The JVM options that record a run as `options` says: the `StartFlightRecording` option, then
    /// the stack depth (a JVM option of its own). `nil` when a path cannot be carried.
    public static func vmArguments(
        file: String, options: JavaFlightRecorderOptions, jdkFeatureVersion: Int?
    ) -> [String]? {
        guard isSafe(file), options.isSafe else { return nil }
        var parts = [
            "name=\(recordingName)", "filename=\(file)", "settings=\(options.template.settingsValue)", "dumponexit=true"
        ]
        parts += options.eventSettings(jdkFeatureVersion: jdkFeatureVersion)
        return ["-XX:StartFlightRecording=" + parts.joined(separator: ","), stackDepthArgument(options.stackDepth)]
    }

    /// JFR keeps 64 frames of a stack unless told otherwise, which cuts a deep framework stack
    /// before its callers; the importer reads 128, so the recorder is asked for as many.
    public static let defaultStackDepth = 128
    public static let maximumStackDepth = 2048

    /// `-XX:FlightRecorderOptions=stackdepth=<n>`, a JVM option of its own (not part of
    /// `StartFlightRecording`); accepted by every JDK that has JFR in the open-source build.
    public static func stackDepthArgument(_ depth: Int = defaultStackDepth) -> String {
        "-XX:FlightRecorderOptions=stackdepth=\(min(max(depth, 1), maximumStackDepth))"
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
        public static let gcHeapSummary = "jdk.GCHeapSummary"
        public static let threadSleep = "jdk.ThreadSleep"
        public static let monitorWait = "jdk.JavaMonitorWait"
        public static let socketRead = "jdk.SocketRead"
        public static let socketWrite = "jdk.SocketWrite"
        public static let fileRead = "jdk.FileRead"
        public static let fileWrite = "jdk.FileWrite"

        /// What the profiler reads by default: samples, waits, collections and the two series the
        /// timeline draws.
        public static let profiled: [String] = [
            executionSample, allocationSample, monitorEnter, threadPark, threadSleep, monitorWait,
            socketRead, socketWrite, fileRead, fileWrite, garbageCollection, gcHeapSummary, cpuLoad
        ]
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

/// What a profiled run records and how much: the settings template, how often the CPU is sampled,
/// how deep a stack is kept and when a wait is long enough to count.
public struct JavaFlightRecorderOptions: Codable, Equatable, Sendable {
    public enum Template: Codable, Equatable, Sendable {
        /// The JDK's `profile.jfc`: about 2 % overhead, a 10 ms CPU period.
        case profile
        /// The JDK's `default.jfc`: about 1 %, 20 ms.
        case standard
        /// A `.jfc` file, made in JDK Mission Control or by hand.
        case custom(path: String)

        /// The value of `settings=`: a name the JDK knows, or the path.
        public var settingsValue: String {
            switch self {
            case .profile: return "profile"
            case .standard: return "default"
            case .custom(let path): return path
            }
        }

        public init(settingsValue: String) {
            switch settingsValue {
            case "profile": self = .profile
            case "default": self = .standard
            default: self = .custom(path: settingsValue)
            }
        }
    }

    public var template: Template = .profile
    /// CPU sampling period; `nil` keeps the template's. Event settings on the command line need Java 17.
    public var samplePeriodMilliseconds: Int?
    public var stackDepth: Int = JavaFlightRecorder.defaultStackDepth
    /// Allocation samples per second (`jdk.ObjectAllocationSample#throttle`); `nil` keeps the template's 150.
    public var allocationSamplesPerSecond: Int?
    /// The shortest wait that is recorded, for monitors, parks, sleeps and socket and file operations;
    /// `nil` keeps the template's (10 ms in `profile`, 20 ms in `default`).
    public var waitThresholdMilliseconds: Int?

    public init(
        template: Template = .profile, samplePeriodMilliseconds: Int? = nil,
        stackDepth: Int = JavaFlightRecorder.defaultStackDepth,
        allocationSamplesPerSecond: Int? = nil, waitThresholdMilliseconds: Int? = nil
    ) {
        self.template = template
        self.samplePeriodMilliseconds = samplePeriodMilliseconds
        self.stackDepth = stackDepth
        self.allocationSamplesPerSecond = allocationSamplesPerSecond
        self.waitThresholdMilliseconds = waitThresholdMilliseconds
    }

    /// Whether the settings value can sit in the option (JFR splits options on commas).
    public var isSafe: Bool { JavaFlightRecorder.isSafe(template.settingsValue) }

    /// Events whose threshold the wait setting changes.
    static let waitEvents = [
        "jdk.JavaMonitorEnter", "jdk.JavaMonitorWait", "jdk.ThreadPark", "jdk.ThreadSleep",
        "jdk.SocketRead", "jdk.SocketWrite", "jdk.FileRead", "jdk.FileWrite"
    ]

    /// `jdk.Event#key=value` settings for the options that are set, empty before Java 17 (which does
    /// not take them on the command line; a custom `.jfc` carries them there).
    public func eventSettings(jdkFeatureVersion: Int?) -> [String] {
        guard let version = jdkFeatureVersion, version >= JavaFlightRecorder.periodOptionFeatureVersion else { return [] }
        var result: [String] = []
        if let period = samplePeriodMilliseconds, period > 0 {
            result.append("jdk.ExecutionSample#period=\(period)ms")
        }
        if let rate = allocationSamplesPerSecond, rate > 0 {
            result.append("jdk.ObjectAllocationSample#throttle=\(rate)/s")
        }
        if let threshold = waitThresholdMilliseconds, threshold >= 0 {
            result += Self.waitEvents.map { "\($0)#threshold=\(threshold)ms" }
        }
        return result
    }

    /// One line for a run's record: `profile · 5 ms · depth 128`.
    public var summary: String {
        var parts: [String] = []
        switch template {
        case .profile: parts.append("profile")
        case .standard: parts.append("default")
        case .custom(let path): parts.append(URL(fileURLWithPath: path).lastPathComponent)
        }
        if let period = samplePeriodMilliseconds, period > 0 { parts.append("\(period) ms") }
        parts.append("depth \(stackDepth)")
        return parts.joined(separator: " · ")
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
