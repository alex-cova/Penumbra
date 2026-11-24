import AgentKit
import Foundation

/// A prompt the agent runs on a cadence in a project, each run in a chat of its own
/// (`docs/harness/agent-harness-11.md`, item 2). Saved per project beside its chats, so it survives a
/// relaunch; it fires only while a window has the project open. Nothing runs in the background.
struct IDEAgentSchedule: Codable, Identifiable, Equatable, Sendable {
    /// Below this, a schedule would be `/loop`'s job.
    static let minimumInterval: TimeInterval = 5 * 60

    var id = UUID()
    var name: String
    var prompt: String
    var interval: TimeInterval
    /// What each run's chat may do without asking. Auto only when the schedule was made with `--auto`.
    var mode: PermissionMode
    /// The model or external agent of the chat it was made in; nil follows the settings at run time.
    var modelChoice: IDEAIModelChoice?
    var binding: IDEACPBinding?
    var createdAt: Date
    var lastRunAt: Date?
    /// The saved conversation of the latest run, to open it from the list.
    var lastChatID: UUID?
    /// What happened at the latest tick that did not start a run ("Skipped: …", "Missed …").
    var lastNote: String?
    var isPaused = false

    var nextDue: Date { (lastRunAt ?? createdAt).addingTimeInterval(interval) }

    static func name(for prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 40 ? String(trimmed.prefix(39)) + "…" : trimmed
    }
}

/// What a tick does with one schedule. Pure, so the rules are tested without a clock.
enum IDEAgentScheduleTiming {
    enum Decision: Equatable {
        case notDue
        case run
        /// It fell due before this window was watching (Umbra was closed, or the project was not open). It is
        /// offered, never run on its own: edits apply without asking, so the user decides.
        case missed(due: Date)
    }

    /// `watchingSince`: when this window started watching the project's schedules.
    static func decide(_ schedule: IDEAgentSchedule, now: Date, watchingSince: Date) -> Decision {
        guard !schedule.isPaused else { return .notDue }
        let due = schedule.nextDue
        guard due <= now else { return .notDue }
        return due < watchingSince ? .missed(due: due) : .run
    }
}

/// `<project folder>/schedules.json` beside the project's chats (0600).
enum IDEAgentScheduleFile {
    static func url(store: SessionStore, projectRoot: String) -> URL {
        store.projectDirectory(for: projectRoot).appendingPathComponent("schedules.json")
    }

    static func load(store: SessionStore, projectRoot: String) -> [IDEAgentSchedule] {
        guard let data = try? Data(contentsOf: url(store: store, projectRoot: projectRoot)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([IDEAgentSchedule].self, from: data)) ?? []
    }

    static func save(_ schedules: [IDEAgentSchedule], store: SessionStore, projectRoot: String) {
        let url = url(store: store, projectRoot: projectRoot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(schedules).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // A failed write costs the schedule's progress, which the next tick writes again.
        }
    }
}
