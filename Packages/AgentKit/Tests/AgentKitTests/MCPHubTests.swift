import Foundation
import Testing
@testable import AgentKit

/// Hands out fake servers, one per start, and remembers them.
private final class Servers: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [String: [FakeMCPServer]] = [:]
    var makeServer: @Sendable (MCPServerConfig, ACPInMemoryTransport) -> FakeMCPServer

    init(_ makeServer: @escaping @Sendable (MCPServerConfig, ACPInMemoryTransport) -> FakeMCPServer = { config, transport in
        FakeMCPServer(transport: transport, tools: [.init(name: "echo")])
    }) { self.makeServer = makeServer }

    func starts(of name: String) -> Int { lock.withLock { started[name]?.count ?? 0 } }
    func servers(_ name: String) -> [FakeMCPServer] { lock.withLock { started[name] ?? [] } }

    var factory: MCPHub.TransportFactory {
        { [self] config in
            let (clientEnd, serverEnd) = ACPInMemoryTransport.pair()
            let server = makeServer(config, serverEnd)
            lock.withLock { started[config.name, default: []].append(server) }
            return clientEnd
        }
    }
}

private func config(_ name: String) -> MCPServerConfig { MCPServerConfig(name: name, command: "/bin/\(name)") }

private func session(_ hub: MCPHub, turns: [MockTurn], mode: PermissionMode = .acceptEdits, approval: ApprovalPolicy = .approveAll,
                     rules: PermissionRules = PermissionRules()) async throws -> (AgentSession, MockLLMClient) {
    let client = MockLLMClient(turns: turns)
    let project = try TempProject()
    return (AgentSession(
        client: client, tools: await hub.tools, workspace: project.workspace,
        configuration: AgentConfiguration(model: "m", approval: approval, mode: mode, permissions: rules)), client)
}

private func call(_ name: String, _ arguments: String = #"{"text":"hi"}"#) -> MockTurn {
    .toolCalls((id: "c1", name: name, arguments: arguments))
}

private func finalOutput(_ session: AgentSession) async -> String? {
    for case .toolOutput(_, let text) in await session.items { return text }
    return nil
}

@Suite struct MCPHubTests {
    @Test func serversConnectTogetherAndTheirToolsAreNamedAndOrdered() async throws {
        let servers = Servers { _, transport in
            FakeMCPServer(transport: transport, tools: [.init(name: "zeta"), .init(name: "alpha")])
        }
        let hub = MCPHub(servers: [config("beta"), config("alpha")], makeTransport: servers.factory)
        let statuses = await hub.start()
        #expect(statuses.map(\.name).sorted() == ["alpha", "beta"])
        #expect(statuses.allSatisfy { $0.state == .connected(tools: 2) })
        #expect(await hub.tools.map(\.name) == ["mcp__beta__alpha", "mcp__beta__zeta", "mcp__alpha__alpha", "mcp__alpha__zeta"],
                "in the order the servers were given, tools by name")
        await hub.close()
    }

    @Test func aServerThatFailsOrHangsIsReportedAndTheOthersWork() async throws {
        let servers = Servers { config, transport in
            FakeMCPServer(transport: transport) { $0.respondToInitialize = config.name != "silent" }
        }
        let factory: MCPHub.TransportFactory = { config in
            if config.name == "missing" { throw MCPError.server(code: 0, message: "Could not find “nope” on PATH.") }
            return try servers.factory(config)
        }
        let hub = MCPHub(servers: [config("ok"), config("missing"), config("silent")], connectTimeout: 0.4, makeTransport: factory)
        let started = Date()
        let statuses = Dictionary(uniqueKeysWithValues: await hub.start().map { ($0.name, $0.state) })
        #expect(statuses["ok"] == .connected(tools: 1))
        if case .failed(let reason)? = statuses["missing"] { #expect(reason.contains("PATH")) } else { Issue.record("missing should fail") }
        if case .failed? = statuses["silent"] {} else { Issue.record("silent should fail: \(String(describing: statuses["silent"]))") }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(await hub.tools.map(\.name) == ["mcp__ok__echo"])
        await hub.close()
    }

    @Test func twoServersWhoseNamesCleanUpAlikeKeepDistinctToolNames() async throws {
        let servers = Servers()
        let hub = MCPHub(servers: [config("my server"), config("my-server!"), config("my.server")], makeTransport: servers.factory)
        await hub.start()
        let names = await hub.tools.map(\.name)
        #expect(Set(names).count == 3, "\(names)")
        await hub.close()
    }

    @Test func aToolCarriesTheServersSchemaAndIsNeverStrict() async throws {
        let schema: JSONValue = ["type": "object", "properties": ["n": ["type": "integer"]], "$schema": "http://json-schema.org/draft-07/schema#"]
        let servers = Servers { _, transport in FakeMCPServer(transport: transport, tools: [.init(name: "count", description: "counts", schema: schema)]) }
        let hub = MCPHub(servers: [config("s")], makeTransport: servers.factory)
        await hub.start()
        let tool = try #require(await hub.tools.first)
        let definition = tool.definition
        #expect(definition.description == "[MCP server s] counts")
        #expect(definition.supportsStrict == false)
        let sent = definition.schema(strict: true)
        #expect(sent["properties"]?["n"]?["type"]?.stringValue == "integer")
        #expect(sent["$schema"] == nil, "a keyword some providers reject is dropped")
        #expect(sent["additionalProperties"] == nil, "nothing is added for strict mode")
        // Through the real encoders.
        let request = LLMRequest(model: "m", system: "", items: [.user("x")], tools: [definition])
        let body = try JSONValue(parsing: String(decoding: ResponsesRequestEncoder.body(for: request, strictTools: true), as: UTF8.self))
        #expect(body["tools"]?.arrayValue?.first?["strict"] == JSONValue.bool(false))
        let ordinary = ToolDefinition(name: "plain", description: "d", parameters: [ToolParameter("a", .string, "a")])
        let both = try JSONValue(parsing: String(decoding: ResponsesRequestEncoder.body(
            for: LLMRequest(model: "m", system: "", items: [.user("x")], tools: [ordinary, definition]), strictTools: true), as: UTF8.self))
        #expect(both["tools"]?.arrayValue?.map { $0["strict"] } == [JSONValue.bool(true), JSONValue.bool(false)], "other tools stay strict")
        await hub.close()
    }

    @Test func aNonObjectSchemaBecomesAnEmptyObjectSchema() {
        let definition = ToolDefinition(name: "t", description: "d", rawSchema: ["type": "string"])
        #expect(definition.schema(strict: false) == ["type": "object", "properties": .object([:])])
    }

    @Test func theFingerprintFollowsTheTools() async throws {
        let one = MCPHub(servers: [config("s")], makeTransport: Servers().factory)
        await one.start()
        let two = MCPHub(servers: [config("s")], makeTransport: Servers { _, t in FakeMCPServer(transport: t, tools: [.init(name: "echo", description: "changed")]) }.factory)
        await two.start()
        let same = MCPHub(servers: [config("s")], makeTransport: Servers().factory)
        await same.start()
        #expect(await one.fingerprint == same.fingerprint)
        #expect(await one.fingerprint != two.fingerprint)
        for hub in [one, two, same] { await hub.close() }
    }
}

