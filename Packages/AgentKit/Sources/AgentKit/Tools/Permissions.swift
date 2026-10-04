import Foundation

/// How much the agent does on its own. Reads never ask.
public enum PermissionMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Every edit shows its diff first, and every command asks.
    case manual
    /// Edits apply at once, checkpointed so a run can be reverted; commands ask. The default.
    case acceptEdits
    /// Edits apply at once, and commands that are known to be read-only (or that a rule allows) run
    /// without asking; any other command asks.
    case auto
    /// The model is not given the tools that change files or run commands, so it can only look and propose.
    case plan

    /// Whether a tool of this risk is offered to the model.
    public func offers(_ risk: ToolRisk) -> Bool {
        switch self {
        case .plan: risk == .read
        case .manual, .acceptEdits, .auto: true
        }
    }

    /// The order ⇧Tab walks through.
    public static let cycleOrder: [PermissionMode] = [.manual, .acceptEdits, .auto, .plan]

    public var next: PermissionMode {
        let order = Self.cycleOrder
        return order[((order.firstIndex(of: self) ?? 0) + 1) % order.count]
    }

    /// Reads a stored value, including the names the three original modes had.
    public init?(persisted raw: String) {
        switch raw {
        case "autoApplyEdits": self = .acceptEdits
        case "approveEachEdit": self = .manual
        case "planOnly": self = .plan
        default:
            guard let mode = PermissionMode(rawValue: raw) else { return nil }
            self = mode
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let mode = PermissionMode(persisted: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown permission mode \"\(raw)\"."))
        }
        self = mode
    }

    /// What the model is told when the mode changes during a conversation.
    public var editorNote: String {
        switch self {
        case .manual:
            "The permission mode is now Manual: every edit is shown to the user as a diff first and may be rejected, and every command asks for approval."
        case .acceptEdits:
            "The permission mode is now Accept Edits: edits apply immediately. Commands still ask for approval."
        case .auto:
            "The permission mode is now Auto: edits apply immediately, and commands that are known to be read-only run without asking. Any other command asks for approval."
        case .plan:
            "The permission mode is now Plan: you can read, search and check problems, but you cannot change files or run commands. Investigate, then give the user a concrete plan."
        }
    }
}

/// What a call touches, as far as a permission rule can tell.
public enum PermissionSubject: Sendable, Equatable {
    case command(String)
    /// Project-relative paths the call would change.
    case paths([String])
    case none
}

/// A call as the permission policy sees it.
public struct ToolCallInfo: Sendable, Equatable {
    public var name: String
    public var risk: ToolRisk
    public var subject: PermissionSubject

    public init(name: String, risk: ToolRisk, subject: PermissionSubject) {
        self.name = name
        self.risk = risk
        self.subject = subject
    }
}

/// One allow, ask or deny entry: a tool and, optionally, which calls of it. Written as a string,
/// the way Claude Code's settings write them: `run_command(git status:*)`, `Bash(npm test)`,
/// `Edit(src/**)`, `edit_file`.
public struct PermissionRule: Sendable, Hashable, Codable, CustomStringConvertible {
    /// A tool name, `*`, or a Claude Code name: `Bash` (any command tool), `Edit`, `Write` or
    /// `MultiEdit` (any file-changing tool).
    public var tool: String
    /// Commands: `prefix:*` matches a command that is the prefix or starts with it plus a space; `*`
    /// elsewhere is a wildcard; anything else must match exactly. Paths: a glob.
    public var pattern: String?

    public init(tool: String, pattern: String? = nil) {
        self.tool = tool
        self.pattern = pattern
    }

