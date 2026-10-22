import Foundation

public enum ToolRisk: Sendable, Hashable {
    case read
    case edit
    case command
}

public struct ToolOutput: Sendable, Hashable {
    public let text: String
    public let isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func error(_ text: String) -> ToolOutput { ToolOutput("Error: \(text)", isError: true) }
}

/// What the host's output shaper sees for one finished call.
public struct ToolOutputShapingInput: Sendable {
    public var toolName: String
    public var arguments: String
    public var risk: ToolRisk
    public var isError: Bool
    public var text: String

    public init(toolName: String, arguments: String, risk: ToolRisk, isError: Bool, text: String) {
        self.toolName = toolName
        self.arguments = arguments
        self.risk = risk
        self.isError = isError
        self.text = text
    }
}

public struct ToolError: Error, Sendable, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Typed access to a call's JSON arguments. Strict mode sends `null` for an omitted optional
/// parameter, so `null` reads as absent everywhere.
///
/// Models (local ones above all) get the shape of a value wrong in ways that cannot be misread, and
/// the accessors know which type the caller wants, so they accept those: `"20"` for an integer,
/// `"true"` for a boolean, a JSON array written as a string for a list, and `{}`
/// where an optional scalar was left out. A value that could mean two things still fails with the
/// message below, so nothing is guessed.
public struct ToolArguments: Sendable {
    private let object: [String: JSONValue]

    /// Models send `""` or `{}` for a call without arguments, and some send the object as a JSON
    /// string inside a string.
    public init(json text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { object = [:]; return }
        guard var value = try? JSONValue(parsing: trimmed) else {
            throw ToolError("The arguments were not a valid JSON object.")
        }
        if case .string(let inner) = value, let unwrapped = try? JSONValue(parsing: inner), case .object = unwrapped {
            value = unwrapped
        }
        guard case .object(let object) = value else {
            throw ToolError("The arguments were not a valid JSON object.")
        }
        self.object = object
    }

    public init(_ object: [String: JSONValue]) { self.object = object }

    /// The arguments as they came, without the `null`s a strict-mode caller sends for what it left out:
    /// for a tool whose schema someone else wrote (`MCPTool`), which wants a missing key, not a null.
    public var presentValues: [String: JSONValue] { object.filter { $0.value != .null } }

    /// The value for `key`, or `nil` when it is absent: missing, `null`, or the empty object some
    /// models send for an optional parameter they skip.
    private func value(_ key: String) -> JSONValue? {
        switch object[key] {
        case nil, .null?: return nil
        case .object(let fields)? where fields.isEmpty: return nil
        case let value?: return value
        }
    }

    public func string(_ key: String) throws -> String {
        guard let value = try optionalString(key) else { throw ToolError("Missing required argument \"\(key)\".") }
        return value
    }

    public func optionalString(_ key: String) throws -> String? {
        switch value(key) {
        case nil: return nil
        case .string(let value)?: return value
        default: throw ToolError("Argument \"\(key)\" must be a string.")
        }
    }

    public func optionalInt(_ key: String) throws -> Int? {
        guard let value = value(key) else { return nil }
        if let int = value.intValue { return int }
        if case .string(let text) = value {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let int = Int(trimmed) { return int }
            if let double = Double(trimmed), let int = Int(exactly: double) { return int }
        }
        throw ToolError("Argument \"\(key)\" must be an integer.")
    }

    public func stringArray(_ key: String) throws -> [String] {
        guard let value = try optionalStringArray(key) else { throw ToolError("Missing required argument \"\(key)\".") }
        return value
    }

