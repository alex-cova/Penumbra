import Foundation

/// A conversation as it is kept on disk. It holds the history and the host's own state (Umbra's
/// transcript), and never a credential: provider settings and keys live elsewhere.
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

    public init(
        id: UUID = UUID(), projectRoot: String, title: String, createdAt: Date = Date(), updatedAt: Date = Date(),
        items: [ConversationItem], totalUsage: TokenUsage = TokenUsage(), host: Data? = nil
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
    }
}

/// What a history menu needs, without reading every conversation in full.
public struct SessionSummary: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date

    public init(id: UUID, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
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
            .compactMap { url -> SessionSummary? in
                guard let data = try? Data(contentsOf: url), let snapshot = decode(data) else { return nil }
                return SessionSummary(id: snapshot.id, title: snapshot.title, updatedAt: snapshot.updatedAt)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(_ id: UUID, projectRoot: String) {
        try? FileManager.default.removeItem(at: file(id, in: projectRoot))
    }

    /// "Clear History": every conversation of one project.
    public func deleteAll(projectRoot: String) {
        try? FileManager.default.removeItem(at: projectDirectory(for: projectRoot))
    }

    private func decode(_ data: Data) -> SessionSnapshot? {
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
        for case .user(let text) in items {
            let typed = text.range(of: editorStateEnd).map { String(text[$0.upperBound...]) } ?? text
            let line = typed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
            if !line.isEmpty { return line.count > 60 ? String(line.prefix(60)) + "…" : line }
        }
        return "New conversation"
    }
}
