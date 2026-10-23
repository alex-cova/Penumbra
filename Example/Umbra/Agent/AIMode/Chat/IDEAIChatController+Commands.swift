import AgentKit
import Foundation
import Penumbra

/// Slash commands in AI Chat: the project-less subset of the agent's built-ins. Chat has no
/// project, tools, modes or checkpoints, so `/plan`, `/mode`, `/permissions`, `/init`, `/rewind`
/// and `/fork` are not offered; `@` mentions and `!` shell commands are not either.
extension IDEAIChatController {
    /// The built-ins Chat offers, in list order.
    static let chatCommands: [IDEAgentBuiltInCommand] = [
        .new, .clear, .resume, .compact, .model, .export, .cost, .rename, .help,
    ]

    /// What Return does in the message field: run a command if the message is one, else send it.
    func submit() {
        let text = selected.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !selected.isRunning else { return }
        if let invocation = IDEAgentSlashInvocation.parse(text),
           let command = IDEAgentBuiltInCommand(rawValue: invocation.name.lowercased()),
           Self.chatCommands.contains(command)
        {
            selected.draft = ""
            run(command, arguments: invocation.arguments)
            return
        }
        // A lone `/word` that is no command is still sent, but it is probably a mistyped
        // command, so the transcript says it went to the model as text.
        let unknownCommand = IDEAgentSlashInvocation.parse(text).flatMap { $0.arguments.isEmpty ? $0.name : nil }
        if let unknownCommand { selected.appendNotice(Self.unknownCommandNotice(unknownCommand)) }
        selected.send()
    }

    static func unknownCommandNotice(_ name: String) -> String {
        "There is no command named /\(name) here, so it was sent to the model as a message. /help lists the commands."
    }

    // MARK: - Suggestions

    /// The rows above the message field for `/`. Chat offers no `@` mentions (nothing to attach)
    /// and no prompt history (chats are not per-project), so those triggers stay empty.
    func suggestions(for trigger: IDEAgentComposerTrigger) -> [IDEAgentSuggestion] {
        switch trigger {
        case .slash(let query, _): commandSuggestions(matching: query)
        case .slashArgument(let command, let query, _): argumentSuggestions(for: command, matching: query)
        case .mention, .history, .none: []
        }
    }

    private func commandSuggestions(matching query: String) -> [IDEAgentSuggestion] {
        let ranked: [(command: IDEAgentBuiltInCommand, score: Int)] = Self.chatCommands.compactMap { command in
            if query.isEmpty { return (command, 0) }
            return FuzzyMatcher.match(query: query, in: command.rawValue).map { (command, $0.score) }
        }
        let ordered = ranked.enumerated().sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }.map(\.element)
        return ordered.prefix(40).map { command, _ in
            var detail = command.summary
            if let hint = command.argumentHint { detail = hint + (detail.isEmpty ? "" : "  ·  " + detail) }
            return IDEAgentSuggestion(
                id: "command:" + command.rawValue, icon: command.symbol, title: "/" + command.rawValue, detail: detail,
                insertion: "/" + command.rawValue + " ",
                payload: command.argumentHint == nil ? .run(command.rawValue) : nil)
        }
    }

    private func argumentSuggestions(for command: String, matching query: String) -> [IDEAgentSuggestion] {
        guard command.lowercased() == "resume" else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let open = Set(conversations.map(\.conversationID))
        return IDEAgentHistorySearch.rank(history, query: trimmed).prefix(30).map { summary in
            IDEAgentSuggestion(
                id: "resume:" + summary.id.uuidString, icon: "bubble.left", title: summary.title,
                detail: summary.updatedAt.formatted(.relative(presentation: .named)) + (open.contains(summary.id) ? "  ·  open" : ""),
                insertion: summary.title, payload: .resume(summary.id))
        }
    }

    /// Carries out what an accepted row stands for.
    func perform(_ payload: IDEAgentSuggestionPayload) {
        switch payload {
        case .resume(let id):
            resume(id)
        case .run(let name):
            if let command = IDEAgentBuiltInCommand(rawValue: name), Self.chatCommands.contains(command) {
                run(command, arguments: "")
            }
        case .mode:
            break
        }
    }

    // MARK: - Running

    func run(_ command: IDEAgentBuiltInCommand, arguments: String) {
        switch command {
        case .new:
            newChat()
        case .clear:
            selected.reset()
        case .resume:
            if arguments.isEmpty {
                // The list of chats is the argument picker: put the caret where it shows.
                selected.draft = "/resume "
                composerFocusRequest += 1
            } else if let match = IDEAgentHistorySearch.rank(history, query: arguments, requiresMatch: true).first {
                resume(match.id)
            } else {
                selected.appendNotice("No saved chat matches “\(arguments)”.")
            }
        case .compact:
            let conversation = selected
            Task { await conversation.compact() }
        case .model:
            modelRequest += 1
        case .export:
            exportTranscript()
        case .cost:
            selected.appendNotice(IDEAgentController.costNotice(usage: selected.usage, cost: selected.cost))
        case .rename:
            if arguments.isEmpty {
                selected.appendNotice("Give the chat a name: /rename <name>.")
            } else {
                selected.rename(arguments)
            }
        case .help:
            selected.appendNotice(helpText())
        case .rewind, .fork, .plan, .mode, .permissions, .history, .initialize:
            selected.appendNotice("There is no /\(command.rawValue) in Chat.")
        }
    }

    private func helpText() -> String {
        var lines = ["Commands (type / to pick one):"]
        for command in Self.chatCommands {
            var line = "/" + command.rawValue
            if let hint = command.argumentHint { line += " " + hint }
            if !command.summary.isEmpty { line += "  —  " + command.summary }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Export

    func exportTranscript() {
        let title = selected.title
        exportHandler(
            IDEAgentTranscriptExport.fileName(for: title),
            IDEAgentTranscriptExport.markdown(title: title, entries: selected.entries))
    }
}
