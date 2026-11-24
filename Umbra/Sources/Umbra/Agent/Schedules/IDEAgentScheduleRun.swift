import AgentKit
import Foundation

/// One run a schedule started: when, in which chat, and how it ended. The Schedules sheet lists them.
struct IDEAgentScheduleRun: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var scheduleID: UUID
    /// The schedule's name when it ran, so a deleted schedule's runs still say what they were.
    var scheduleName: String
    /// The chat's saved conversation, to open it.
    var conversationID: UUID
    var startedAt: Date
    var endedAt: Date?
    /// "Completed", or why it did not (`IDEAgentToolSummary.endingMessage`). Nil while it runs.
    var outcome: String?
    var isError = false
    var filesChanged = 0
    var cost: Double?
}

/// `<project folder>/schedule-runs.json` beside `schedules.json` (0600): the newest `limit` runs, newest first.
enum IDEAgentScheduleRunLog {
    static let limit = 200

    static func url(store: SessionStore, projectRoot: String) -> URL {
        store.projectDirectory(for: projectRoot).appendingPathComponent("schedule-runs.json")
    }

    /// A run that started, put first; the oldest past `limit` go.
    static func started(_ run: IDEAgentScheduleRun, in runs: [IDEAgentScheduleRun], limit: Int = limit) -> [IDEAgentScheduleRun] {
        Array(([run] + runs).prefix(limit))
    }

    /// Records how the run in `conversationID` ended: the newest run of that chat with no ending yet.
    /// Returns nil when no such run is waiting (the chat was not a scheduled run, or it was recorded).
    static func ended(
        conversationID: UUID, ending: RunEnding, at date: Date, filesChanged: Int, cost: Double?,
        iterationLimit: Int, in runs: [IDEAgentScheduleRun]
    ) -> [IDEAgentScheduleRun]? {
        guard let index = runs.firstIndex(where: { $0.conversationID == conversationID && $0.endedAt == nil }) else { return nil }
        var runs = runs
        runs[index].endedAt = date
        if ending == .completed {
            runs[index].outcome = "Completed"
        } else {
            let message = IDEAgentToolSummary.endingMessage(ending, iterationLimit: iterationLimit)
            runs[index].outcome = message?.text ?? "Ended"
            runs[index].isError = message?.isError ?? false
        }
        runs[index].filesChanged = filesChanged
        runs[index].cost = cost
        return runs
    }

    /// "12 s", "4 min", "1 h 5 min".
    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func load(store: SessionStore, projectRoot: String) -> [IDEAgentScheduleRun] {
        guard let data = try? Data(contentsOf: url(store: store, projectRoot: projectRoot)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([IDEAgentScheduleRun].self, from: data)) ?? []
    }

    static func save(_ runs: [IDEAgentScheduleRun], store: SessionStore, projectRoot: String) {
        let url = url(store: store, projectRoot: projectRoot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(runs).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Best effort, like the schedules themselves: a run log that cannot be written loses its history only.
        }
    }
}
