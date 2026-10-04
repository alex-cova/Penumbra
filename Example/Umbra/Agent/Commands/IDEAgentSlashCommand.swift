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
    case new, clear, resume, plan, mode, permissions, model, export, initialize = "init", cost, rename, help

    var summary: String {
        switch self {
        case .new: "Start a new chat in a new tab"
        case .clear: "Empty this chat"
        case .resume: "Open an earlier chat"
        case .plan: "Plan first: the agent only reads until you approve"
        case .mode: "Change what the agent may do without asking"
        case .permissions: "Open the permission rules"
        case .model: "Choose the model and provider"
        case .export: "Save this chat as a Markdown file"
        case .initialize: "Have the agent write an AGENTS.md for this project"
        case .cost: "Show this chat's token use and cost"
        case .rename: "Name this chat's tab"
        case .help: "List the commands"
        }
    }

    var argumentHint: String? {
        switch self {
        case .resume: "[search]"
        case .plan: "[what to plan]"
        case .mode: "manual | accept-edits | auto | plan"
        case .rename: "<name>"
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .new: "plus.bubble"
        case .clear: "eraser"
        case .resume: "clock.arrow.circlepath"
        case .plan: "list.bullet.clipboard"
        case .mode: "slider.horizontal.3"
        case .permissions: "checkmark.shield"
        case .model: "cpu"
        case .export: "square.and.arrow.up"
        case .initialize: "doc.badge.plus"
        case .cost: "dollarsign.circle"
        case .rename: "pencil"
        case .help: "questionmark.circle"
        }
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
