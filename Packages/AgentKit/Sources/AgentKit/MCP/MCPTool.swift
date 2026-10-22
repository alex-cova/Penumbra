import Foundation

/// One tool of one MCP server, as the model calls it: `mcp__<server>__<tool>`. It runs code the user
/// installed somewhere else, so it asks like a command does (`.command`: plan mode never offers it,
/// Auto mode never runs it unasked) unless a rule names it, and what comes back is untrusted data.
public struct MCPTool: AgentTool {
    public static let maxDescriptionLength = 1_500
    public static let maxOutputCharacters = 30_000

    public let name: String
    public let server: String
    public let remoteName: String
    private let info: MCPToolInfo
    private let hub: MCPHub

    init(name: String, server: String, info: MCPToolInfo, hub: MCPHub) {
        self.name = name
        self.server = server
        self.remoteName = info.name
        self.info = info
        self.hub = hub
    }

    public var risk: ToolRisk { .command }
    public var runsWithoutTimeout: Bool { true }

    public var definition: ToolDefinition {
        var description = info.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if description.count > Self.maxDescriptionLength { description = String(description.prefix(Self.maxDescriptionLength)) + "…" }
        let prefix = "[MCP server \(server)] "
        return ToolDefinition(name: name, description: prefix + (description.isEmpty ? info.title ?? info.name : description), rawSchema: info.inputSchema)
    }

    public func permissionSubject(for arguments: ToolArguments) -> PermissionSubject { .none }

    public func approvalRequest(for arguments: ToolArguments, context: ToolContext) async -> ApprovalRequest? {
        let text = (try? arguments.jsonText()) ?? ""
        var notes = ["\(info.name) runs on the MCP server “\(server)”, a program on this Mac that can do whatever it was written to do."]
        if info.readOnlyHint == true { notes.append("The server says this tool only reads. That is the server's claim, not something Umbra checks.") }
        return ApprovalRequest(
            title: "Use \(server): \(info.title ?? info.name)",
            command: text.count > 2_000 ? String(text.prefix(2_000)) + "…" : text,
            notes: notes, suggestedRule: name)
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let result: MCPToolResult
        do {
            result = try await hub.call(server: server, tool: remoteName, arguments: arguments.jsonValue)
        } catch let error as MCPError {
            throw ToolError("\(server): \(error.localizedDescription)")
        }
        let text = result.text.isEmpty ? "(The tool returned no content.)" : result.text
        if result.isError { throw ToolError("\(server): \(text)") }
        let shown = await OutputTruncation.headAndTailSaving(text, maxCharacters: Self.maxOutputCharacters, headShare: 0.6, context: context)
        return UntrustedContent.wrap(shown, source: "mcp:\(server)")
    }
}

extension ToolArguments {
    /// The arguments as the JSON object they came in, for a server and for the approval card.
    var jsonValue: JSONValue { .object(presentValues) }

    func jsonText() throws -> String { try jsonValue.serialized() }
}