    public func optionalStringArray(_ key: String) throws -> [String]? {
        guard let value = value(key) else { return nil }
        switch value {
        case .array(let items):
            return try items.map {
                guard let text = $0.stringValue else { throw ToolError("Every item of \"\(key)\" must be a string.") }
                return text
            }
        case .string(let text):
            // A list written as a JSON string. Any other string stays an error: for a checklist or a
            // list of paths, "one item" and "not a list" are different mistakes.
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("["),
               let parsed = try? JSONValue(parsing: text), case .array(let items) = parsed {
                let strings = items.compactMap(\.stringValue)
                if strings.count == items.count { return strings }
            }
            throw ToolError("Argument \"\(key)\" must be a list of strings.")
        default: throw ToolError("Argument \"\(key)\" must be a list of strings.")
        }
    }

    public func optionalBool(_ key: String) throws -> Bool? {
        guard let value = value(key) else { return nil }
        if let bool = value.boolValue { return bool }
        if case .string(let text) = value {
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return true
            case "false": return false
            default: break
            }
        }
        throw ToolError("Argument \"\(key)\" must be true or false.")
    }
}

/// What a tool run may touch. `ledger` remembers what the model has read, for `edit_file` to refuse
/// a file that changed underneath it.
public struct ToolContext: Sendable {
    public let workspace: any AgentWorkspace
    public let ledger: ReadLedger
    public let callID: String
    /// Set while a session runs the tool; tools that change files record through it first.
    public let checkpoint: CheckpointScope?
    /// Live output for the transcript while the tool runs (a command's stdout). The model still
    /// gets only the tool's final output.
    public let progress: (@Sendable (String) -> Void)?
    /// Puts a question to the user and waits. `nil` result: they stopped the run or dismissed it.
    public let ask: (@Sendable (UserQuestion) async -> String?)?
    /// Shows the user a plan and waits for their decision. Stop answers with `.revise("")`.
    public let proposePlan: (@Sendable (String) async -> PlanDecision)?
    /// The session's checklist, for `todo`.
    public let todos: TodoList?
    /// How `edit_file` and `apply_patch` recover a unique near-miss. Exact matching always runs first.
    public let editTolerance: EditTolerance
    /// Failed edits in this run, so the third miss on one file suggests `write_file`.
    public let editFailures: EditFailureLog?
    /// Nested instruction files, appended once per directory.
    public let projectNotes: ProjectNoteTracker?
    /// Tells the session a file tool succeeded on `path` (conditional skills).
    public let fileTouched: (@Sendable (String) -> Void)?
    /// Redacts a line before it is persisted outside the history (`remember`). The session wires
    /// the configured output shaper; `nil` keeps the text as the model wrote it.
    public let redactForMemory: (@Sendable (String) async -> String)?
    /// Runs a child session for read-only research (`explore`). `nil` when the host session does
    /// not offer subagents. The session counts the child's tokens against this run's budget.
    public let spawnSubagent: (@Sendable (SubagentRequest) async -> SubagentResult)?
    /// Hands a task to a subagent (`task`). `nil` when the host session does not offer them.
    public let delegate: (@Sendable (DelegationRequest) async -> DelegationResult)?
    /// True when the permission rules already allowed this call outright (an allow rule or a safe
    /// default), rather than the user approving its card. A tool that degrades gracefully (the
    /// sandbox retry) may skip asking again.
    public let preapproved: Bool
    /// Where output too large to show is kept (see `OutputTruncation.headAndTailSaving`). `nil`: it is
    /// cut and the middle is lost.
    public let outputStore: (any ToolOutputStore)?
    /// Scrubs text the way this call's output is scrubbed before it enters the history (the configured
    /// shaper, with this call's tool name and risk). A copy saved to disk goes through it first.
    public let redactOutput: (@Sendable (String) async -> String)?

