import Foundation

/// A conversation as it is kept on disk. It holds the history and the host's own state (Umbra's
/// transcript), and never a credential: provider settings and keys live elsewhere.
/// One child subagent as it is kept on disk with its parent: enough to continue it by its
/// session id after a relaunch. The agent is named (resolved through the host's catalog on
/// restore; a child whose agent is gone is dropped), and `items`/`totalUsage` restore its
/// conversation and budget accounting.
public struct ChildSnapshot: Codable, Sendable, Equatable {
    public var id: String
    public var agent: String
    public var description: String
    public var canEdit: Bool
    public var items: [ConversationItem]
    public var totalUsage: TokenUsage

    public init(
        id: String, agent: String, description: String, canEdit: Bool,
        items: [ConversationItem], totalUsage: TokenUsage = TokenUsage()
    ) {
        self.id = id
        self.agent = agent
        self.description = description
        self.canEdit = canEdit
        self.items = items
        self.totalUsage = totalUsage
    }
}

public struct SessionSnapshot: Codable, Sendable, Equatable, Identifiable {
    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    public var projectRoot: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var items: [ConversationItem]
    public var totalUsage: TokenUsage
    /// Whatever the host needs to bring its own UI back; opaque to the session.
    public var host: Data?
    /// Children that can be continued by session id after a relaunch. Missing in old files.
    public var children: [ChildSnapshot]

    public init(
        id: UUID = UUID(), projectRoot: String, title: String, createdAt: Date = Date(), updatedAt: Date = Date(),
        items: [ConversationItem], totalUsage: TokenUsage = TokenUsage(), host: Data? = nil,
        children: [ChildSnapshot] = []
    ) {
        self.version = Self.currentVersion
        self.id = id
        self.projectRoot = projectRoot
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.items = items
        self.totalUsage = totalUsage
        self.host = host
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, projectRoot, title, createdAt, updatedAt, items, totalUsage, host, children
    }

    public init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        version = try box.decode(Int.self, forKey: .version)
        id = try box.decode(UUID.self, forKey: .id)
        projectRoot = try box.decode(String.self, forKey: .projectRoot)
        title = try box.decode(String.self, forKey: .title)
        createdAt = try box.decode(Date.self, forKey: .createdAt)
        updatedAt = try box.decode(Date.self, forKey: .updatedAt)
        items = try box.decode([ConversationItem].self, forKey: .items)
        totalUsage = try box.decode(TokenUsage.self, forKey: .totalUsage)
        host = try box.decodeIfPresent(Data.self, forKey: .host)
        children = try box.decodeIfPresent([ChildSnapshot].self, forKey: .children) ?? []
    }
}

/// What a history menu needs, without reading every conversation in full.
public struct SessionSummary: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    /// User messages in the conversation. Tool calls and the model's replies are not counted.
    public let messageCount: Int
    /// Dollars recorded in the host blob's `cost` field, when the host saved one.
    public let cost: Double?
    /// The project the conversation belongs to, as saved in the snapshot.
    public let projectRoot: String?

    public init(
        id: UUID, title: String, updatedAt: Date, messageCount: Int = 0, cost: Double? = nil, projectRoot: String? = nil
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.cost = cost
        self.projectRoot = projectRoot
    }
}

