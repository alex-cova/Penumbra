import AgentKit
import AppKit
import Foundation
import Penumbra
import UniformTypeIdentifiers

extension IDEAgentController {
    /// What `/init` asks for.
    static let initPrompt = """
    Look at this project and write an AGENTS.md at its root for a coding agent that will work here: how to build \
    and run it, how to run the tests, how the code is laid out, and the conventions to follow. Be specific to \
    this project, not generic, and keep it under 80 lines. If there is already an AGENTS.md or CLAUDE.md, improve \
    it instead of replacing it. Read before you write.
    """

    // MARK: - Sending

    /// What Return does in the message field: run a command if the message is one, else send it.
    func submit() {
        let text = selected.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        commandCatalog.invalidate()
        if let invocation = IDEAgentSlashInvocation.parse(text), let descriptor = commandCatalog.descriptor(named: invocation.name) {
            run(descriptor, arguments: invocation.arguments)
            return
        }
        if selected.canSend { selected.send() }
    }

    // MARK: - Suggestions

    /// The rows above the message field for `/` and `@`.
    func suggestions(for trigger: IDEAgentComposerTrigger) -> [IDEAgentSuggestion] {
        switch trigger {
        case .slash(let query, _): commandSuggestions(matching: query)
        case .slashArgument(let command, let query, _): argumentSuggestions(for: command, matching: query)
        case .mention, .none: []
        }
    }