@Suite struct MCPSessionTests {
    @Test func theModelCallsAServerToolAndGetsUntrustedText() async throws {
        let servers = Servers()
        let hub = MCPHub(servers: [config("fake")], makeTransport: servers.factory)
        await hub.start()
        let (agent, client) = try await session(hub, turns: [call("mcp__fake__echo"), .text("done")])
        for await _ in await agent.send("go") {}
        let output = try #require(await finalOutput(agent))
        #expect(output.hasPrefix("<untrusted source=\"mcp:fake\">"))
        #expect(output.contains(#"called echo with {"text":"hi"}"#))
        #expect(client.requests[0].tools.map(\.name) == ["mcp__fake__echo"])
        await hub.close()
    }

    @Test func aToolErrorBecomesAnErrorOutput() async throws {
        let servers = Servers { _, transport in
            FakeMCPServer(transport: transport) {
                $0.call = { _, _ in .success(["content": [["type": "text", "text": "quota exceeded"]], "isError": true]) }
            }
        }
        let hub = MCPHub(servers: [config("fake")], makeTransport: servers.factory)
        await hub.start()
        let (agent, _) = try await session(hub, turns: [call("mcp__fake__echo"), .text("done")])
        var failed: ToolOutput?
        for await event in await agent.send("go") { if case .toolCallFinished(_, _, let out) = event { failed = out } }
        #expect(failed?.isError == true)
        #expect(failed?.text.contains("fake: quota exceeded") == true)
        await hub.close()
    }