/// Sessions on disk: `<directory>/<hash of project root>/<session id>.json`. Conversations contain
/// file contents, so they stay on this Mac, readable by the user alone.
public struct SessionStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/<app folder>/Agent`.
    public static func defaultDirectory(appFolder: String) throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(appFolder, isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
    }

    public func projectDirectory(for projectRoot: String) -> URL {
        let key = String(ReadLedger.hash(URL(fileURLWithPath: projectRoot).standardizedFileURL.path), radix: 16)
        return directory.appendingPathComponent(key, isDirectory: true)
    }

    private func file(_ id: UUID, in projectRoot: String) -> URL {
        projectDirectory(for: projectRoot).appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Attached images

    /// Media types the composer accepts. Anything else is refused before it reaches the session.
    public static let imageMediaTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]
    /// An attached image is downscaled by the composer; anything still larger is refused.
    public static let maxImageBytes = 10_000_000

    /// `<project dir>/<session id>.images/`: beside the session JSON, never inline in it.
    public func imageDirectory(for id: UUID, projectRoot: String) -> URL {
        projectDirectory(for: projectRoot).appendingPathComponent("\(id.uuidString).images", isDirectory: true)
    }

    private static func imageExtension(for mediaType: String) -> String? {
        switch mediaType.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return nil
        }
    }

    public static func mediaType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    /// Writes image bytes beside the session (0600) and returns the id `UserPart.image` names.
    /// Throws when the media type is not an accepted image or the bytes are too large.
    @discardableResult
    public func saveImage(_ data: Data, mediaType: String, sessionID: UUID, projectRoot: String) throws -> String {
        guard let ext = Self.imageExtension(for: mediaType) else {
            throw AgentWorkspaceError.writeFailed(path: "image", reason: "Unsupported image type \(mediaType).")
        }
        guard data.count <= Self.maxImageBytes else {
            throw AgentWorkspaceError.tooLarge(path: "image", bytes: data.count)
        }
        let folder = imageDirectory(for: sessionID, projectRoot: projectRoot)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID().uuidString
        let url = folder.appendingPathComponent("\(id).\(ext)")
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return id
    }

    /// The bytes (and media type) for an attached image, or `nil` when the file is gone.
    public func loadImage(id: String, sessionID: UUID, projectRoot: String) -> (mediaType: String, data: Data)? {
        let folder = imageDirectory(for: sessionID, projectRoot: projectRoot)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let url = files.first(where: { $0.deletingPathExtension().lastPathComponent == id }) else { return nil }
        guard let mediaType = Self.mediaType(forExtension: url.pathExtension),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return (mediaType, data)
    }

    /// Loads every attached image of a session that is still on disk, keyed by id.
    public func loadImages(ids: [String], sessionID: UUID, projectRoot: String) -> [String: LLMImage] {
        var result: [String: LLMImage] = [:]
        for id in ids {
            guard let (mediaType, data) = loadImage(id: id, sessionID: sessionID, projectRoot: projectRoot) else { continue }
            result[id] = LLMImage(id: id, mediaType: mediaType, data: data)
        }
        return result
    }

    public func deleteImages(sessionID: UUID, projectRoot: String) {
        try? FileManager.default.removeItem(at: imageDirectory(for: sessionID, projectRoot: projectRoot))
    }

    public func save(_ snapshot: SessionSnapshot) throws {
        let folder = projectDirectory(for: snapshot.projectRoot)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = file(snapshot.id, in: snapshot.projectRoot)
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// `nil` when the file is missing, unreadable, or from a newer version this build can't read.
    public func load(_ id: UUID, projectRoot: String) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: file(id, in: projectRoot)) else { return nil }
        return decode(data)
    }

    /// Newest first. A file that can't be read is skipped, not fatal.
    public func list(projectRoot: String) -> [SessionSummary] {
        let folder = projectDirectory(for: projectRoot)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap(summary(at:))
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The newest conversations of every project, newest first, for a list that is not tied to one
    /// folder. Conversations can be large, so only the `limit` most recently written files are read,
    /// and a file whose summary is in `previous` and has not been written since is not read again
    /// (a list that refreshes whenever a chat is saved would otherwise decode every conversation each time).
    public func listAll(limit: Int = 100, reusing previous: [SessionSummary] = []) -> [SessionSummary] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let folders = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        var candidates: [(url: URL, modified: Date)] = []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            // One level only: `blobs/` and any other subfolder hold checkpoint data, not conversations.
            for url in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            where url.pathExtension == "json" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                candidates.append((url, modified))
            }
        }
        let known = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(max(0, limit))
            .compactMap { candidate -> SessionSummary? in
                // The file is named after the session id, and `updatedAt` is stamped when it is written.
                if let id = UUID(uuidString: candidate.url.deletingPathExtension().lastPathComponent),
                   let earlier = known[id], abs(earlier.updatedAt.timeIntervalSince(candidate.modified)) < 2 {
                    return earlier
                }
                return summary(at: candidate.url)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func summary(at url: URL) -> SessionSummary? {
        guard let data = try? Data(contentsOf: url), let snapshot = decode(data) else { return nil }
        return SessionSummary(
            id: snapshot.id, title: snapshot.title, updatedAt: snapshot.updatedAt,
            messageCount: snapshot.items.reduce(into: 0) { count, item in if item.isUserTurn { count += 1 } },
            cost: Self.cost(in: snapshot.host), projectRoot: snapshot.projectRoot)
    }

    public func delete(_ id: UUID, projectRoot: String) {
        try? FileManager.default.removeItem(at: file(id, in: projectRoot))
        deleteImages(sessionID: id, projectRoot: projectRoot)
    }

    /// "Clear History": every conversation of one project.
    public func deleteAll(projectRoot: String) {
        try? FileManager.default.removeItem(at: projectDirectory(for: projectRoot))
    }

    /// The host blob is opaque. A number under `cost` is what a history row shows; anything else is none.
    static func cost(in host: Data?) -> Double? {
        guard let host, let object = try? JSONSerialization.jsonObject(with: host) as? [String: Any] else { return nil }
        return (object["cost"] as? NSNumber)?.doubleValue
    }

    private func decode(_ data: Data) -> SessionSnapshot? {
        Self.decode(data)
    }

    /// Reads back a snapshot from bytes, including an `/export json` file: `nil` when the data is
    /// not a snapshot this build can read.
    public static func decode(_ data: Data) -> SessionSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(SessionSnapshot.self, from: data),
              snapshot.version <= SessionSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    /// The block a host puts in front of each user message to describe the editor's state; not part of what the user typed.
    public static let editorStateEnd = "[End editor state]"

    /// A short title from the first thing the user asked.
    public static func title(from items: [ConversationItem]) -> String {
        for item in items {
            guard let text = item.userText, let typed = UserText.typed(text) else { continue }
            let line = typed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            if !line.isEmpty { return line.count > 60 ? String(line.prefix(60)) + "…" : line }
        }
        return "New conversation"
    }
}