    private func commandSuggestions(matching query: String) -> [IDEAgentSuggestion] {
        let ranked: [(descriptor: IDEAgentCommandDescriptor, score: Int)] = commandCatalog.descriptors.compactMap { descriptor in
            if query.isEmpty { return (descriptor, 0) }
            return FuzzyMatcher.match(query: query, in: descriptor.name).map { (descriptor, $0.score) }
        }
        let ordered = ranked.enumerated().sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }.map(\.element)
        return ordered.prefix(40).map { descriptor, _ in
            var detail = descriptor.summary
            if let hint = descriptor.argumentHint { detail = hint + (detail.isEmpty ? "" : "  ·  " + detail) }
            if let source = descriptor.source { detail += "  ·  " + source }
            return IDEAgentSuggestion(
                id: "command:" + descriptor.name, icon: descriptor.symbol, title: "/" + descriptor.name, detail: detail,
                insertion: "/" + descriptor.name + " ", payload: descriptor.takesNoArguments ? .run(descriptor.name) : nil)
        }
    }

    private func argumentSuggestions(for command: String, matching query: String) -> [IDEAgentSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        switch command.lowercased() {
        case "resume":
            let open = Set(conversations.map(\.conversationID))
            let ranked: [(summary: SessionSummary, score: Int)] = history.compactMap { summary in
                if trimmed.isEmpty { return (summary, 0) }
                return FuzzyMatcher.match(query: trimmed, in: summary.title).map { (summary, $0.score) }
            }
            let ordered = ranked.enumerated().sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }.map(\.element)
            return ordered.prefix(30).map { summary, _ in
                IDEAgentSuggestion(
                    id: "resume:" + summary.id.uuidString, icon: "bubble.left", title: summary.title,
                    detail: summary.updatedAt.formatted(.relative(presentation: .named)) + (open.contains(summary.id) ? "  ·  open" : ""),
                    insertion: summary.title, payload: .resume(summary.id))
            }
        case "mode":
            return PermissionMode.allCases.compactMap { mode in
                guard trimmed.isEmpty || FuzzyMatcher.match(query: trimmed, in: mode.title) != nil else { return nil }
                return IDEAgentSuggestion(
                    id: "mode:" + mode.rawValue, icon: mode.symbol, title: mode.title, detail: mode.detail,
                    insertion: mode.rawValue, payload: .mode(mode))
            }
        default:
            return []
        }
    }

    /// Carries out what an accepted row stands for.
    func perform(_ payload: IDEAgentSuggestionPayload) {
        switch payload {
        case .resume(let id):
            resume(id)
        case .mode(let mode):
            changeMode(to: mode)
        case .run(let name):
            commandCatalog.invalidate()
            if let descriptor = commandCatalog.descriptor(named: name) { run(descriptor, arguments: "") }
        }
    }

    // MARK: - Running

    func run(_ descriptor: IDEAgentCommandDescriptor, arguments: String) {
        switch descriptor.kind {
        case .builtIn(let command):
            selected.draft = ""
            runBuiltIn(command, arguments: arguments)
        case .custom(let template):
            guard selected.canRunCommands else { return }
            if template.usesShellSubstitution {
                selected.appendNotice("Lines like !`command` in /\(template.name) are sent as text: Umbra does not run them.")
            }
            let typed = ("/" + descriptor.name + " " + arguments).trimmingCharacters(in: .whitespaces)
            selected.submit(text: typed, modelText: template.expand(arguments: arguments), allowedTools: template.allowedTools)
        case .skill(let skill):
            guard selected.canRunCommands else { return }
            let typed = ("/" + descriptor.name + " " + arguments).trimmingCharacters(in: .whitespaces)
            selected.submit(text: typed, modelText: Self.skillMessage(skill, arguments: arguments), allowedTools: skill.allowedTools)
        }
    }

    /// What the model is sent when the user runs a skill themselves.
    static func skillMessage(_ skill: Skill, arguments: String) -> String {
        var message = "[Skill: \(skill.name)]\n\(skill.body)"
        message += "\n\nFiles next to these instructions can be read with the skill tool: skill(name: \"\(skill.name)\", file: \"path/inside/the/skill\")."
        if !arguments.isEmpty { message += "\n\nArguments: \(arguments)" }
        return message
    }

    private func runBuiltIn(_ command: IDEAgentBuiltInCommand, arguments: String) {
        switch command {
        case .new:
            newConversation()
            composerFocusRequest += 1
        case .clear:
            clear()
        case .resume:
            if arguments.isEmpty {
                // The list of chats is the argument picker: put the caret where it shows.
                selected.draft = "/resume "
                composerFocusRequest += 1
            } else if let match = bestChat(matching: arguments) {
                resume(match.id)
            } else {
                selected.appendNotice("No saved chat matches “\(arguments)”.")
            }
        case .plan:
            changeMode(to: .plan)
            if !arguments.isEmpty, selected.canRunCommands { selected.submit(text: arguments) }
        case .mode:
            if arguments.isEmpty {
                selected.draft = "/mode "
                composerFocusRequest += 1
            } else if let mode = PermissionMode(spoken: arguments) {
                changeMode(to: mode)
            } else {
                selected.appendNotice("“\(arguments)” is not a mode. Choose manual, accept-edits, auto or plan.")
            }
        case .permissions:
            onOpenSettings?()
        case .model:
            settingsRequest += 1
        case .export:
            exportTranscript()
        case .initialize:
            guard selected.canRunCommands else { return }
            selected.submit(text: "/init", modelText: Self.initPrompt)
        case .cost:
            selected.appendNotice(Self.costNotice(usage: selected.usage, cost: selected.cost))
        case .rename:
            if arguments.isEmpty {
                selected.appendNotice("Give the chat a name: /rename <name>.")
            } else {
                selected.rename(arguments)
            }
        case .help:
            selected.appendNotice(helpText())
        }
    }

    private func changeMode(to mode: PermissionMode) {
        selected.setMode(mode)
        selected.appendNotice("Mode: \(mode.title). \(mode.detail)")
    }

    /// The saved chat whose title matches best.
    func bestChat(matching query: String) -> SessionSummary? {
        history.compactMap { summary in FuzzyMatcher.match(query: query, in: summary.title).map { (summary, $0.score) } }
            .max { $0.1 < $1.1 }?.0
    }

    static func costNotice(usage: TokenUsage, cost: Double?) -> String {
        let total = usage.inputTokens + usage.outputTokens
        guard total > 0 else { return "Nothing has been sent in this chat yet." }
        var text = "\(IDEAgentFormat.tokens(usage.inputTokens)) tokens in (\(IDEAgentFormat.tokens(usage.cachedInputTokens)) cached), \(IDEAgentFormat.tokens(usage.outputTokens)) out."
        if let cost { text += " About \(IDEAgentPrices.format(cost))." } else { text += " No price is known for this model, so there is no cost estimate." }
        return text
    }

    private func helpText() -> String {
        let descriptors = commandCatalog.descriptors
        var lines = ["Commands (type / to pick one):"]
        for descriptor in descriptors {
            var line = "/" + descriptor.name
            if let hint = descriptor.argumentHint { line += " " + hint }
            if !descriptor.summary.isEmpty { line += "  —  " + descriptor.summary }
            lines.append(line)
        }
        lines.append("@ mentions a file. ⇧Tab changes the mode. ⌥⌘T opens a new chat.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Export

    func exportTranscript() {
        let title = selected.title
        let markdown = IDEAgentTranscriptExport.markdown(title: title, entries: selected.entries)
        exportHandler(IDEAgentTranscriptExport.fileName(for: title), markdown)
    }

    /// The default way a transcript is saved: a save panel.
    static func presentSavePanel(name: String, text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

extension PermissionMode {
    /// A mode as a person writes it: `Accept Edits`, `accept-edits`, `accept`, `edits`.
    init?(spoken text: String) {
        let key = text.lowercased().filter { $0.isLetter }
        switch key {
        case "manual", "ask": self = .manual
        case "acceptedits", "accept", "edits", "default": self = .acceptEdits
        case "auto", "automatic": self = .auto
        case "plan", "planning": self = .plan
        default: return nil
        }
    }
}

extension IDEAgentConversation {
    /// Whether a command that sends a message could do so now.
    var canRunCommands: Bool { !isRunning && settings.hasAcceptedDisclosure }
}
