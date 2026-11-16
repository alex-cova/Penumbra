import Foundation

/// Cursor CLI's ACP extension methods (`agent acp`, https://cursor.com/docs/cli/acp), mapped onto
/// cards Umbra already has instead of a Cursor-specific interface:
///
/// - `cursor/ask_question` (request): each question becomes an `ask_user` card, asked one after
///   another; the answer is matched to the question's options by label or id.
/// - `cursor/create_plan` (request): a plan card (approve / keep planning) plus the checklist.
/// - `cursor/update_todos` (notification; answered too if sent as a request): the checklist.
/// - `cursor/task`, `cursor/generate_image` (notifications): a tool row with the description and
///   arguments. Cursor runs subagents and image generation itself; Umbra only shows them.
///
/// Every request gets a JSON-RPC answer. Stop, a disconnect and the session's interaction timeout
/// answer `cancelled`; Umbra cannot run a subagent or generate an image, so those two requests (the
/// docs call them notifications) are answered `rejected` with a reason rather than left open.
public final class CursorACPExtension: ACPClientExtension, @unchecked Sendable {
    public static let methods: Set<String> = [
        "cursor/ask_question", "cursor/create_plan", "cursor/update_todos", "cursor/task", "cursor/generate_image",
    ]

    /// The checklist as Cursor last described it, by todo id, so `merge: true` updates in place.
    private let lock = NSLock()
    private var todoOrder: [String] = []
    private var todos: [String: Todo] = [:]

    public init() {}

    public func handles(method: String) -> Bool { Self.methods.contains(method) }

    public func handleRequest(method: String, params: JSONValue?, session: ACPClientSession) async -> Result<JSONValue, JSONRPCError> {
        guard let params else { return .failure(.invalidParams("Missing params.")) }
        switch method {
        case "cursor/ask_question":
            return .success(await askQuestions(params, session: session))
        case "cursor/create_plan":
            return .success(await createPlan(params, session: session))
        case "cursor/update_todos":
            let merged = updateTodos(params)
            await session.emit(.todosUpdated(merged.map(\.todoItem)))
            return .success(Self.outcome("accepted", ["todos": .array(merged.map(\.jsonValue))]))
        case "cursor/task", "cursor/generate_image":
            await showActivity(method: method, params: params, session: session)
            return .success(Self.outcome("rejected", ["reason": .string(Self.notRunHere)]))
        default:
            return .failure(.methodNotFound(method))
        }
    }

    public func handleNotification(method: String, params: JSONValue?, session: ACPClientSession) async {
        guard let params else { return }
        switch method {
        case "cursor/update_todos":
            let merged = updateTodos(params)
            await session.emit(.todosUpdated(merged.map(\.todoItem)))
        case "cursor/task", "cursor/generate_image":
            await showActivity(method: method, params: params, session: session)
        default:
            break
        }
    }

    static let notRunHere = "Umbra shows this request but cannot run it."

    // MARK: - Questions

    private func askQuestions(_ params: JSONValue, session: ACPClientSession) async -> JSONValue {
        let toolCallId = params.string("toolCallId") ?? UUID().uuidString
        let title = params.string("title") ?? "Question"
        let questions = (params["questions"]?.arrayValue ?? []).map(Question.init(jsonValue:))
        guard !questions.isEmpty else { return Self.outcome("skipped", ["reason": "No questions were sent."]) }
        var answers: [JSONValue] = []
        var freeText: [String] = []
        var summary: [String] = []
        for (index, question) in questions.enumerated() {
            // The first question uses the agent's call id so the card sits on Cursor's own row.
            let callID = index == 0 ? toolCallId : "\(toolCallId)#\(question.id)"
            let outcome = await session.askQuestion(
                callID: callID, title: title, question: question.prompt,
                options: question.options.map(\.label))
            switch outcome {
            case .cancelled:
                // The session already finished the card and said why.
                return Self.outcome("cancelled")
            case .skipped:
                summary.append("\(question.prompt) → skipped")
                if callID != toolCallId { await session.finishToolCall(id: callID, output: "Skipped") }
            case .answered(let text):
                let selected = question.match(text)
                if selected.isEmpty {
                    freeText.append("\(question.prompt): \(text)")
                    summary.append("\(question.prompt) → \(text)")
                } else {
                    answers.append(.object([
                        "questionId": .string(question.id),
                        "selectedOptionIds": .array(selected.map(JSONValue.string)),
                    ]))
                    summary.append("\(question.prompt) → \(question.labels(for: selected).joined(separator: ", "))")
                }
                if callID != toolCallId { await session.finishToolCall(id: callID, output: "Answered") }
            }
        }
        await session.finishToolCall(id: toolCallId, output: summary.joined(separator: "\n"))
        if answers.isEmpty {
            // Cursor's answer type carries option ids only; a typed reply goes back as the reason.
            let reason = freeText.isEmpty ? "The user skipped the question." : "The user answered in their own words: " + freeText.joined(separator: "; ")
            return Self.outcome("skipped", ["reason": .string(reason)])
        }
        return Self.outcome("answered", ["answers": .array(answers)])
    }

