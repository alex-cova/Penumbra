import Foundation
import Testing
@testable import AgentKit

// MARK: - A fake server

/// An MCP server on the other end of an in-memory pipe, answering from closures.
final class FakeMCPServer: @unchecked Sendable {
    struct Tool {
        var name: String
        var description = "does a thing"
        var schema: JSONValue = ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]
        var readOnly: Bool?
    }

    let connection: ACPConnection
    let lock = NSLock()
    private var _seen: [String] = []
    private var _initializeParams: JSONValue?
    private var _callArguments: [JSONValue] = []

    var version = "2025-06-18"
    var hasToolsCapability = true
    var instructions: String?
    var pages: [[Tool]]
    var respondToInitialize = true
    var call: @Sendable (String, JSONValue) -> Result<JSONValue, JSONRPCError> = { name, arguments in
        .success(["content": [["type": "text", "text": .string("called \(name) with \((try? arguments.serialized()) ?? "")")]]])
    }

    init(transport: ACPInMemoryTransport, tools: [Tool] = [Tool(name: "echo")], pages: [[Tool]]? = nil, configure: (FakeMCPServer) -> Void = { _ in }) {
        connection = ACPConnection(transport: transport)
        self.pages = pages ?? [tools]
        configure(self)
        let box = self
        Task {
            await box.connection.setRequestHandler { method, params in box.handle(method, params) }
            await box.connection.setNotificationHandler { method, _ in box.lock.withLock { box._seen.append(method) } }
            await box.connection.start()
        }
    }

    var seen: [String] { lock.withLock { _seen } }
    var initializeParams: JSONValue? { lock.withLock { _initializeParams } }
    var callArguments: [JSONValue] { lock.withLock { _callArguments } }

    private func handle(_ method: String, _ params: JSONValue?) -> Result<JSONValue, JSONRPCError> {
        lock.withLock { _seen.append(method) }
        switch method {
        case "initialize":
            lock.withLock { _initializeParams = params }
            if !respondToInitialize { return .failure(JSONRPCError(code: -1, message: "never")) }
            var result: [String: JSONValue] = [
                "protocolVersion": .string(version), "serverInfo": ["name": "fake", "version": "1"],
                "capabilities": hasToolsCapability ? ["tools": [:]] : [:],
            ]
            if let instructions { result["instructions"] = .string(instructions) }
            return .success(.object(result))
        case "tools/list":
            let index = params?["cursor"]?.stringValue.flatMap(Int.init) ?? 0
            let page = index < pages.count ? pages[index] : []
            var result: [String: JSONValue] = ["tools": .array(page.map { tool in
                var object: [String: JSONValue] = ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.schema]
                if let readOnly = tool.readOnly { object["annotations"] = ["readOnlyHint": .bool(readOnly)] }
                return .object(object)
            })]
            if index + 1 < pages.count { result["nextCursor"] = .string(String(index + 1)) }
            return .success(.object(result))
        case "tools/call":
            let name = params?["name"]?.stringValue ?? ""
            let arguments = params?["arguments"] ?? .object([:])
            lock.withLock { _callArguments.append(arguments) }
            return call(name, arguments)
        case "ping":
            return .success(.object([:]))
        default:
            return .failure(.methodNotFound(method))
        }
    }

    func stop() async { await connection.close() }
}

private func connectedClient(
    tools: [FakeMCPServer.Tool] = [FakeMCPServer.Tool(name: "echo")], configure: (FakeMCPServer) -> Void = { _ in }
) async throws -> (MCPClient, FakeMCPServer) {
    let (clientEnd, serverEnd) = ACPInMemoryTransport.pair()
    let server = FakeMCPServer(transport: serverEnd, tools: tools, configure: configure)
    let client = MCPClient(transport: clientEnd)
    try await client.start(timeout: .seconds(5))
    return (client, server)
}

// MARK: - Client

@Suite struct MCPClientTests {
    @Test func theHandshakeSendsOurVersionAndNameThenInitialized() async throws {
        let (client, server) = try await connectedClient { $0.instructions = "Use me for tickets." }
        let params = try #require(server.initializeParams)
        #expect(params["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(params["clientInfo"]?["name"]?.stringValue == "Umbra")
        #expect(params["capabilities"] == .object([:]), "no optional capability is offered")
        try await Task.sleep(for: .milliseconds(50))
        #expect(server.seen == ["initialize", "notifications/initialized"])
        #expect(await client.serverName == "fake")
        #expect(await client.serverInstructions == "Use me for tickets.")
    }

