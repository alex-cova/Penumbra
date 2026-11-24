import AgentKit
import Foundation

/// Runs a project's schedules while this window has the project open (`IDEAgentSchedule`,
/// `docs/harness/agent-harness-11.md` item 2). A tick every `tickInterval` reloads them when the project
/// changes, starts the ones that are due, each in a new chat that is not selected, and offers the ones that
/// fell due before the window was watching instead of running them. Only with a store: tests and windows
/// without persistence run nothing on their own.
@MainActor @Observable
final class IDEAgentScheduler {
    nonisolated(unsafe) static var tickInterval: Duration = .seconds(30)

    private(set) var schedules: [IDEAgentSchedule] = []
    /// The runs this project's schedules started, newest first (`IDEAgentScheduleRunLog`).
    private(set) var runs: [IDEAgentScheduleRun] = []
    @ObservationIgnored private let store: SessionStore?
    @ObservationIgnored private(set) var root: String?
    @ObservationIgnored private var watchingSince = Date()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored weak var controller: IDEAgentController?

    init(store: SessionStore?) {
        self.store = store
    }

    func start() {
        guard store != nil, task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func tick(now: Date = Date()) {
        syncProject(now: now)
        guard let controller, root != nil else { return }
        var changed = false
        for index in schedules.indices {
            switch IDEAgentScheduleTiming.decide(schedules[index], now: now, watchingSince: watchingSince) {
            case .notDue:
                continue
            case .run:
                run(at: index, now: now)
                changed = true
            case .missed(let due):
                schedules[index].lastRunAt = now
                schedules[index].lastNote = "Missed the run due \(Self.describe(due)) while the project was not open; offered in a chat."
                controller.offerMissedScheduledRun(schedules[index], due: due)
                changed = true
            }
        }
        if changed { save() }
    }

    /// Follows the window's project: another project's schedules are loaded, and its watch starts now.
    private func syncProject(now: Date) {
        guard let store, let controller else { return }
        let current = controller.projectRoot?.standardizedFileURL.path
        guard current != root else { return }
        root = current
        watchingSince = now
        schedules = current.map { IDEAgentScheduleFile.load(store: store, projectRoot: $0) } ?? []
        runs = current.map { IDEAgentScheduleRunLog.load(store: store, projectRoot: $0) } ?? []
    }

    private func run(at index: Int, now: Date) {
        guard let controller else { return }
        let schedule = schedules[index]
        schedules[index].lastRunAt = now
        // One run of a schedule at a time: a slow run is not stacked on.
        if let last = schedule.lastChatID,
           controller.conversations.contains(where: { $0.conversationID == last && ($0.isRunning || $0.isAwaitingUser) }) {
            schedules[index].lastNote = "Skipped \(Self.describe(now)): the previous run was still going."
            return
        }
        if let chat = controller.startScheduledRun(schedule, at: now) {
            schedules[index].lastChatID = chat.conversationID
            schedules[index].lastNote = nil
            runs = IDEAgentScheduleRunLog.started(
                IDEAgentScheduleRun(
                    scheduleID: schedule.id, scheduleName: schedule.name, conversationID: chat.conversationID, startedAt: now),
                in: runs)
            saveRuns()
        } else {
            schedules[index].lastNote = "Could not start \(Self.describe(now)): the model is not set up, or sending to it was not allowed yet."
        }
    }

    // MARK: - Changes from the user

    func add(_ schedule: IDEAgentSchedule) {
        // Before the first tick of a project, its saved schedules are read first, so none is written over.
        syncProject(now: Date())
        schedules.append(schedule)
        save()
    }

    func remove(_ id: UUID) {
        syncProject(now: Date())
        schedules.removeAll { $0.id == id }
        save()
    }

    func setPaused(_ paused: Bool, id: UUID) {
        syncProject(now: Date())
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[index].isPaused = paused
        // Resuming counts from now, so a paused hour is not made up at once.
        if !paused { schedules[index].lastRunAt = Date() }
        save()
    }

    func runNow(_ id: UUID) {
        syncProject(now: Date())
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        run(at: index, now: Date())
        save()
    }

    /// A chat's run ended; if it was one a schedule started, its ending goes in the run log.
    func runEnded(
        conversationID: UUID, ending: RunEnding, filesChanged: Int, cost: Double?, iterationLimit: Int, at date: Date = Date()
    ) {
        guard let updated = IDEAgentScheduleRunLog.ended(
            conversationID: conversationID, ending: ending, at: date, filesChanged: filesChanged, cost: cost,
            iterationLimit: iterationLimit, in: runs)
        else { return }
        runs = updated
        saveRuns()
    }

    private func saveRuns() {
        guard let store, let root else { return }
        IDEAgentScheduleRunLog.save(runs, store: store, projectRoot: root)
    }

    private func save() {
        guard let store, let root else { return }
        IDEAgentScheduleFile.save(schedules, store: store, projectRoot: root)
    }

    nonisolated static func describe(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    /// "every 5 min", "every 2 h", "every day".
    nonisolated static func describe(interval: TimeInterval) -> String {
        if interval.truncatingRemainder(dividingBy: 86_400) == 0 {
            let days = Int(interval / 86_400)
            return days == 1 ? "every day" : "every \(days) days"
        }
        if interval.truncatingRemainder(dividingBy: 3_600) == 0 { return "every \(Int(interval / 3_600)) h" }
        return "every \(Int((interval / 60).rounded())) min"
    }
}