    // MARK: - Plans

    private func createPlan(_ params: JSONValue, session: ACPClientSession) async -> JSONValue {
        let toolCallId = params.string("toolCallId") ?? UUID().uuidString
        let todosParams = JSONValue.object(["todos": params["todos"] ?? .array([]), "merge": false])
        let checklist = updateTodos(todosParams)
        if !checklist.isEmpty { await session.emit(.todosUpdated(checklist.map(\.todoItem))) }
        var plan = params.string("plan") ?? ""
        if let overview = params.string("overview"), !overview.isEmpty, !plan.contains(overview) {
            plan = overview + "\n\n" + plan
        }
        let title = params.string("name").map { "Plan: \($0)" } ?? "Plan"
        await session.emitToolCall(id: toolCallId, name: title, arguments: .object(["plan": .string(plan)]))
        guard let decision = await session.proposePlan(callID: toolCallId, title: title, plan: plan) else {
            return Self.outcome("cancelled")
        }
        switch decision {
        case .approve:
            await session.finishToolCall(id: toolCallId, output: "Plan approved.")
            return Self.outcome("accepted")
        case .revise(let feedback):
            let reason = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
            await session.finishToolCall(id: toolCallId, output: reason.isEmpty ? "Keep planning." : "Keep planning: \(reason)")
            return Self.outcome("rejected", ["reason": .string(reason.isEmpty ? "The user asked to keep planning." : reason)])
        }
    }

    // MARK: - Checklist

    struct Todo: Equatable {
        var id: String
        var content: String
        var status: String

        var todoItem: TodoItem {
            switch status {
            case "completed": TodoItem(content, .completed)
            case "in_progress": TodoItem(content, .inProgress)
            case "cancelled": TodoItem("\(content) (cancelled)", .completed)
            default: TodoItem(content, .pending)
            }
        }

        var jsonValue: JSONValue {
            .object(["id": .string(id), "content": .string(content), "status": .string(status)])
        }
    }

    /// Applies an update and returns the whole list in order. `merge: false` (or absent) replaces it.
    func updateTodos(_ params: JSONValue) -> [Todo] {
        let incoming: [Todo] = (params["todos"]?.arrayValue ?? []).enumerated().compactMap { index, value in
            let content = value.string("content") ?? ""
            guard !content.isEmpty else { return nil }
            return Todo(id: value.string("id") ?? "todo-\(index)", content: content, status: value.string("status") ?? "pending")
        }
        let merge = params.bool("merge")
        return lock.withLock {
            if !merge {
                todoOrder = []
                todos = [:]
            }
            for todo in incoming {
                if todos[todo.id] == nil { todoOrder.append(todo.id) }
                todos[todo.id] = todo
            }
            return todoOrder.compactMap { todos[$0] }
        }
    }

    // MARK: - Subagents and images

    private func showActivity(method: String, params: JSONValue, session: ACPClientSession) async {
        let toolCallId = params.string("toolCallId") ?? UUID().uuidString
        let description = params.string("description") ?? ""
        let name: String
        if method == "cursor/task" {
            let kind = params.string("subagentType") ?? params["subagentType"]?.string("custom") ?? "subagent"
            name = description.isEmpty ? "Subagent (\(kind))" : "Subagent: \(description)"
        } else {
            name = description.isEmpty ? "Generate image" : "Generate image: \(description)"
        }
        await session.emitToolCall(id: toolCallId, name: name, arguments: params)
    }

    // MARK: - Helpers

    static func outcome(_ kind: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var inner: [String: JSONValue] = ["outcome": .string(kind)]
        for (key, value) in extra { inner[key] = value }
        return .object(["outcome": .object(inner)])
    }

    struct Question {
        struct Option { var id: String; var label: String }
        var id: String
        var prompt: String
        var options: [Option]
        var allowMultiple: Bool

        init(jsonValue: JSONValue) {
            id = jsonValue.string("id") ?? "q"
            prompt = jsonValue.string("prompt") ?? jsonValue.string("question") ?? ""
            options = (jsonValue["options"]?.arrayValue ?? []).compactMap { option in
                guard let id = option.string("id") else { return nil }
                return Option(id: id, label: option.string("label") ?? id)
            }
            allowMultiple = jsonValue.bool("allowMultiple")
        }

        /// Option ids the answer names, by label or id, ignoring case and surrounding space. A
        /// multiple-choice question also takes a comma-separated list.
        func match(_ answer: String) -> [String] {
            let parts = allowMultiple ? answer.split(separator: ",").map(String.init) : [answer]
            var ids: [String] = []
            for part in parts {
                let wanted = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let option = options.first(where: {
                    $0.label.compare(wanted, options: .caseInsensitive) == .orderedSame
                        || $0.id.compare(wanted, options: .caseInsensitive) == .orderedSame
                }) else { return [] }
                if !ids.contains(option.id) { ids.append(option.id) }
            }
            return ids
        }

        func labels(for ids: [String]) -> [String] {
            ids.compactMap { id in options.first { $0.id == id }?.label }
        }
    }
}