    @Test func aVersionWeDoNotSpeakIsRefused() async throws {
        let (clientEnd, serverEnd) = ACPInMemoryTransport.pair()
        _ = FakeMCPServer(transport: serverEnd) { $0.version = "2030-01-01" }
        let client = MCPClient(transport: clientEnd)
        await #expect(throws: MCPError.unsupportedVersion("2030-01-01")) { try await client.start(timeout: .seconds(5)) }
    }

    @Test func olderVersionsWeKnowAreAccepted() async throws {
        let (client, _) = try await connectedClient { $0.version = "2024-11-05" }
        #expect(try await client.listTools().count == 1)
    }

    @Test func toolsAreListedAcrossPagesWithTheirSchemasAndHints() async throws {
        let (clientEnd, serverEnd) = ACPInMemoryTransport.pair()
        _ = FakeMCPServer(transport: serverEnd, pages: [
            [.init(name: "a", description: "first", readOnly: true)], [.init(name: "b")], [.init(name: "c")],
        ])
        let client = MCPClient(transport: clientEnd)
        try await client.start(timeout: .seconds(5))
        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["a", "b", "c"])
        #expect(tools[0].description == "first")
        #expect(tools[0].readOnlyHint == true)
        #expect(tools[1].readOnlyHint == nil)
        #expect(tools[0].inputSchema["properties"]?["text"]?["type"]?.stringValue == "string")
    }

    @Test func aServerWithoutToolsHasNoneAndIsNotAsked() async throws {
        let (client, server) = try await connectedClient { $0.hasToolsCapability = false }
        #expect(try await client.listTools().isEmpty)
        #expect(!server.seen.contains("tools/list"))
    }

    @Test func resultBlocksBecomeText() async throws {
        let (client, _) = try await connectedClient {
            $0.call = { _, _ in .success([
                "content": [
                    ["type": "text", "text": "line one"],
                    ["type": "image", "data": "AAAA", "mimeType": "image/png"],
                    ["type": "resource", "resource": ["uri": "file:///a.txt", "text": "from a resource"]],
                    ["type": "resource", "resource": ["uri": "file:///b.bin", "blob": "AAAA"]],
                    ["type": "resource_link", "name": "docs", "uri": "https://x.test/docs"],
                    ["type": "text", "text": "line two"],
                ],
            ]) }
        }
        let result = try await client.callTool(name: "t", arguments: .object([:]), timeout: .seconds(5))
        #expect(!result.isError)
        #expect(result.text == """
        line one
        [image content (image/png) not shown]
        [file:///a.txt]
        from a resource
        [resource file:///b.bin not shown]
        [link docs: https://x.test/docs]
        line two
        """)
    }

    @Test func structuredContentAloneIsStillHeardAndIsErrorIsCarried() async throws {
        let (client, _) = try await connectedClient {
            $0.call = { name, _ in
                name == "bad"
                    ? .success(["content": [["type": "text", "text": "it broke"]], "isError": true])
                    : .success(["structuredContent": ["count": 3]])
            }
        }
        let ok = try await client.callTool(name: "good", arguments: .object([:]), timeout: .seconds(5))
        #expect(ok.text == #"{"count":3}"#)
        let bad = try await client.callTool(name: "bad", arguments: .object([:]), timeout: .seconds(5))
        #expect(bad.isError && bad.text == "it broke")
    }

    @Test func rpcErrorsTimeoutsAndAStoppedServerAreDistinct() async throws {
        let (client, server) = try await connectedClient {
            $0.call = { name, _ in
                if name == "fail" { return .failure(JSONRPCError(code: -32602, message: "bad arguments")) }
                return .failure(JSONRPCError(code: -1, message: "unused"))
            }
        }
        await #expect(throws: MCPError.server(code: -32602, message: "bad arguments")) {
            _ = try await client.callTool(name: "fail", arguments: .object([:]), timeout: .seconds(5))
        }
        await server.stop()
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: MCPError.closed) {
            _ = try await client.callTool(name: "x", arguments: .object([:]), timeout: .seconds(5))
        }
        #expect(await client.isClosed)
    }

    @Test func aServerThatNeverAnswersTimesOut() async throws {
        let (clientEnd, serverEnd) = ACPInMemoryTransport.pair()
        _ = serverEnd // nobody reads it
        let client = MCPClient(transport: clientEnd)
        await #expect(throws: MCPError.timedOut("the handshake")) { try await client.start(timeout: .milliseconds(100)) }
    }

    @Test func pingIsAnsweredAndOtherServerRequestsAreRefused() async throws {
        let (clientEnd, serverEnd) = ACPInMemoryTransport.pair()
        let server = FakeMCPServer(transport: serverEnd)
        let client = MCPClient(transport: clientEnd)
        try await client.start(timeout: .seconds(5))
        let pong = try await server.connection.request(method: "ping", timeout: .seconds(2))
        #expect(pong == .object([:]))
        await #expect(throws: ACPError.self) {
            _ = try await server.connection.request(method: "sampling/createMessage", params: .object([:]), timeout: .seconds(2))
        }
    }
}

// MARK: - Configuration and names

@Suite struct MCPConfigTests {
    @Test func aClaudeStyleFileIsReadAndHttpServersAreReported() throws {
        let file = try MCPConfigFile.parse(Data("""
        {"mcpServers": {
          "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"], "env": {"TOKEN": "abc", "N": 3}},
          "remote": {"type": "http", "url": "https://x.test/mcp"},
          "sse": {"url": "https://x.test/sse"},
          "empty": {"args": ["x"]},
          "weird": 5
        }}
        """.utf8))
        #expect(file.servers == [MCPServerConfig(name: "github", command: "npx", args: ["-y", "@modelcontextprotocol/server-github"], env: ["TOKEN": "abc"])])
        #expect(Dictionary(uniqueKeysWithValues: file.skipped.map { ($0.name, $0.reason) }).keys.sorted() == ["empty", "remote", "sse", "weird"])
        #expect(file.skipped.first { $0.name == "remote" }?.reason.contains("http") == true)
    }

    @Test func theVSCodeShapeAndEmptyFilesWork() throws {
        let vscode = try MCPConfigFile.parse(Data(#"{"servers": {"a": {"type": "stdio", "command": "uvx", "args": ["tool"]}}}"#.utf8))
        #expect(vscode.servers.map(\.command) == ["uvx"])
        #expect(try MCPConfigFile.parse(Data("{}".utf8)).servers.isEmpty)
        #expect(throws: MCPConfigFile.ParseError.notJSON) { try MCPConfigFile.parse(Data("nope".utf8)) }
        #expect(throws: MCPConfigFile.ParseError.notJSON) { try MCPConfigFile.parse(Data("[1]".utf8)) }
        #expect(throws: MCPConfigFile.ParseError.tooLarge) { try MCPConfigFile.parse(Data(count: MCPConfigFile.maxFileBytes + 1)) }
    }

    @Test func whatWouldRunDecidesTheCanonicalText() {
        let base = MCPServerConfig(name: "a", command: "npx", args: ["x"], env: ["K": "v"])
        #expect(base.canonicalText == MCPServerConfig(name: "a", command: "npx", args: ["x"], env: ["K": "v"]).canonicalText)
        for changed in [
            MCPServerConfig(name: "b", command: "npx", args: ["x"], env: ["K": "v"]),
            MCPServerConfig(name: "a", command: "npy", args: ["x"], env: ["K": "v"]),
            MCPServerConfig(name: "a", command: "npx", args: ["y"], env: ["K": "v"]),
            MCPServerConfig(name: "a", command: "npx", args: ["x"], env: ["K": "w"]),
            MCPServerConfig(name: "a", command: "npx", args: ["x"], env: ["K": "v", "L": "1"]),
            MCPServerConfig(name: "a", command: "npx", args: ["x", ""], env: ["K": "v"]),
        ] { #expect(changed.canonicalText != base.canonicalText) }
    }

    @Test func toolNamesFitBothApisAndStayDistinct() {
        #expect(MCPNaming.toolName(server: "github", tool: "create_issue") == "mcp__github__create_issue")
        let odd = MCPNaming.toolName(server: "s", tool: "do.thing/now")
        #expect(odd.hasPrefix("mcp__s__do_thing_now_"))
        let long1 = MCPNaming.toolName(server: "server", tool: String(repeating: "a", count: 80) + "1")
        let long2 = MCPNaming.toolName(server: "server", tool: String(repeating: "a", count: 80) + "2")
        #expect(long1.count <= 64 && long2.count <= 64)
        #expect(long1 != long2)
        for name in [odd, long1, MCPNaming.toolName(server: "s", tool: "ünï")] {
            #expect(name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }, "\(name)")
        }
        #expect(MCPServerConfig(name: "My Server!", command: "x").identifier == "My_Server")
        #expect(MCPServerConfig(name: "!!!", command: "x").identifier == "server")
    }
}