    @Test func nullsTheModelSendsForSkippedFieldsAreNotPassedOn() async throws {
        let servers = Servers()
        let hub = MCPHub(servers: [config("fake")], makeTransport: servers.factory)
        await hub.start()
        let (agent, _) = try await session(hub, turns: [call("mcp__fake__echo", #"{"text":"hi","limit":null}"#), .text("done")])
        for await _ in await agent.send("go") {}
        #expect(servers.servers("fake")[0].callArguments == [["text": "hi"]])
        await hub.close()
    }

    @Test func itAsksFirstWithTheServerNamedAndARuleToAlwaysAllow() async throws {
        let servers = Servers { _, transport in FakeMCPServer(transport: transport, tools: [.init(name: "echo", readOnly: true)]) }
        let hub = MCPHub(servers: [config("fake")], makeTransport: servers.factory)
        await hub.start()
        let (agent, _) = try await session(hub, turns: [call("mcp__fake__echo"), .text("done")], approval: .askForCommands)
        var request: ApprovalRequest?
        for await event in await agent.send("go") {
            if case .approvalRequested(let asked) = event {
                request = asked
                await agent.resolveApproval(callID: asked.callID, decision: .approve)
            }
        }
        let asked = try #require(request)
        #expect(asked.title == "Use fake: echo")
        #expect(asked.command == #"{"text":"hi"}"#)
        #expect(asked.suggestedRule == "mcp__fake__echo")
        #expect(asked.notes.joined().contains("fake"))
        #expect(asked.notes.joined().contains("claim"), "a read-only hint is shown as the server's claim")
        #expect(servers.servers("fake")[0].callArguments.count == 1)
        await hub.close()
    }

    @Test func aDenialStopsTheCallAndAnAllowRuleSkipsTheQuestion() async throws {
        let servers = Servers()
        let hub = MCPHub(servers: [config("fake")], makeTransport: servers.factory)
        await hub.start()
        let (denied, _) = try await session(hub, turns: [call("mcp__fake__echo"), .text("done")], approval: .askForCommands)
        for await event in await denied.send("go") {
            if case .approvalRequested(let asked) = event { await denied.resolveApproval(callID: asked.callID, decision: .deny(note: "no")) }
        }
        #expect(servers.servers("fake")[0].callArguments.isEmpty)
        #expect(await finalOutput(denied)?.contains("denied") == true)

        let allow = PermissionRules(allow: [PermissionRule(tool: "mcp__fake__echo")])
        let (allowed, _) = try await session(hub, turns: [call("mcp__fake__echo"), .text("done")], approval: .askForCommands, rules: allow)
        var asked = false
        for await event in await allowed.send("go") { if case .approvalRequested = event { asked = true } }
        #expect(!asked)
        #expect(servers.servers("fake")[0].callArguments.count == 1)
        await hub.close()
    }

    @Test func planModeDoesNotOfferServerTools() async throws {
        let hub = MCPHub(servers: [config("fake")], makeTransport: Servers().factory)
        await hub.start()
        let (agent, client) = try await session(hub, turns: [.text("plan")], mode: .plan)
        for await _ in await agent.send("go") {}
        #expect(client.requests[0].tools.isEmpty)
        await hub.close()
    }

    @Test func aServerThatStoppedIsStartedAgainByTheNextCallAFewTimesAtMost() async throws {
        let servers = Servers()
        let hub = MCPHub(servers: [config("fake")], makeTransport: servers.factory)
        await hub.start()
        let tool = try #require(await hub.tools.first)
        let project = try TempProject()
        let context = ToolContext(workspace: project.workspace, ledger: ReadLedger(), callID: "x")
        let arguments = try ToolArguments(json: #"{"text":"hi"}"#)

        for restart in 1...MCPHub.maxRestarts {
            await servers.servers("fake").last?.stop()
            try await Task.sleep(for: .milliseconds(60))
            let text = try await tool.run(arguments, context: context)
            #expect(text.contains("called echo"), "restart \(restart)")
            #expect(servers.starts(of: "fake") == restart + 1)
        }
        await servers.servers("fake").last?.stop()
        try await Task.sleep(for: .milliseconds(60))
        do {
            _ = try await tool.run(arguments, context: context)
            Issue.record("a server that keeps stopping should not be started again")
        } catch let error as ToolError {
            #expect(error.message.contains("keeps stopping"))
        }
        await hub.close()
    }

    @Test func closingStopsEveryServerAndLaterCallsFail() async throws {
        let servers = Servers()
        let hub = MCPHub(servers: [config("fake")], makeTransport: servers.factory)
        await hub.start()
        let tool = try #require(await hub.tools.first)
        await hub.close()
        try await Task.sleep(for: .milliseconds(60))
        let project = try TempProject()
        let context = ToolContext(workspace: project.workspace, ledger: ReadLedger(), callID: "x")
        await #expect(throws: ToolError.self) { _ = try await tool.run(try ToolArguments(json: #"{"text":"hi"}"#), context: context) }
        #expect(servers.starts(of: "fake") == 1, "nothing is started after close")
    }

    @Test func aLongOutputIsCutAndSaysSo() async throws {
        let big = String(repeating: "word ", count: 20_000)
        let servers = Servers { _, transport in
            FakeMCPServer(transport: transport) { $0.call = { _, _ in .success(["content": [["type": "text", "text": .string(big)]]]) } }
        }
        let hub = MCPHub(servers: [config("fake")], makeTransport: servers.factory)
        await hub.start()
        let (agent, _) = try await session(hub, turns: [call("mcp__fake__echo"), .text("done")])
        for await _ in await agent.send("go") {}
        let output = try #require(await finalOutput(agent))
        #expect(output.count < MCPTool.maxOutputCharacters + 1_000)
        #expect(output.contains("characters omitted"))
        await hub.close()
    }
}