    /// `nil` for text that is not a rule (empty, or unbalanced parentheses).
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let open = trimmed.firstIndex(of: "(") else {
            guard !trimmed.contains(")") else { return nil }
            self.init(tool: trimmed)
            return
        }
        guard trimmed.hasSuffix(")") else { return nil }
        let tool = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        let pattern = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        guard !tool.isEmpty else { return nil }
        self.init(tool: tool, pattern: pattern.isEmpty ? nil : String(pattern))
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let rule = PermissionRule(parsing: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a permission rule: \"\(text)\"."))
        }
        self = rule
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String { pattern.map { "\(tool)(\($0))" } ?? tool }

    func appliesTo(_ call: ToolCallInfo) -> Bool {
        switch tool {
        case "*", call.name: true
        case "Bash": call.risk == .command
        case "Edit", "Write", "MultiEdit": call.risk == .edit
        default: false
        }
    }

    func matches(command segment: String) -> Bool {
        guard let pattern else { return true }
        if pattern.hasSuffix(":*") {
            let prefix = String(pattern.dropLast(2))
            return segment == prefix || segment.hasPrefix(prefix + " ")
        }
        if pattern.contains("*") { return Self.wildcard(pattern, matches: segment) }
        return segment == pattern
    }

    func matches(path: String) -> Bool {
        guard let pattern else { return true }
        let normalized = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
        guard let glob = try? GlobPattern(normalized) else { return false }
        return glob.matches(path.hasPrefix("./") ? String(path.dropFirst(2)) : path)
    }

    /// `*` stands for any run of characters, including none.
    static func wildcard(_ pattern: String, matches text: String) -> Bool {
        let parts = pattern.components(separatedBy: "*")
        var remainder = Substring(text)
        for (index, part) in parts.enumerated() {
            if index == 0 {
                guard remainder.hasPrefix(part) else { return false }
                remainder = remainder.dropFirst(part.count)
            } else if index == parts.count - 1 {
                return remainder.hasSuffix(part) && remainder.count >= part.count
            } else {
                guard let found = remainder.range(of: part) else { return false }
                remainder = remainder[found.upperBound...]
            }
        }
        return remainder.isEmpty
    }

    /// The rule an "always allow" button offers for a command: `Bash(git status:*)` for `git status -sb`,
    /// `Bash(swift build:*)` for `swift build`. `Bash` covers every command tool, so it also matches the
    /// same command run through `gradle` or `run_tests`. `nil` for a compound command, which no single rule describes.
    public static func suggestion(forCommand command: String) -> PermissionRule? {
        let parsed = CommandSegments.parse(command)
        guard !parsed.isOpaque, parsed.segments.count == 1 else { return nil }
        let words = CommandSegments.words(parsed.segments[0])
        guard let first = words.first, !first.contains("="), !first.contains("$") else { return nil }
        let subcommandTools: Set<String> = [
            "git", "npm", "yarn", "pnpm", "cargo", "go", "gradle", "./gradlew", "gradlew", "mvn", "docker", "kubectl",
            "make", "brew", "swift", "xcodebuild",
        ]
        var prefix = first
        if subcommandTools.contains(first), words.count > 1, !words[1].hasPrefix("-") { prefix += " " + words[1] }
        return PermissionRule(tool: "Bash", pattern: prefix + ":*")
    }
}

/// The user's rules. Order of precedence is in `PermissionPolicy`: deny, then ask, then allow.
public struct PermissionRules: Sendable, Equatable, Codable {
    public var allow: [PermissionRule]
    public var ask: [PermissionRule]
    public var deny: [PermissionRule]

    public init(allow: [PermissionRule] = [], ask: [PermissionRule] = [], deny: [PermissionRule] = []) {
        self.allow = allow
        self.ask = ask
        self.deny = deny
    }

    public var isEmpty: Bool { allow.isEmpty && ask.isEmpty && deny.isEmpty }

    /// Every list of both, in order and without repeats.
    public func merged(with other: PermissionRules) -> PermissionRules {
        func union(_ a: [PermissionRule], _ b: [PermissionRule]) -> [PermissionRule] {
            var seen = Set<PermissionRule>()
            return (a + b).filter { seen.insert($0).inserted }
        }
        return PermissionRules(
            allow: union(allow, other.allow), ask: union(ask, other.ask), deny: union(deny, other.deny))
    }

    /// Reads the `permissions` object of a Claude Code or Umbra settings file (`allow`, `ask`, `deny`
    /// lists of rule strings). Entries that are not rules are skipped, and so is anything that is not
    /// a settings file: a broken file loses its rules, it does not stop the agent.
    public static func fromSettings(_ data: Data) -> PermissionRules {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = root["permissions"] as? [String: Any]
        else { return PermissionRules() }
        func rules(_ key: String) -> [PermissionRule] {
            (permissions[key] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(PermissionRule.init(parsing:)) }
        }
        return PermissionRules(allow: rules("allow"), ask: rules("ask"), deny: rules("deny"))
    }

    public enum Kind: Sendable { case allow, ask, deny }

    public mutating func add(_ rule: PermissionRule, to kind: Kind) {
        switch kind {
        case .allow: if !allow.contains(rule) { allow.append(rule) }
        case .ask: if !ask.contains(rule) { ask.append(rule) }
        case .deny: if !deny.contains(rule) { deny.append(rule) }
        }
    }
}

public enum PermissionVerdict: Sendable, Equatable {
    case allow
    /// `notes` go on the approval card.
    case ask(notes: [String])
    /// The reason goes back to the model as the call's output.
    case deny(String)
}

/// The host's say over a call, ahead of the user's own ask and allow rules: Umbra uses it to ask
/// before one chat edits a file that another chat's run is changing. `nil`, or `.allow`, has no opinion.
public protocol PermissionGate: Sendable {
    func verdict(for call: ToolCallInfo) async -> PermissionVerdict?
}
