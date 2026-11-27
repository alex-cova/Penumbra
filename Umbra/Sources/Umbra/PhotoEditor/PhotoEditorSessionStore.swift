import Foundation

/// Autosaved edit recipes for the photo editor, ported from the reference
/// `PhotoEditorSessionStore`. Umbra keeps one JSON file keyed by file path (the reference kept a
/// single snapshot for its single open photo; Umbra edits many tabs). Security-scoped bookmark
/// handling is unchanged: files opened from outside the project sandbox need the bookmark to
/// re-resolve on restore.
struct PhotoEditorSessionStore {
    struct Snapshot: Codable, Sendable {
        var bookmark: Data
        var adjustments: EditAdjustment
    }

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("PhotoEditor", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    static func save(_ snapshot: Snapshot, forPath path: String, fileURL: URL = fileURL) {
        var snapshots = loadAll(fileURL: fileURL)
        snapshots[path] = snapshot
        persist(snapshots, fileURL: fileURL)
    }

    static func load(forPath path: String, fileURL: URL = fileURL) -> Snapshot? {
        loadAll(fileURL: fileURL)[path]
    }

    static func clear(forPath path: String, fileURL: URL = fileURL) {
        var snapshots = loadAll(fileURL: fileURL)
        snapshots.removeValue(forKey: path)
        persist(snapshots, fileURL: fileURL)
    }

    private static func loadAll(fileURL: URL) -> [String: Snapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Snapshot].self, from: data)) ?? [:]
    }

    private static func persist(_ snapshots: [String: Snapshot], fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshots)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort autosave; a failed write must never interrupt editing.
        }
    }

    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    struct ResolvedBookmark: Equatable, Sendable {
        var url: URL
        /// Bookmark data to persist. Refreshed when the original was stale but still resolvable.
        var bookmark: Data
        var wasStale: Bool
    }

    /// Resolves a security-scoped bookmark and begins access. Caller must eventually
    /// call `stopAccessingSecurityScopedResource()` on the returned URL. A still-resolvable
    /// stale bookmark is rewritten in `bookmark` so the next restore does not keep dead data.
    static func resolveBookmark(_ data: Data) -> ResolvedBookmark? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        let bookmark = persistedBookmark(original: data, isStale: isStale, refreshed: makeBookmark(for: url))
        return ResolvedBookmark(url: url, bookmark: bookmark, wasStale: isStale)
    }

    /// Stale-but-resolvable bookmarks are replaced when a fresh one can be created.
    static func persistedBookmark(original: Data, isStale: Bool, refreshed: Data?) -> Data {
        if isStale, let refreshed { return refreshed }
        return original
    }
}
