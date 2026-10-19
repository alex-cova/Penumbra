import Foundation

/// Saves one durable fact to the project's memory file (`ProjectMemory`). A recall layer, not
/// instructions: what it saves is read back into later sessions under a "may be stale" heading,
/// and the project's files and instructions win. Risk is `.edit`, so plan mode never offers it;
/// approval comes from the session's rules (the host adds an ask rule for it) or from a run that
/// saw untrusted content.
public struct RememberTool: AgentTool {
    public let memoryDirectory: URL
    public var today: @Sendable () -> String

    public init(memoryDirectory: URL, today: @escaping @Sendable () -> String = RememberTool.currentDate) {
        self.memoryDirectory = memoryDirectory
        self.today = today
    }

    public var risk: ToolRisk { .edit }

    public var asksAfterUntrustedContent: Bool { true }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "remember",
            description: """
            Save one durable fact about this project for later chats, such as a decision, a \
            convention, or something the user asked you to remember. One fact per call, at most \
            300 characters; a fact already remembered is skipped. Memories may be stale when they \
            are read back, so never save credentials, tokens, or private code.
            """,
            parameters: [
                ToolParameter("text", .string, "The fact to remember, in one line."),
            ])
    }

    public func permissionSubject(for arguments: ToolArguments) -> PermissionSubject {
        guard let text = try? arguments.string("text"), !text.isEmpty else { return .none }
        return .text(text)
    }

    public func editPreview(for arguments: ToolArguments, context: ToolContext) async -> EditPreview? {
        guard let text = try? arguments.string("text"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return EditPreview(summary: "Remember: \(String(text.prefix(120)))", diff: "")
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let text = try arguments.string("text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError("Give the fact to remember as \"text\".") }
        var line = text
        if let redact = context.redactForMemory {
            line = await redact(line)
        }
        let added = try ProjectMemory.append(line, at: memoryDirectory, date: today())
        return added ? "Saved to memory." : "That is already remembered; nothing was added."
    }

    public static func currentDate() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
