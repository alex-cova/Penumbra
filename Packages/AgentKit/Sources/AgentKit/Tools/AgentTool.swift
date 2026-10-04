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

public struct ToolError: Error, Sendable, Equatable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Typed access to a call's JSON arguments. Strict mode sends `null` for an omitted optional
/// parameter, so `null` reads as absent everywhere.
public struct ToolArguments: Sendable {
    private let object: [String: JSONValue]

    /// Models send `""` or `{}` for a call without arguments.
    public init(json text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { object = [:]; return }
        guard let value = try? JSONValue(parsing: trimmed), case .object(let object) = value else {
            throw ToolError("The arguments were not a valid JSON object.")
        }
        self.object = object
    }

    public init(_ object: [String: JSONValue]) { self.object = object }

    public func string(_ key: String) throws -> String {
        guard let value = try optionalString(key) else { throw ToolError("Missing required argument \"\(key)\".") }
        return value
    }

    public func optionalString(_ key: String) throws -> String? {
        switch object[key] {
        case nil, .null: return nil
        case .string(let value): return value
        default: throw ToolError("Argument \"\(key)\" must be a string.")
        }
    }

    public func optionalInt(_ key: String) throws -> Int? {
        switch object[key] {
        case nil, .null: return nil
        case let value?:
            guard let int = value.intValue else { throw ToolError("Argument \"\(key)\" must be an integer.") }
            return int
        }
    }

    public func stringArray(_ key: String) throws -> [String] {
        guard let value = try optionalStringArray(key) else { throw ToolError("Missing required argument \"\(key)\".") }
        return value
    }

    public func optionalStringArray(_ key: String) throws -> [String]? {
        switch object[key] {
        case nil, .null: return nil
        case .array(let items)?:
            return try items.map {
                guard let text = $0.stringValue else { throw ToolError("Every item of \"\(key)\" must be a string.") }
                return text
            }
        default: throw ToolError("Argument \"\(key)\" must be a list of strings.")
        }
    }

    public func optionalBool(_ key: String) throws -> Bool? {
        switch object[key] {
        case nil, .null: return nil
        case let value?:
            guard let bool = value.boolValue else { throw ToolError("Argument \"\(key)\" must be true or false.") }
            return bool
        }
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
    /// The session's checklist, for `todo`.
    public let todos: TodoList?

    public init(
        workspace: any AgentWorkspace,
        ledger: ReadLedger,
        callID: String,
        checkpoint: CheckpointScope? = nil,
        progress: (@Sendable (String) -> Void)? = nil,
        ask: (@Sendable (UserQuestion) async -> String?)? = nil,
        todos: TodoList? = nil
    ) {
        self.workspace = workspace
        self.ledger = ledger
        self.callID = callID
        self.checkpoint = checkpoint
        self.progress = progress
        self.ask = ask
        self.todos = todos
    }
}

/// A hash of the text the model last saw for each file.
public actor ReadLedger {
    private var seen: [String: UInt64] = [:]

    public init() {}

    public func record(path: String, text: String) { seen[path] = Self.hash(text) }
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
/// that ends the run. Tools must honor task cancellation: Stop and timeouts rely on it.
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
}

extension AgentTool {
    public var name: String { definition.name }

    public func approvalRequest(for arguments: ToolArguments, context: ToolContext) async -> ApprovalRequest? { nil }
    public func editPreview(for arguments: ToolArguments, context: ToolContext) async -> EditPreview? { nil }
    public var waitsForUser: Bool { false }
    public var isExemptFromRepeatGuard: Bool { false }

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
