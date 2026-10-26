import Foundation

/// Saves a window's unsaved files once typing has paused (IntelliJ's "Save files if the IDE is idle
/// for N seconds"). Typing costs one counter increment: `noteEdit()` never schedules per keystroke.
/// One task sleeps for the idle time, looks whether anything was typed meanwhile and either waits
/// another period or saves, then goes quiet until the next edit.
@MainActor
final class IDEAutosaveController {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    struct Settings: Equatable {
        /// Whether the idle trigger is on.
        var isEnabled = true
        /// How long typing must pause.
        var idleDelay: Duration = .seconds(15)
    }

    /// Read at every edit and every wake-up, so a change in Settings applies to the wait in progress.
    var settings: @MainActor () -> Settings = { Settings() }
    /// False while saving would be unwelcome (an input method composition, an open sheet). The save
    /// waits one more idle period and asks again.
    var canSaveNow: @MainActor () -> Bool = { true }
    /// What an idle pause does: save every unsaved file.
    var save: @MainActor () async -> Void = {}

    private let sleeper: Sleeper
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    init(sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }) {
        self.sleeper = sleeper
    }

    /// A document changed. Cheap: it runs for every keystroke.
    func noteEdit() {
        guard settings().isEnabled else { return }
        generation &+= 1
        if task == nil { startWaiting() }
    }

    /// Stops waiting; an edit afterwards starts again.
    func cancel() {
        task?.cancel()
        task = nil
    }

    private func startWaiting() {
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                let seen = self.generation
                let delay = self.settings().idleDelay
                let sleeper = self.sleeper
                do { try await sleeper(delay) } catch { return }
                guard !Task.isCancelled, self.settings().isEnabled else { break }
                // Typed meanwhile, or not a good moment: wait another full period.
                guard self.generation == seen, self.canSaveNow() else { continue }
                await self.save()
                // Typed while the files were being written: the new edits get their own period.
                guard self.generation == seen else { continue }
                break
            }
            self?.task = nil
        }
    }
}
