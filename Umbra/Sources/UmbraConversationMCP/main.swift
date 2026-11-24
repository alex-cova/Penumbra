import AgentKit
import Foundation

/// `umbra-conversation-mcp <archive.json>`: an MCP server on stdio with one tool, `read_conversation`, over the
/// earlier conversation Umbra handed an external ACP agent (`MCPConversationServer`,
/// `docs/harness/agent-harness-10.md`). Umbra writes the archive and lists this program in `session/new`'s
/// `mcpServers`; the agent starts it. The file is read at every call and nothing else is touched. Only MCP
/// frames go to stdout.
let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: umbra-conversation-mcp <archive.json>\n".utf8))
    exit(64)
}
let archive = URL(fileURLWithPath: arguments[1])
let server = MCPConversationServer { MCPConversationServer.turns(fromFile: archive) }
await server.serve(over: ACPStandardIOTransport())
