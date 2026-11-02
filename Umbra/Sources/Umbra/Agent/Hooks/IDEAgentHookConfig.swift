import AgentKit
import Foundation

/// When a user-configured hook runs. Phase 1 covers these three; `UserPromptSubmit`,
/// `SessionStart` and `Notification` come later.
enum IDEAgentHookEvent: String, Sendable, CaseIterable {
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case stop = "Stop"
}

/// One shell command from a `hooks` block, with the tool it applies to.
struct IDEAgentHookEntry: Sendable, Equatable {
    var event: IDEAgentHookEvent
    /// Which tools this applies to: empty matches all, otherwise `|`-separated tool names,
    /// regexes or globs over the tool name (see `IDEAgentHookMatcher`).
    var matcher: String
    var command: String
    var timeout: TimeInterval
    /// A required hook fails closed: a timeout or failure blocks (or, after a call, is shown)
    /// instead of warning and failing open.
    var required: Bool
    /// Which settings file listed it. App-level hooks are the user's own and need no prompt.
    var origin: IDEAgentPermissionFiles.Origin

    /// Whether this hook sees calls to `toolName`.
    func matches(toolName: String) -> Bool {
        IDEAgentHookMatcher.matches(matcher, tool: toolName)
    }
}

/// Matches a hook's `matcher` against a tool name. An alternative matches when it names the
/// tool exactly, names a Claude Code tool that covers it (the alias table, so an existing
/// `.claude/settings.json` matcher keeps working), or matches it as a regex or glob.
enum IDEAgentHookMatcher {
    /// Claude Code tool names understood in matchers, mapped to Umbra's tool names.
    static let aliases: [String: [String]] = [
        "Bash": ["run_command", "gradle", "maven", "project_task", "run_tests"],
        "Edit": ["edit_file", "write_file", "apply_patch"],
        "Write": ["edit_file", "write_file", "apply_patch"],
        "MultiEdit": ["edit_file", "write_file", "apply_patch"],
        "Read": ["read_file"],
        "Grep": ["grep"],
        "Glob": ["glob"],
    ]

    static func matches(_ matcher: String, tool: String) -> Bool {
        let trimmed = matcher.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "*" { return true }
        return trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { matchOne(String($0), tool: tool) }
    }

    private static func matchOne(_ alternative: String, tool: String) -> Bool {
        guard !alternative.isEmpty else { return false }
        if alternative == tool { return true }
        if let aliased = aliases[alternative], aliased.contains(tool) { return true }
        if alternative.contains("*") || alternative.contains("?"),
           let glob = try? GlobPattern(alternative), glob.matches(tool) { return true }
        if let regex = try? NSRegularExpression(pattern: "^(?:" + alternative + ")$"),
           regex.firstMatch(in: tool, range: NSRange(tool.startIndex..., in: tool)) != nil { return true }
        return false
    }
}

/// Reads the `hooks` key of the settings files Umbra already reads for permissions, in the same
/// order and shape as Claude Code's `settings.json`, so existing `.claude/settings.json` hooks
/// work: `{"hooks": {"PreToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command",
/// "command": "...", "timeout": 30}]}]}}`. Entries that are not shell commands are skipped, and
/// so is anything that is not a settings file: a broken file loses its hooks, it does not stop
/// the agent.
enum IDEAgentHooks {
    static func parse(_ data: Data, origin: IDEAgentPermissionFiles.Origin) -> [IDEAgentHookEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else { return [] }
        var entries: [IDEAgentHookEntry] = []
        for (key, value) in hooks {
            guard let event = IDEAgentHookEvent(rawValue: key),
                  let groups = value as? [[String: Any]]
            else { continue }
            for group in groups {
                let matcher = group["matcher"] as? String ?? ""
                guard let defs = group["hooks"] as? [[String: Any]] else { continue }
                for def in defs {
                    guard (def["type"] as? String ?? "command") == "command",
                          let command = (def["command"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                          !command.isEmpty
                    else { continue }
                    entries.append(IDEAgentHookEntry(
                        event: event, matcher: matcher, command: command,
                        timeout: timeout(from: def), required: (def["required"] as? Bool) ?? false,
                        origin: origin))
                }
            }
        }
        // Dictionaries read in any order; keep the list stable for the fingerprint.
        return entries.sorted {
            ($0.event.rawValue, $0.matcher, $0.command) < ($1.event.rawValue, $1.matcher, $1.command)
        }
    }

    private static func timeout(from def: [String: Any]) -> TimeInterval {
        let seconds: TimeInterval?
        if let value = def["timeout"] as? Double { seconds = value }
        else if let value = def["timeout"] as? Int { seconds = TimeInterval(value) }
        else { seconds = nil }
        guard let seconds else { return IDEAgentHookRunner.defaultTimeout }
        return min(300, max(1, seconds))
    }
}

/// Where the agent's hooks live: the same files as the permission rules, merged in the same
/// order (the app's own file first, then the project's).
enum IDEAgentHookFiles {
    static func load(projectRoot: URL?, appFile: URL?) -> [IDEAgentHookEntry] {
        var entries: [IDEAgentHookEntry] = []
        if let appFile, let data = try? Data(contentsOf: appFile) {
            entries += IDEAgentHooks.parse(data, origin: .app)
        }
        if let projectRoot {
            let files: [(String, IDEAgentPermissionFiles.Origin)] = [
                (".umbra/settings.json", .projectShared),
                (IDEAgentPermissionFiles.projectLocalPath, .projectLocal),
                (".claude/settings.json", .claudeShared),
                (".claude/settings.local.json", .claudeLocal),
            ]
            for (path, origin) in files {
                let url = projectRoot.appendingPathComponent(path)
                guard let data = try? Data(contentsOf: url) else { continue }
                entries += IDEAgentHooks.parse(data, origin: origin)
            }
        }
        return entries
    }
}
