import AgentKit
import Foundation

/// `/name arguments`, as typed at the start of a message.
struct IDEAgentSlashInvocation: Equatable {
    let name: String
    let arguments: String

    /// `nil` unless the message begins with a slash and a name that ends at whitespace or at the end:
    /// `/usr/bin is missing` is a sentence about a path, not a command.
    static func parse(_ text: String) -> IDEAgentSlashInvocation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let rest = trimmed.dropFirst()
        let name = rest.prefix { isNameCharacter($0) }
        guard !name.isEmpty else { return nil }
        let after = rest.dropFirst(name.count)
        guard after.isEmpty || after.first!.isWhitespace else { return nil }
        return IDEAgentSlashInvocation(name: String(name), arguments: after.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "-_.:".contains(character)
    }
}

/// The commands the editor itself provides.
enum IDEAgentBuiltInCommand: String, CaseIterable {
    case new, clear, resume, rewind, fork, compact, plan, mode, permissions, model, history, export, loop, initialize = "init", cost, local, rename, help

    var summary: String {
        switch self {
        case .new: "Start a new chat in a new tab"
        case .clear: "Empty this chat"
        case .resume: "Open an earlier chat"
        case .rewind: "Go back to an earlier message, and optionally undo the file changes since"
        case .fork: "Continue this chat's conversation in a new tab"
        case .compact: "Summarize the earlier conversation to free up space"
        case .plan: "Plan first: the agent only reads until you approve"
        case .mode: "Change what the agent may do without asking"
        case .permissions: "Open the permission rules"
        case .model: "Choose the model and provider"
        case .history: "Show this file's local history"
        case .export: "Save this chat as Markdown or JSON"
        case .loop: "Resend a prompt on a timer, up to 10 runs"
        case .initialize: "Have the agent write an AGENTS.md for this project"
        case .cost: "Show this chat's token use and cost"
        case .local: "Run one prompt on the helper model and paste its report"
        case .rename: "Name this chat's tab"
        case .help: "List the commands"
        }
    }

    var argumentHint: String? {
        switch self {
        case .resume: "[search]"
        case .compact: "[what to keep in detail]"
        case .plan: "[what to plan]"
        case .mode: "manual | accept-edits | auto | plan"
        case .export: "[json] [--hide-tools]"
        case .loop: "<interval> [count] <prompt>"
        case .local: "<prompt>"
        case .rename: "<name>"
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .new: "plus.bubble"
        case .clear: "eraser"
        case .resume: "clock.arrow.circlepath"
        case .rewind: "arrow.uturn.backward"
        case .fork: "arrow.triangle.branch"
        case .compact: "arrow.down.right.and.arrow.up.left"
        case .plan: "list.bullet.clipboard"
        case .mode: "slider.horizontal.3"
        case .permissions: "checkmark.shield"
        case .model: "cpu"
        case .history: "clock"
        case .export: "square.and.arrow.up"
        case .loop: "repeat"
        case .initialize: "doc.badge.plus"
        case .cost: "dollarsign.circle"
        case .local: "magnifyingglass"
        case .rename: "pencil"
        case .help: "questionmark.circle"
        }
    }
}

/// An interval as `/loop` takes it: `30s`, `5m`, `1h`, or a bare number of minutes.
/// A schedule that survives quitting needs a launchd job, so this is a floor of in-app repeats.
enum IDEAgentLoopInterval {
    /// `nil` for anything that is not a positive duration.
    static func parse(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        var number = trimmed
        var multiplier = 60.0
        if let last = trimmed.last, "smh".contains(last) {
            number = String(trimmed.dropLast())
            multiplier = last == "s" ? 1 : last == "m" ? 60 : 3_600
        }
        guard let value = Double(number), value > 0, value.isFinite else { return nil }
        return value * multiplier
    }

    static func describe(_ interval: TimeInterval) -> String {
        if interval.truncatingRemainder(dividingBy: 3_600) == 0 { return "\(Int(interval / 3_600))h" }
        if interval.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(interval / 60))m" }
        return "\(Int(interval))s"
    }
}

/// A row of the command list: a built-in, a command the user wrote, or a skill.
struct IDEAgentCommandDescriptor: Identifiable, Equatable {
    enum Kind: Equatable {
        case builtIn(IDEAgentBuiltInCommand)
        case custom(CommandTemplate)
        case skill(Skill)
    }

    let name: String
    let kind: Kind

    var id: String { name }

    var summary: String {
        switch kind {
        case .builtIn(let command): command.summary
        case .custom(let template): template.description
        case .skill(let skill): skill.description
        }
    }

    var argumentHint: String? {
        switch kind {
        case .builtIn(let command): command.argumentHint
        case .custom(let template): template.argumentHint
        case .skill: nil
        }
    }

    var symbol: String {
        switch kind {
        case .builtIn(let command): command.symbol
        case .custom: "text.page"
        case .skill: "sparkles"
        }
    }

    /// Where it came from, for the list: nothing for built-ins.
    var source: String? {
        switch kind {
        case .builtIn: nil
        case .custom(let template): template.source
        case .skill(let skill): skill.source
        }
    }

    /// Accepting it in the list runs it at once, since there is nothing to add after its name.
    var takesNoArguments: Bool {
        switch kind {
        case .builtIn(let command): command.argumentHint == nil
        case .custom(let template): template.argumentHint == nil && !template.body.contains("$")
        case .skill: false
        }
    }
}
