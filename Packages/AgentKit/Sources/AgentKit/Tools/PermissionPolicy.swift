import Foundation

/// Decides whether a call that changes files or runs a command goes ahead, asks, or is refused.
///
/// In order: a deny rule refuses; the host's gate may ask or refuse; an ask rule asks; an allow rule
/// allows; otherwise the mode decides. A command is checked segment by segment (`a && b | c` is three
/// commands), and a command the parser cannot read with certainty is never allowed by a rule or by
/// Auto mode, though a deny or ask rule still catches the parts it can see.
public enum PermissionPolicy {
    public static func evaluate(
        _ call: ToolCallInfo,
        mode: PermissionMode,
        rules: PermissionRules,
        gate: (any PermissionGate)? = nil,
        secretPatterns: [GlobPattern] = []
    ) async -> PermissionVerdict {
        if call.risk == .read { return .allow }
        if mode == .plan { return .deny("\(call.name) is not available: this session is in plan mode, so nothing can be changed or run. Describe the change in your plan instead.") }

        if let rule = firstRule(in: rules.deny, touching: call) {
            return .deny("Blocked by the user's permission rules (deny \(rule)). Do not try this again; ask the user or take another approach.")
        }
        if let verdict = await gate?.verdict(for: call), verdict != .allow { return verdict }
        if firstRule(in: rules.ask, touching: call) != nil { return .ask(notes: []) }
        if covers(rules.allow, call) { return .allow }

        switch (call.risk, mode) {
        case (.edit, .manual):
            return .ask(notes: [])
        case (.edit, _):
            return .allow
        case (.command, .auto):
            return autoVerdict(call, rules: rules, secretPatterns: secretPatterns)
        case (.command, _):
            return .ask(notes: [])
        case (.read, _):
            return .allow
        }
    }

    // MARK: - Auto mode

    private static func autoVerdict(_ call: ToolCallInfo, rules: PermissionRules, secretPatterns: [GlobPattern]) -> PermissionVerdict {
        guard case .command(let text) = call.subject else {
            return .ask(notes: ["Auto mode only runs commands it can read and recognizes as read-only."])
        }
        let parsed = CommandSegments.parse(text)
        guard !parsed.isOpaque, !parsed.hasRedirection, !parsed.segments.isEmpty else {
            return .ask(notes: ["Auto mode asks about commands with substitutions, subshells or redirections."])
        }
        guard CommandWarnings.warnings(for: text).isEmpty else { return .ask(notes: []) }
        for segment in parsed.segments {
            let allowed = rules.allow.contains { $0.appliesTo(call) && $0.matches(command: segment) }
            guard allowed || SafeCommands.isSafe(segment, secretPatterns: secretPatterns) else {
                return .ask(notes: ["Auto mode runs known read-only commands without asking; this one is not on that list."])
            }
        }
        return .allow
    }

    // MARK: - Rules

    /// A rule that applies to any part of the call: enough for a deny or an ask.
    static func firstRule(in rules: [PermissionRule], touching call: ToolCallInfo) -> PermissionRule? {
        rules.first { rule in
            guard rule.appliesTo(call) else { return false }
            guard rule.pattern != nil else { return true }
            switch call.subject {
            case .command(let text):
                let parsed = CommandSegments.parse(text)
                return rule.matches(command: text.trimmingCharacters(in: .whitespacesAndNewlines))
                    || parsed.segments.contains { rule.matches(command: $0) }
            case .paths(let paths):
                return paths.contains { rule.matches(path: $0) }
            case .none:
                return false
            }
        }
    }

    /// Whether the rules, together, allow every part of the call. A command with a substitution or
    /// subshell is never covered, whatever its visible parts say.
    static func covers(_ rules: [PermissionRule], _ call: ToolCallInfo) -> Bool {
        let applicable = rules.filter { $0.appliesTo(call) }
        guard !applicable.isEmpty else { return false }
        switch call.subject {
        case .command(let text):
            let parsed = CommandSegments.parse(text)
            guard !parsed.isOpaque, !parsed.hasRedirection || applicable.contains(where: { $0.pattern == nil }),
                  !parsed.segments.isEmpty
            else { return false }
            return parsed.segments.allSatisfy { segment in applicable.contains { $0.matches(command: segment) } }
        case .paths(let paths):
            return !paths.isEmpty && paths.allSatisfy { path in applicable.contains { $0.matches(path: path) } }
        case .none:
            return applicable.contains { $0.pattern == nil }
        }
    }
}
