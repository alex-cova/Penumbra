import Foundation

/// What is known about a profiled run beyond its recording, kept as `run.json` next to the `.jfr`
/// files so a list of recent profiles can say what each one was.
public struct JavaProfileRunInfo: Codable, Equatable, Sendable {
    public static let fileName = "run.json"

    /// The run configuration's name: `Spin`, `OrderServiceTest`.
    public var label: String
    public var startedAt: Date
    public var jdkFeatureVersion: Int
    /// ``JavaFlightRecorderOptions/summary`` at the time of the run.
    public var settings: String
    /// Gradle tasks of the run, empty for a plain `main`.
    public var tasks: [String]
    public var finishedAt: Date?
    public var recordingCount: Int?
    public var recordingBytes: Int?

    public init(
        label: String, startedAt: Date, jdkFeatureVersion: Int, settings: String, tasks: [String] = [],
        finishedAt: Date? = nil, recordingCount: Int? = nil, recordingBytes: Int? = nil
    ) {
        self.label = label
        self.startedAt = startedAt
        self.jdkFeatureVersion = jdkFeatureVersion
        self.settings = settings
        self.tasks = tasks
        self.finishedAt = finishedAt
        self.recordingCount = recordingCount
        self.recordingBytes = recordingBytes
    }

    /// Wall time of the run, when it ended.
    public var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }

    /// ISO 8601 with milliseconds, so a short run's duration is not rounded to the second.
    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        let formatter = Self.makeFormatter()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// The record in `directory`, or `nil` when there is none or it cannot be read (a run from before
    /// the record existed, or a file from a newer build).
    public static func read(from directory: URL) -> JavaProfileRunInfo? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        let formatter = makeFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date: \(text)"))
            }
            return date
        }
        return try? decoder.decode(JavaProfileRunInfo.self, from: data)
    }
}

/// The profiled runs of a project, newest first, with their recordings and records.
public struct JavaRecentProfile: Equatable, Identifiable, Sendable {
    public var run: JavaRunArtifacts.Run
    public var info: JavaProfileRunInfo?
    public var recordings: [URL]

    public var id: String { run.id }

    /// `Spin` for a run that knows its configuration; the run's date otherwise.
    public var title: String {
        info?.label ?? run.modified.formatted(date: .abbreviated, time: .shortened)
    }

    public static func list(
        artifacts: JavaRunArtifacts, projectHash: String, limit: Int = 10
    ) -> [JavaRecentProfile] {
        artifacts.runs(kind: .profile, projectHash: projectHash)
            .compactMap { run -> JavaRecentProfile? in
                let recordings = JavaProfileGradleScript.recordings(in: run.directory)
                guard !recordings.isEmpty else { return nil }
                return JavaRecentProfile(run: run, info: JavaProfileRunInfo.read(from: run.directory), recordings: recordings)
            }
            .prefix(limit)
            .map { $0 }
    }
}
