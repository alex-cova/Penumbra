import Foundation
import Observation

/// What Umbra does when a file open in a text tab changes on disk (Settings ▸ Editor ▸ External
/// Changes). A buffer with unsaved edits is never replaced without asking, whatever the policy.
enum IDEExternalChangePolicy: String, CaseIterable, Identifiable, Sendable {
    /// A clean tab reloads silently; a dirty one gets the banner.
    case always
    /// Every changed tab gets the banner and reloads only when asked.
    case prompt
    /// Nothing reloads and no banner appears; a notification says the file changed. Saving over
    /// the newer file still asks first.
    case never

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .always: "Reload Automatically"
        case .prompt: "Ask"
        case .never: "Never Reload"
        }
    }
}

/// The banner a text tab shows for its file.
enum IDEExternalChangeState: Equatable, Sendable {
    case none
    /// The disk holds other bytes than the buffer was loaded or saved from.
    case changedOnDisk
    case deletedOnDisk
}

/// Keeps open text buffers in step with their files. It watches nothing itself: the window's
/// ``IDEProjectWatcher`` reports paths and ``handle(paths:)`` judges them by content against the
/// snapshot taken when the buffer was loaded, reloaded or saved. Language-agnostic: it sees paths
/// and asks the workspace, through closures, whether a buffer is dirty and how to reload it.
@MainActor
@Observable
final class IDEOpenDocumentDiskSync {
    private(set) var states: [String: IDEExternalChangeState] = [:]

    /// The policy in force, read at each change.
    @ObservationIgnored var policy: () -> IDEExternalChangePolicy = { .always }
    /// Whether the open text buffer for a path has unsaved edits; nil when none is open.
    @ObservationIgnored var isDirty: (String) -> Bool? = { _ in nil }
    /// Replaces a clean buffer with the disk's text. Must end in ``noteReloaded(path:)``.
    @ObservationIgnored var reload: (String) async -> Void = { _ in }
    /// Tells the user a file changed (`deleted: false`) or went away, under ``IDEExternalChangePolicy/never``.
    @ObservationIgnored var notify: (_ path: String, _ deleted: Bool) -> Void = { _, _ in }

    private struct Entry {
        /// The disk as the buffer last matched it. Nil when the file did not exist.
        var baseline: DiskSnapshot?
        /// A baseline being read (on open, after a save or a reload). Judging waits for it, so
        /// the event of Umbra's own save compares against what that save wrote.
        var pendingBaseline: Task<DiskSnapshot?, Never>?
        /// Disk bytes the user chose to keep their buffer over (Keep Mine), or was told about under
        /// `never`. The same bytes don't raise anything again.
        var dismissed: DiskSnapshot?
        /// Keep Mine's read of the disk, still running. The save check and judging wait for it.
        var pendingDismissal: Task<DiskSnapshot?, Never>?
        var isReconciling = false
        var needsAnotherPass = false
    }

    @ObservationIgnored private var entries: [String: Entry] = [:]

    var openPaths: Set<String> { Set(entries.keys) }

    func state(for path: String?) -> IDEExternalChangeState {
        path.flatMap { states[$0] } ?? .none
    }

    // MARK: Registration

    /// The standardized paths of the text tabs that have a file. New paths get a baseline read
    /// from disk; closed ones are forgotten.
    func setOpenFiles(_ paths: Set<String>) {
        guard paths.count != entries.count || !paths.allSatisfy({ entries[$0] != nil }) else { return }
        for path in entries.keys where !paths.contains(path) {
            entries[path]?.pendingBaseline?.cancel()
            entries[path] = nil
            states[path] = nil
        }
        for path in paths where entries[path] == nil {
            entries[path] = Entry()
            refreshBaseline(path)
        }
    }

    /// Umbra wrote the file: what is on disk now is what the buffer holds.
    func noteSaved(path: String) {
        guard entries[path] != nil else { return }
        entries[path]?.pendingDismissal?.cancel()
        entries[path]?.pendingDismissal = nil
        entries[path]?.dismissed = nil
        states[path] = nil
        refreshBaseline(path)
    }

    /// The buffer was replaced with the disk's text.
    func noteReloaded(path: String) {
        noteSaved(path: path)
    }