    public init(
        workspace: any AgentWorkspace,
        ledger: ReadLedger,
        callID: String,
        checkpoint: CheckpointScope? = nil,
        progress: (@Sendable (String) -> Void)? = nil,
        ask: (@Sendable (UserQuestion) async -> String?)? = nil,
        todos: TodoList? = nil,
        proposePlan: (@Sendable (String) async -> PlanDecision)? = nil,
        editTolerance: EditTolerance = .hosted,
        editFailures: EditFailureLog? = nil,
        projectNotes: ProjectNoteTracker? = nil,
        fileTouched: (@Sendable (String) -> Void)? = nil,
        redactForMemory: (@Sendable (String) async -> String)? = nil,
        spawnSubagent: (@Sendable (SubagentRequest) async -> SubagentResult)? = nil,
        delegate: (@Sendable (DelegationRequest) async -> DelegationResult)? = nil,
        preapproved: Bool = false,
        outputStore: (any ToolOutputStore)? = nil,
        redactOutput: (@Sendable (String) async -> String)? = nil
    ) {
        self.outputStore = outputStore
        self.redactOutput = redactOutput
        self.workspace = workspace
        self.ledger = ledger
        self.callID = callID
        self.checkpoint = checkpoint
        self.progress = progress
        self.ask = ask
        self.todos = todos
        self.proposePlan = proposePlan
        self.editTolerance = editTolerance
        self.editFailures = editFailures
        self.projectNotes = projectNotes
        self.fileTouched = fileTouched
        self.redactForMemory = redactForMemory
        self.spawnSubagent = spawnSubagent
        self.delegate = delegate
        self.preapproved = preapproved
    }

    /// Appends a nested instruction file the first time `path`'s folder is touched, and tells the
    /// session the path was touched. The system prompt is left alone.
    public func finishFileTool(_ text: String, path: String) async -> String {
        fileTouched?(path)
        let rootURL = URL(fileURLWithPath: workspace.rootPath)
        guard let extra = await projectNotes?.textToAppend(for: path, root: rootURL) else { return text }
        return text + "\n\n" + extra
    }
}

/// What a delegated research call asks the session to run.
public struct SubagentRequest: Sendable {
    /// The parent's tool-call id, so progress events tie back to the call.
    public var id: String
    public var task: String
    public var maxIterations: Int
    /// When set, the child asks this client instead of sharing the parent's. Tests use one scripted
    /// client per side; production shares the parent's client, model and permission rules.
    public var client: (any LLMClient)?

    public init(id: String, task: String, maxIterations: Int, client: (any LLMClient)? = nil) {
        self.id = id
        self.task = task
        self.maxIterations = maxIterations
        self.client = client
    }
}

/// What the child session brought back. `usage` is the child's whole run; the session adds it to
/// the parent run's budget.
public struct SubagentResult: Sendable {
    public var summary: String
    public var usage: TokenUsage
    public var ending: RunEnding

    public init(summary: String, usage: TokenUsage, ending: RunEnding) {
        self.summary = summary
        self.usage = usage
        self.ending = ending
    }
}

/// A hash of the text the model last saw for each file.
public actor ReadLedger {
    private var seen: [String: UInt64] = [:]

    public init(snapshot: [String: UInt64] = [:]) {
        self.seen = snapshot
    }

    /// What this ledger holds, so a child session can start from a copy.
    public func snapshot() -> [String: UInt64] { seen }

    public func record(path: String, text: String) { seen[path] = Self.hash(text) }
    /// Forgets everything the model was shown, as after a rewind: it must read before it edits again.
    public func removeAll() { seen.removeAll() }
    public func hasRead(_ path: String) -> Bool { seen[path] != nil }
    /// `true` only if the model read this file and its text is unchanged since.
    public func isCurrent(path: String, text: String) -> Bool { seen[path] == Self.hash(text) }

    /// FNV-1a: stable across launches, which `Hasher` is not.
    static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }
}

