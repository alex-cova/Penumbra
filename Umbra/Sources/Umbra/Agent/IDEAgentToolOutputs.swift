import AgentKit
import Foundation

/// Tool output too large to show the model, kept on disk beside the conversation so `read_tool_output`
/// can page through it: `<project folder>/tool-output/<conversation id>/<output id>`, compressed, readable
/// by the user alone. It is command output and diffs like any other in the project, so it stays on this
/// Mac. Kept for a week, and 100 MB per project at most (the oldest go first); a deleted conversation
/// takes its outputs with it.
struct IDEAgentToolOutputs: ToolOutputStore {
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let defaultLimit = 100_000_000

    /// The project's `tool-output` folder.
    let directory: URL
    let conversationID: UUID

    init(directory: URL, conversationID: UUID) {
        self.directory = directory
        self.conversationID = conversationID
    }

    init(store: SessionStore, projectRoot: String, conversationID: UUID) {
        self.init(
            directory: store.projectDirectory(for: projectRoot).appendingPathComponent("tool-output", isDirectory: true),
            conversationID: conversationID)
    }

    func save(_ text: String, id: String) -> Bool {
        guard ToolOutputID.isValid(id) else { return false }
        let manager = FileManager.default
        let folder = conversationDirectory
        guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil,
              let compressed = try? (Data(text.utf8) as NSData).compressed(using: .lzfse) as Data
        else { return false }
        let file = folder.appendingPathComponent(id)
        guard (try? compressed.write(to: file, options: .atomic)) != nil else { return false }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }

    /// This conversation's output first; then any other conversation of the project, since a fork or a
    /// reload carries the model's pointers into a conversation with a different id.
    func load(id: String) -> String? {
        guard ToolOutputID.isValid(id) else { return nil }
        let manager = FileManager.default
        var candidates = [conversationDirectory.appendingPathComponent(id)]
        if let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            candidates += folders.map { $0.appendingPathComponent(id) }
        }
        for file in candidates {
            guard let data = try? Data(contentsOf: file),
                  let plain = try? (data as NSData).decompressed(using: .lzfse) as Data
            else { continue }
            return String(data: plain, encoding: .utf8)
        }
        return nil
    }

    /// Deletes one conversation's outputs.
    func removeConversation() {
        try? FileManager.default.removeItem(at: conversationDirectory)
    }

    /// Deletes every conversation's outputs of the project.
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Drops what is older than a week, then the oldest of the rest until the project fits in `limit`
    /// bytes, and any conversation folder left empty. Cheap enough to run whenever a session starts.
    @discardableResult
    static func sweep(
        directory: URL, retention: TimeInterval = retention, limit: Int = defaultLimit, now: Date = Date()
    ) -> Int {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return 0 }
        var files: [(url: URL, date: Date, bytes: Int)] = []
        for folder in folders {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            for url in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [] {
                let values = try? url.resourceValues(forKeys: Set(keys))
                files.append((url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0))
            }
        }
        var removed = 0
        var kept: [(url: URL, date: Date, bytes: Int)] = []
        for file in files {
            if now.timeIntervalSince(file.date) > retention {
                try? manager.removeItem(at: file.url)
                removed += 1
            } else {
                kept.append(file)
            }
        }
        var total = kept.reduce(0) { $0 + $1.bytes }
        for file in kept.sorted(by: { $0.date < $1.date }) where total > limit {
            try? manager.removeItem(at: file.url)
            total -= file.bytes
            removed += 1
        }
        for folder in folders where ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty {
            try? manager.removeItem(at: folder)
        }
        return removed
    }

    private var conversationDirectory: URL {
        directory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }
}
