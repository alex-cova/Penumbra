import AgentKit
import Foundation
import Observation

/// The window's way of keeping Local History: it turns "this file was saved / opened / written by an
/// agent" into revisions in the project's `IDELocalHistoryStore` without ever making the main thread
/// wait. A save is noted by reading the file back off the main thread once it is on disk, so no text
/// is copied from the editor and a large file costs the typing path nothing.
@MainActor
@Observable
final class IDELocalHistoryRecorder {
    /// Bumped whenever something was recorded or changed, so views showing history refresh.
    private(set) var revision = 0
    private(set) var store: IDELocalHistoryStore?

    @ObservationIgnored private var baseDirectory: URL?
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var lastPruneKey = "umbra.localHistory.lastPrune"

    /// Where histories live: `<Application Support>/com.umbra.editor/LocalHistory`.
    static func defaultDirectory() -> URL? {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("LocalHistory", isDirectory: true)
    }

    /// Without a base directory nothing is recorded (tests, a window with persistence off).
    func enable(baseDirectory: URL?) {
        self.baseDirectory = baseDirectory
        setRoot(root)
    }

    var isEnabled: Bool { baseDirectory != nil }
    var projectRoot: URL? { root }

    /// Points the recorder at a project's history, or at none.
    func setRoot(_ url: URL?) {
        root = url
        guard let baseDirectory, let url else {
            store = nil
            return
        }
        let key = String(CheckpointLog.hash(of: url.standardizedFileURL.path), radix: 16)
        store = IDELocalHistoryStore(directory: baseDirectory.appendingPathComponent(key, isDirectory: true))
        pruneOncePerDay()
    }

    /// Project-relative, or `nil` for a file outside the project.
    func relativePath(of url: URL) -> String? {
        guard let root = root?.standardizedFileURL.path else { return nil }
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }

    // MARK: - Recording

    /// A file was saved: its text on disk is a new revision.
    func recordSaved(_ url: URL, source: IDELocalHistorySource = .save) {
        record(url) { store, path, text in await store.record(path: path, text: text, source: source) != nil }
    }

    /// A file was opened: if nothing is known about it yet, what is on disk now is where its history starts.
    func recordBaseline(_ url: URL) {
        record(url) { store, path, text in
            guard let text else { return false }
            return await store.recordBaseline(path: path, text: text)
        }
    }

    /// Something else changed these files on disk (git, another tool). Only a file that already has
    /// history is looked at, so a build writing thousands of files is not read, and at most `limit` per batch.
    func recordExternalChanges(_ paths: Set<String>, limit: Int = 40) {
        guard store != nil else { return }
        for path in paths.sorted().prefix(limit) {
            let url = URL(fileURLWithPath: path)
            guard relativePath(of: url) != nil else { continue }
            record(url) { store, relative, text in
                guard await store.hasHistory(forPath: relative) else { return false }
                return await store.record(path: relative, text: text, source: .external) != nil
            }
        }
    }

    /// Reads `url` off the main thread and hands the text to `body`; bumps `revision` if `body` says something was recorded.
    private func record(_ url: URL, _ body: @escaping @Sendable (IDELocalHistoryStore, String, String?) async -> Bool) {
        guard let store, let path = relativePath(of: url) else { return }
        Task { [weak self] in
            let text = await Task.detached(priority: .utility) { () -> String? in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attributes[.size] as? Int, size <= IDELocalHistoryStore.maxFileBytes
                else { return nil }
                return try? String(contentsOf: url, encoding: .utf8)
            }.value
            // An unreadable file (binary, gone) is not a revision; a vanished one is recorded by `recordDeleted`.
            guard let text else { return }
            if await body(store, path, text) { self?.revision += 1 }
        }
    }

    /// A file was deleted.
    func recordDeleted(_ url: URL, source: IDELocalHistorySource) {
        guard let store, let path = relativePath(of: url) else { return }
        Task { [weak self] in
            if await store.record(path: path, text: nil, source: source) != nil { self?.revision += 1 }
        }
    }

    /// Text known to the caller, for writes that already hold it (an agent's edit, a restore).
    func record(
        path: String, text: String?, source: IDELocalHistorySource, group: UUID? = nil, before prior: String? = nil
    ) {
        guard let store else { return }
        Task { [weak self] in
            if await store.record(path: path, text: text, source: source, group: group, assumingBefore: prior) != nil { self?.revision += 1 }
        }
    }

    /// Pins the file's current text with a name.
    func putLabel(_ name: String, for url: URL, text: String) {
        guard let store, let path = relativePath(of: url) else { return }
        Task { [weak self] in
            if await store.putLabel(path: path, name: name, text: text) != nil { self?.revision += 1 }
        }
    }

    // MARK: - Keeping it small

    /// Once a day at most; age and size limits can be changed in the defaults (`umbra.localHistory.days`, `.megabytes`).
    private func pruneOncePerDay() {
        guard let store else { return }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: lastPruneKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3_600 else { return }
        defaults.set(Date(), forKey: lastPruneKey)
        let days = defaults.object(forKey: "umbra.localHistory.days") as? Double ?? 7
        let megabytes = defaults.object(forKey: "umbra.localHistory.megabytes") as? Int ?? 500
        Task { await store.prune(maxAge: days * 86_400, maxBytes: megabytes * 1_000_000) }
    }

    func clear() {
        guard let store else { return }
        Task { [weak self] in
            await store.clear()
            self?.revision += 1
        }
    }
}
