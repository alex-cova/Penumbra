import Foundation

/// A question the model put to the user with `ask_user`. The run waits for `AgentSession.answerQuestion`.
public struct UserQuestion: Sendable, Equatable {
    public var callID: String
    public var question: String
    /// Suggested answers; the user may type something else.
    public var options: [String]

    public init(callID: String, question: String, options: [String] = []) {
        self.callID = callID
        self.question = question
        self.options = options
    }
}

/// One line of the checklist the model keeps with `todo`.
public struct TodoItem: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Equatable, Codable {
        case pending, inProgress, completed
    }

    public var content: String
    public var status: Status

    public init(_ content: String, _ status: Status = .pending) {
        self.content = content
        self.status = status
    }

    /// `[ ] text`, `[~] text` (in progress) or `[x] text`. A leading list marker is allowed, and a
    /// line with no checkbox is a pending item.
    static func parse(_ line: String) -> TodoItem? {
        var text = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "• "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        var status = Status.pending
        if text.count >= 3, text.hasPrefix("["), let close = text.firstIndex(of: "]"), text.distance(from: text.startIndex, to: close) == 2 {
            let mark = text[text.index(after: text.startIndex)]
            switch mark {
            case "x", "X", "✓", "✔": status = .completed
            case "~", ">", "-", "*": status = .inProgress
            default: status = .pending
            }
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }
        return TodoItem(String(text.prefix(TodoList.maxItemLength)), status)
    }

    /// The form the model writes and reads.
    public var line: String {
        switch status {
        case .pending: "[ ] \(content)"
        case .inProgress: "[~] \(content)"
        case .completed: "[x] \(content)"
        }
    }
}

/// The session's checklist. Lives next to the conversation; the host shows it and the model keeps it.
public actor TodoList {
    public static let maxItems = 30
    public static let maxItemLength = 200

    public private(set) var items: [TodoItem] = []
    private var revision = 0
    private var emittedRevision = 0

    public init(_ items: [TodoItem] = []) {
        self.items = items
    }

    /// Returns whether the list changed.
    @discardableResult
    public func replace(with items: [TodoItem]) -> Bool {
        guard items != self.items else { return false }
        self.items = items
        revision += 1
        return true
    }

    /// The list if it changed since this was last called, else `nil`.
    func takeChange() -> [TodoItem]? {
        guard revision != emittedRevision else { return nil }
        emittedRevision = revision
        return items
    }

    /// The checklist as of the last `todo` call in `items`, so a resumed conversation has it back.
    public static func latest(in items: [ConversationItem]) -> [TodoItem] {
        for item in items.reversed() {
            guard case .toolCall(_, "todo", let arguments) = item,
                  let parsed = try? TodoTool.items(from: ToolArguments(json: arguments))
            else { continue }
            return parsed
        }
        return []
    }
}

/// `todo`: the model's own checklist for work with several steps. It replaces the whole list each
/// call, which is simpler for a model to get right than patching items by index.
public struct TodoTool: AgentTool {
    public init() {}
    public var risk: ToolRisk { .read }
    public var isExemptFromRepeatGuard: Bool { true }
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "todo",
            description: """
            Keep a checklist for work with several steps. Each call replaces the whole list. Write each \
            item as `[ ] text` (to do), `[~] text` (doing now) or `[x] text` (done). Keep at most one \
            item in progress, and mark an item done as soon as it is. The user sees the list.
            """,
            parameters: [ToolParameter("items", .array(of: .string), "The complete checklist, in order.")])
    }

    static func items(from arguments: ToolArguments) throws -> [TodoItem] {
        let lines = try arguments.stringArray("items")
        guard lines.count <= TodoList.maxItems else {
            throw ToolError("A checklist holds at most \(TodoList.maxItems) items; group the small steps.")
        }
        return lines.compactMap(TodoItem.parse)
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let items = try Self.items(from: arguments)
        guard let list = context.todos else { throw ToolError("A checklist is not available here.") }
        let changed = await list.replace(with: items)
        if items.isEmpty { return changed ? "Checklist cleared." : "The checklist was already empty." }
        let done = items.filter { $0.status == .completed }.count
        // Sending the same list again changes nothing; say so, so the model moves on instead of repeating it.
        if !changed { return "Checklist unchanged (\(done) of \(items.count) done). Mark items [x] as you finish them, and carry on with the next step." }
        return "Checklist updated (\(done) of \(items.count) done):\n" + items.map(\.line).joined(separator: "\n")
    }
}

/// `ask_user`: a question only the user can answer. The run pauses until they do; Stop ends the wait.
public struct AskUserTool: AgentTool {
    public init() {}
    public var risk: ToolRisk { .read }
    public var waitsForUser: Bool { true }
    public var definition: ToolDefinition {
        ToolDefinition(
            name: "ask_user",
            description: """
            Ask the user a question and wait for the answer. Use it when the request is ambiguous in a way \
            that changes what you would build, or a decision is theirs to make (which of two designs, \
            whether to delete something). Do not ask what you can find out with your tools. Offer short \
            `options` when the answers are a small set.
            """,
            parameters: [
                ToolParameter("question", .string, "One clear question."),
                ToolParameter("options", .array(of: .string), "Suggested answers; the user can also type their own.", optional: true),
            ])
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let question = try arguments.string("question").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw ToolError("The question is empty.") }
        let options = (try arguments.optionalStringArray("options") ?? []).prefix(6).map { String($0.prefix(120)) }
        guard let ask = context.ask else { throw ToolError("The user cannot be asked here. Decide with the information you have and say what you assumed.") }
        guard let answer = await ask(UserQuestion(callID: context.callID, question: question, options: options)) else {
            return "The user did not answer. Continue with your best judgment and say what you assumed, or stop and explain what you need."
        }
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "The user gave an empty answer." : "The user answered: \(text)"
    }
}
