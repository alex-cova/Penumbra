import Foundation

/// One MCP server the agent may use: a program that speaks MCP on its standard input and output.
/// AgentKit never starts it; the host does, after the user has said yes.
public struct MCPServerConfig: Sendable, Hashable, Codable, Identifiable {
    /// What the user calls it. Tool names are built from `identifier`.
    public var name: String
    /// An executable path, or a bare name the host finds on `PATH`.
    public var command: String
    public var args: [String]
    /// Extra environment for the process. May hold secrets: shown to nobody, never put in a tool name.
    public var env: [String: String]

    public init(name: String, command: String, args: [String] = [], env: [String: String] = [:]) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }

    public var id: String { name }

    /// The name as it appears in tool names: letters, digits, `-` and `_`, at most 24 characters.
    public var identifier: String { MCPNaming.sanitize(name, limit: 24) }

    /// Everything that decides what would run, in one stable text. A host hashes it to remember that
    /// the user trusted exactly this: change the command, an argument or the environment and it differs.
    public var canonicalText: String {
        var parts = ["name=\(name)", "command=\(command)"]
        parts += args.map { "arg=\($0)" }
        parts += env.keys.sorted().map { "env=\($0)=\(env[$0] ?? "")" }
        return parts.joined(separator: "\u{0}")
    }

    /// The command line as the user would read it.
    public var displayCommand: String {
        ([command] + args).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}

/// An `.mcp.json` style file: `{"mcpServers": {"name": {"command": "npx", "args": [...], "env": {...}}}}`
/// (Claude Code, Cursor), or `{"servers": {...}}` (VS Code). Servers that are not a local program are
/// reported, not dropped silently.
public struct MCPConfigFile: Sendable, Equatable {
    public var servers: [MCPServerConfig]
    /// A server the file lists that this version cannot use, and why.
    public var skipped: [(name: String, reason: String)]

    public static func == (lhs: MCPConfigFile, rhs: MCPConfigFile) -> Bool {
        lhs.servers == rhs.servers && lhs.skipped.map(\.name) == rhs.skipped.map(\.name)
            && lhs.skipped.map(\.reason) == rhs.skipped.map(\.reason)
    }

    public static let maxServers = 32
    public static let maxFileBytes = 256_000

    public enum ParseError: Error, Equatable, LocalizedError {
        case notJSON
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .notJSON: "The file is not valid JSON."
            case .tooLarge: "The file is too large to be an MCP configuration."
            }
        }
    }

    public static func parse(_ data: Data) throws -> MCPConfigFile {
        guard data.count <= maxFileBytes else { throw ParseError.tooLarge }
        guard let root = try? JSONValue(parsing: String(decoding: data, as: UTF8.self)), case .object = root else {
            throw ParseError.notJSON
        }
        guard let table = (root["mcpServers"] ?? root["servers"])?.objectValue else {
            return MCPConfigFile(servers: [], skipped: [])
        }
        var servers: [MCPServerConfig] = []
        var skipped: [(name: String, reason: String)] = []
        for name in table.keys.sorted().prefix(maxServers) {
            guard let entry = table[name]?.objectValue else {
                skipped.append((name, "The entry is not an object."))
                continue
            }
            let type = entry["type"]?.stringValue?.lowercased()
            if entry["url"] != nil || (type != nil && type != "stdio") {
                skipped.append((name, "It connects over \(type ?? "HTTP"), and this version only starts local programs."))
                continue
            }
            guard let command = entry["command"]?.stringValue?.trimmingCharacters(in: .whitespaces), !command.isEmpty else {
                skipped.append((name, "It has no command."))
                continue
            }
            let args = (entry["args"]?.arrayValue ?? []).compactMap { $0.stringValue }
            var env: [String: String] = [:]
            for (key, value) in entry["env"]?.objectValue ?? [:] { if let text = value.stringValue { env[key] = text } }
            servers.append(MCPServerConfig(name: name, command: command, args: args, env: env))
        }
        return MCPConfigFile(servers: servers, skipped: skipped)
    }
}

enum MCPNaming {
    /// Letters, digits, `-` and `_` only (what both APIs accept in a tool name), cut to `limit`.
    static func sanitize(_ text: String, limit: Int) -> String {
        let mapped = text.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" }
        let cleaned = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let result = String(cleaned.prefix(limit))
        return result.isEmpty ? "server" : result
    }

    /// `mcp__<server>__<tool>`, at most 64 characters. A tool name that does not fit keeps its start
    /// and ends with a short hash of the full name, so two long names stay different.
    static func toolName(server: String, tool: String) -> String {
        let prefix = "mcp__\(server)__"
        let room = 64 - prefix.count
        let cleaned = sanitize(tool, limit: .max)
        if cleaned.count <= room, cleaned == tool { return prefix + cleaned }
        let hash = String(ReadLedger.hash(tool), radix: 16).prefix(6)
        if cleaned.count + 7 <= room, cleaned != tool { return prefix + cleaned + "_" + hash }
        return prefix + String(cleaned.prefix(max(1, room - 7))) + "_" + hash
    }
}