    /// Keep Mine: the buffer stays, and these disk bytes raise nothing again. The next save still
    /// writes over them without asking, since the user has seen them.
    func keepMine(path: String) {
        guard entries[path] != nil else { return }
        states[path] = nil
        let task = Task.detached(priority: .userInitiated) { DiskSnapshot.captureNow(url: URL(fileURLWithPath: path)) }
        entries[path]?.pendingDismissal = task
        Task {
            let snapshot = await task.value
            guard entries[path]?.pendingDismissal == task else { return }
            entries[path]?.dismissed = snapshot
            entries[path]?.pendingDismissal = nil
        }
    }

    /// Keep Mine's snapshot, waiting for it when it is still being read.
    private func dismissedSnapshot(_ path: String) async -> DiskSnapshot? {
        if let pending = entries[path]?.pendingDismissal { return await pending.value }
        return entries[path]?.dismissed
    }

    /// A save refused because the disk is newer (the agent's saves never ask): show the banner.
    func noteConflict(path: String) {
        guard entries[path] != nil else { return }
        states[path] = .changedOnDisk
    }

    /// Keep Editing a deleted file: the banner goes, the buffer stays; a save recreates the file.
    func dismissDeleted(path: String) {
        states[path] = nil
    }

    // MARK: Changes

    /// A batch of paths the watcher reported. Only open files are looked at.
    func handle(paths: Set<String>) {
        for path in entries.keys where paths.contains(path) {
            reconcile(path)
        }
    }

    /// Whether the file differs from what the buffer was loaded from, ignoring bytes the user
    /// already kept their buffer over. A missing file is not a conflict: saving recreates it.
    func diskChangedSinceLoad(path: String) async -> Bool {
        guard let entry = entries[path] else { return false }
        let baseline = await entry.pendingBaseline?.value ?? entry.baseline
        guard let current = await DiskSnapshot.capture(url: URL(fileURLWithPath: path)) else { return false }
        if let dismissed = await dismissedSnapshot(path), dismissed.sameContent(as: current) { return false }
        guard let baseline else { return true }
        return !baseline.sameContent(as: current)
    }

    private func refreshBaseline(_ path: String) {
        entries[path]?.pendingBaseline?.cancel()
        let task = Task.detached(priority: .utility) { DiskSnapshot.captureNow(url: URL(fileURLWithPath: path)) }
        entries[path]?.pendingBaseline = task
        Task {
            let snapshot = await task.value
            guard entries[path]?.pendingBaseline == task else { return }
            entries[path]?.baseline = snapshot
            entries[path]?.pendingBaseline = nil
        }
    }

    /// One pass at a time per path; events during a pass run one more after it.
    private func reconcile(_ path: String) {
        guard entries[path] != nil else { return }
        if entries[path]?.isReconciling == true {
            entries[path]?.needsAnotherPass = true
            return
        }
        entries[path]?.isReconciling = true
        Task {
            repeat {
                entries[path]?.needsAnotherPass = false
                await judge(path)
            } while entries[path]?.needsAnotherPass == true
            entries[path]?.isReconciling = false
        }
    }

    private func judge(_ path: String) async {
        guard let entry = entries[path] else { return }
        let baseline: DiskSnapshot?
        if let pending = entry.pendingBaseline {
            baseline = await pending.value
        } else {
            baseline = entry.baseline
        }
        let current = await DiskSnapshot.capture(url: URL(fileURLWithPath: path))
        guard entries[path] != nil, let dirty = isDirty(path) else { return }

        guard let current else {
            guard baseline != nil, states[path] != .deletedOnDisk else { return }
            if policy() == .never {
                notify(path, true)
                entries[path]?.baseline = nil
            } else {
                states[path] = .deletedOnDisk
            }
            return
        }
        if let baseline, baseline.sameContent(as: current) {
            // Touched, or edited and put back: nothing to show.
            states[path] = nil
            return
        }
        if let dismissed = await dismissedSnapshot(path), dismissed.sameContent(as: current) { return }
        guard entries[path] != nil else { return }

        switch policy() {
        case .always where !dirty:
            await reload(path)
        case .always, .prompt:
            states[path] = .changedOnDisk
        case .never:
            entries[path]?.dismissed = current
            states[path] = nil
            notify(path, false)
        }
    }
}
