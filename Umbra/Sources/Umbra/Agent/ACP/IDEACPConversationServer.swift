import AgentKit
import Foundation

/// The `read_conversation` MCP server an external ACP agent gets after a handoff
/// (`docs/harness/agent-harness-10.md`): the `umbra-conversation-mcp` helper beside Umbra's binary, listed
/// in `session/new` / `session/load`'s `mcpServers`, over an archive file Umbra writes for the chat.
enum IDEACPConversationServer {
    static let helperName = "umbra-conversation-mcp"

    /// Where the helper is: next to the running binary (`Contents/MacOS` in the app, the build folder under
    /// `swift run`). Tests replace it.
    nonisolated(unsafe) static var locateHelper: () -> URL? = {
        guard let folder = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let helper = folder.appendingPathComponent(helperName)
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    /// The chat's archive: `<project folder>/handoff/<conversation id>.json` beside its saved conversation,
    /// or a temporary folder when nothing is saved (tests, no store).
    static func archiveURL(store: SessionStore?, projectRoot: String?, conversationID: UUID) -> URL {
        let folder: URL
        if let store, let projectRoot {
            folder = store.projectDirectory(for: projectRoot).appendingPathComponent("handoff", isDirectory: true)
        } else {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-handoff", isDirectory: true)
        }
        return folder.appendingPathComponent("\(conversationID.uuidString).json")
    }

    /// Writes the archive (0600, folder 0700). The helper reads it at every call, so a later handoff only
    /// rewrites the file. False when it could not be written; the agent then gets no server.
    @discardableResult
    static func write(_ turns: [HandoffTurn], to url: URL) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(turns).write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// The `mcpServers` entry (ACP's stdio form: name, command, args, env).
    static func entry(helper: URL, archive: URL) -> JSONValue {
        .object([
            "name": .string(MCPConversationServer.serverName),
            "command": .string(helper.path),
            "args": .array([.string(archive.path)]),
            "env": .array([]),
        ])
    }

    static func removeArchive(store: SessionStore, projectRoot: String, conversationID: UUID) {
        try? FileManager.default.removeItem(at: archiveURL(store: store, projectRoot: projectRoot, conversationID: conversationID))
    }

    static func removeAll(store: SessionStore, projectRoot: String) {
        try? FileManager.default.removeItem(
            at: store.projectDirectory(for: projectRoot).appendingPathComponent("handoff", isDirectory: true))
    }
}