/// A tool the model can call. A thrown error becomes an output the model can act on, never an error
/// that ends the run. Tools should honor task cancellation: Stop and the tool timeout stop waiting
/// for a tool that does not, and its late result is dropped.
public protocol AgentTool: Sendable {
    var definition: ToolDefinition { get }
    var risk: ToolRisk { get }
    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String
    /// What to ask the user first. `nil` runs without asking. Only consulted for `.command` tools.
    func approvalRequest(for arguments: ToolArguments, context: ToolContext) async -> ApprovalRequest?
    /// For `.edit` tools: what the call would change, without changing it. `nil` if it can't be
    /// worked out; the call is then left to run (and fail) as usual.
    func editPreview(for arguments: ToolArguments, context: ToolContext) async -> EditPreview?
    /// True for a tool that waits on a person. It runs alone and is not cut off by the tool timeout.
    var waitsForUser: Bool { get }
    /// True for a tool whose identical repeat is harmless bookkeeping, not a stuck loop (`todo`).
    var isExemptFromRepeatGuard: Bool { get }
    /// What a permission rule can match against: the command, or the files the call would change.
    func permissionSubject(for arguments: ToolArguments) -> PermissionSubject
    /// Whether the model is told about the tool in this mode. By default what the mode offers by risk.
    func isOffered(in mode: PermissionMode) -> Bool
    /// When true, a deny rule naming this tool is honored even though reads otherwise skip rules.
    /// Set by a read that sends data off the machine (`web_search`). Ask and allow rules still are not.
    var honorsDenyRules: Bool { get }
    /// When true, a successful call counts as checking the files this run changed (`diagnostics`,
    /// `run_tests`, `gradle`).
    var verifies: Bool { get }
    /// When true, the call asks first in a run that used web search or read untrusted content, even
    /// when the rules would allow it (`remember`, so prompt-injected text is not quietly persisted).
    var asksAfterUntrustedContent: Bool { get }
    /// A file tool touched `path`. Skills with a `paths` filter use this; other tools ignore it.
    func noteFileTouched(_ path: String)
    /// True for a tool that is bounded by something else (a child's iteration cap, and Stop), so the
    /// session's per-tool timeout would only cut off work that is going well (`task`).
    var runsWithoutTimeout: Bool { get }
    /// True for a read that sends a request off this Mac (`web_fetch`): unlike other reads it goes
    /// through the user's rules and, unless an allow rule names the call, asks first. It runs alone.
    var asksUnlessAllowed: Bool { get }
    /// For a tool with `asksUnlessAllowed`: why this call can never run, known before anything is
    /// asked. The call is answered with it and the user sees no card for something that would be refused.
    func refusalBeforeAsking(for arguments: ToolArguments) -> String?
    /// True for an `.edit` tool that reports the files it changed itself, as they happen, instead of
    /// the session counting the call as one edit (`task`: a read-only child changed nothing).
    var reportsOwnEdits: Bool { get }
}

extension AgentTool {
    public var name: String { definition.name }

    public func approvalRequest(for arguments: ToolArguments, context: ToolContext) async -> ApprovalRequest? { nil }
    public func editPreview(for arguments: ToolArguments, context: ToolContext) async -> EditPreview? { nil }
    public var waitsForUser: Bool { false }
    public var isExemptFromRepeatGuard: Bool { false }
    public var honorsDenyRules: Bool { false }
    public var verifies: Bool { false }
    public var asksAfterUntrustedContent: Bool { false }
    public func noteFileTouched(_ path: String) {}
    public var runsWithoutTimeout: Bool { false }
    public var asksUnlessAllowed: Bool { false }
    public func refusalBeforeAsking(for arguments: ToolArguments) -> String? { nil }
    public var reportsOwnEdits: Bool { false }

    public func isOffered(in mode: PermissionMode) -> Bool { mode.offers(risk) }

    /// A `command` argument is a command; otherwise a `path` argument is the file the call changes.
    public func permissionSubject(for arguments: ToolArguments) -> PermissionSubject {
        if let command = try? arguments.optionalString("command") { return .command(command) }
        if let path = try? arguments.optionalString("path") { return .paths([path]) }
        return .none
    }

    /// Parses, runs and converts every failure into a `ToolOutput`.
    public func execute(argumentsJSON: String, context: ToolContext) async -> ToolOutput {
        do {
            return ToolOutput(try await run(try ToolArguments(json: argumentsJSON), context: context))
        } catch is CancellationError {
            return .error("Cancelled.")
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
