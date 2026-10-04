import AgentKit
import Foundation

/// The original texts of the files an agent run changed, kept on disk next to the conversation so
/// the run can still be reverted after a relaunch: `<project folder>/blobs/<run id>/<file>`, one file
/// per changed file, compressed, readable by the user alone. They are file contents like any other
/// in the project, so they stay on this Mac.
struct IDEAgentCheckpointBlobs: CheckpointBlobStore {
    /// 500 MB per project, enforced by `prune`: the oldest runs go first.
    static let defaultLimit = 500_000_000

    let directory: URL

    init(directory: URL) { self.directory = directory }

    /// For a project's conversations in `store`.
    init(store: SessionStore, projectRoot: String) {
        directory = store.projectDirectory(for: projectRoot).appendingPathComponent("blobs", isDirectory: true)
    }

    func put(_ text: String, run: RunID, path: String) {
        let folder = runDirectory(run)
        let manager = FileManager.default
        guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil,
              let compressed = try? (Data(text.utf8) as NSData).compressed(using: .lzfse) as Data
        else { return }
        let file = folder.appendingPathComponent(Self.fileName(for: path))
        guard (try? compressed.write(to: file, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func get(run: RunID, path: String) -> String? {
        let file = runDirectory(run).appendingPathComponent(Self.fileName(for: path))
        guard let data = try? Data(contentsOf: file), let plain = try? (data as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    func removeRun(_ run: RunID) {
        try? FileManager.default.removeItem(at: runDirectory(run))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    func hasRun(_ run: RunID) -> Bool {
        FileManager.default.fileExists(atPath: runDirectory(run).path)
    }

    /// Deletes the oldest runs until what is left fits in `limit` bytes. Runs in `keeping` stay.
    @discardableResult
    func prune(limit: Int = defaultLimit, keeping: Set<RunID> = []) -> [RunID] {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return [] }
        var runs: [(id: RunID, url: URL, date: Date, bytes: Int)] = folders.compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (id, url, date, Self.size(of: url))
        }
        var total = runs.reduce(0) { $0 + $1.bytes }
        guard total > limit else { return [] }
        runs.sort { $0.date < $1.date }
        var removed: [RunID] = []
        for run in runs where total > limit && !keeping.contains(run.id) {
            try? manager.removeItem(at: run.url)
            total -= run.bytes
            removed.append(run.id)
        }
        return removed
    }

    private func runDirectory(_ run: RunID) -> URL {
        directory.appendingPathComponent(run.uuidString, isDirectory: true)
    }

    /// The path made safe as a file name: letters and digits kept, everything else percent-encoded, and a
    /// long one shortened with a hash of the whole.
    static func fileName(for path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))) ?? "file"
        guard encoded.count > 180 else { return encoded }
        return String(encoded.prefix(120)) + "-" + String(CheckpointLog.hash(of: path), radix: 16)
    }

    private static func size(of folder: URL) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
