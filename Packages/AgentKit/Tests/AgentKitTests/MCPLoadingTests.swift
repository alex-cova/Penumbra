import Foundation
import Testing
@testable import AgentKit

// MARK: - Helpers

private func tool(_ name: String, _ description: String = "does a thing", required: [String] = ["text"], extra: [String: JSONValue] = [:]) -> FakeMCPServer.Tool {
    var properties: [String: JSONValue] = ["text": ["type": "string", "description": "The text."]]
    for (key, value) in extra { properties[key] = value }
    return FakeMCPServer.Tool(name: name, description: description, schema: [
        "type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)),
    ])
}

/// A server with a lot of tools, like a hosted one: `<kind>_<action>` for a few kinds.
private func bigServerTools() -> [FakeMCPServer.Tool] {
    var tools: [FakeMCPServer.Tool] = []
    for kind in ["issue", "pull_request", "repository", "branch", "release", "workflow"] {
        for action in ["list", "get", "create", "update", "search"] {
            let readable = kind.replacingOccurrences(of: "_", with: " ")
            tools.append(tool(
                "\(kind)_\(action)",
                "\(action.capitalized) \(readable)s in a repository. Requires access to the repository and a token with the right scope. Results are paginated and sorted by most recent activity.",
                required: ["owner", "repo"],
                extra: ["owner": ["type": "string"], "repo": ["type": "string"], "title": ["type": "string"], "state": ["type": "string", "enum": ["open", "closed"]]]))
        }
    }
    return tools
}

private final class Servers: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String: [FakeMCPServer]] = [:]
    let toolsFor: @Sendable (String) -> [FakeMCPServer.Tool]
    let configure: @Sendable (FakeMCPServer) -> Void

    init(_ toolsFor: @escaping @Sendable (String) -> [FakeMCPServer.Tool], configure: @escaping @Sendable (FakeMCPServer) -> Void = { _ in }) {
        self.toolsFor = toolsFor
        self.configure = configure
    }

    func servers(_ name: String) -> [FakeMCPServer] { lock.withLock { all[name] ?? [] } }

    var factory: MCPHub.TransportFactory {
        { [self] config in
            let (clientEnd, serverEnd) = ACPInMemoryTransport.pair()
            let server = FakeMCPServer(transport: serverEnd, tools: toolsFor(config.name), configure: configure)
            lock.withLock { all[config.name, default: []].append(server) }
            return clientEnd
        }
    }
}

private func config(_ name: String) -> MCPServerConfig { MCPServerConfig(name: name, command: "/bin/\(name)") }

private func agent(
    _ hub: MCPHub, turns: [MockTurn], mode: PermissionMode = .acceptEdits, approval: ApprovalPolicy = .approveAll,
    rules: PermissionRules = PermissionRules()
) async throws -> (AgentSession, MockLLMClient) {
    let client = MockLLMClient(turns: turns)
    return (AgentSession(
        client: client, tools: await hub.tools, workspace: try TempProject().workspace,
        configuration: AgentConfiguration(model: "m", approval: approval, mode: mode, permissions: rules)), client)
}

private func outputs(_ session: AgentSession) async -> [String: String] {
    var result: [String: String] = [:]
    for case .toolOutput(let id, let text) in await session.items { result[id] = text }
    return result
}

private func names(_ hub: MCPHub) async -> [String] { await hub.tools.map(\.name) }

// MARK: - Trimming and hiding in the hub

@Suite struct MCPHubLoadingTests {
    @Test func trimmingShrinksWhatIsSentAndKeepsWhatTheServerWrote() async throws {
        let long = String(repeating: "This tool does a particular thing with the data you give it. ", count: 10)
        let servers = Servers { _ in [tool("do_it", long)] }
        let plain = MCPHub(servers: [config("s")], makeTransport: servers.factory)
        let trimmed = MCPHub(servers: [config("s")], trimming: .standard, makeTransport: servers.factory)
        await plain.start()
        await trimmed.start()
        let before = try #require(await plain.tools.first).definition
        let after = try #require(await trimmed.tools.first).definition
        #expect(ToolCost.characters(of: after) < ToolCost.characters(of: before) / 2)
        let summary = try #require(await trimmed.summaries.first)
        #expect(summary.description == long, "Settings still shows the server's own text")
        #expect(summary.definition == after)
        #expect(await plain.fingerprint != trimmed.fingerprint)
        await plain.close(); await trimmed.close()
    }

    @Test func aHiddenToolIsNotListedNotCallableAndStillShownInSettings() async throws {
        let servers = Servers { _ in [tool("keep"), tool("drop"), tool("also_keep")] }
        let hub = MCPHub(servers: [config("s")], hidden: ["s": ["drop"]], makeTransport: servers.factory)
        let statuses = await hub.start()
        #expect(statuses.first?.state == .connected(tools: 2), "the count is of tools offered")
        #expect(await names(hub) == ["mcp__s__also_keep", "mcp__s__keep"])
        let summaries = await hub.summaries
        #expect(summaries.map(\.remoteName) == ["also_keep", "drop", "keep"])
        #expect(summaries.first { $0.remoteName == "drop" }?.isHidden == true)
        #expect(summaries.first { $0.remoteName == "keep" }?.isHidden == false)

        let (session, client) = try await agent(hub, turns: [.toolCalls((id: "c", name: "mcp__s__drop", arguments: #"{"text":"x"}"#)), .text("ok")])
        for await _ in await session.send("go") {}
        #expect(await outputs(session)["c"]?.contains("Unknown tool") == true)
        #expect(client.requests[0].tools.map(\.name) == ["mcp__s__also_keep", "mcp__s__keep"])
        #expect(servers.servers("s")[0].callArguments.isEmpty)
        await hub.close()
    }

    @Test func hidingChangesTheFingerprintSoASessionIsRestarted() async throws {
        let servers = Servers { _ in [tool("a"), tool("b")] }
        let none = MCPHub(servers: [config("s")], makeTransport: servers.factory)
        let one = MCPHub(servers: [config("s")], hidden: ["s": ["b"]], makeTransport: servers.factory)
        await none.start(); await one.start()
        #expect(await none.fingerprint != one.fingerprint)
        await none.close(); await one.close()
    }

    @Test func hiddenToolsAreKeyedByTheServersOwnNames() async throws {
        let servers = Servers { _ in [tool("same")] }
        let hub = MCPHub(servers: [config("a"), config("b")], hidden: ["a": ["same"]], makeTransport: servers.factory)
        await hub.start()
        #expect(await names(hub) == ["mcp__b__same"])
        await hub.close()
    }
}

// MARK: - Deferral

@Suite struct MCPDeferralTests {
    private func hub(_ mode: MCPDeferral.Mode, perServer: [String: MCPDeferral.Mode] = [:], servers names: [String] = ["big"]) async -> (MCPHub, Servers) {
        let servers = Servers { name in name == "small" ? [tool("one"), tool("two")] : bigServerTools() }
        let hub = MCPHub(
            servers: names.map(config), trimming: .standard,
            deferral: MCPDeferral(mode: mode, provider: "anthropic", perServer: perServer), makeTransport: servers.factory)
        await hub.start()
        return (hub, servers)
    }

    @Test func aBigServerIsDeferredAndASmallOneStaysListed() async throws {
        let (hub, _) = await hub(.automatic, servers: ["small", "big"])
        let listed = await names(hub)
        #expect(listed == ["mcp__small__one", "mcp__small__two", "tool_search", "tool_call"])
        let summaries = await hub.summaries
        #expect(summaries.filter { $0.server == "big" }.allSatisfy { $0.isDeferred })
        #expect(summaries.filter { $0.server == "small" }.allSatisfy { !$0.isDeferred })
        await hub.close()
    }

    @Test func theModesAndPerServerOverridesDecide() async throws {
        let (never, _) = await hub(.never)
        #expect(await names(never).count == 30)
        let (always, _) = await hub(.always, servers: ["small"])
        #expect(await names(always) == ["tool_search", "tool_call"])
        let (forcedListed, _) = await hub(.automatic, perServer: ["big": .never])
        #expect(await names(forcedListed).count == 30)
        let (forcedDeferred, _) = await hub(.never, perServer: ["small": .always], servers: ["small"])
        #expect(await names(forcedDeferred) == ["tool_search", "tool_call"])
        for h in [never, always, forcedListed, forcedDeferred] { await h.close() }
    }

    @Test func deferringIsWhatMakesAHugeServerCheap() async throws {
        let (direct, _) = await hub(.never)
        let (deferred, _) = await hub(.automatic)
        let directTokens = ToolCost.tokens(of: await direct.tools.map(\.definition), provider: "anthropic")
        let deferredTokens = ToolCost.tokens(of: await deferred.tools.map(\.definition), provider: "anthropic")
        #expect(deferredTokens < directTokens / 4, "\(directTokens) -> \(deferredTokens)")
        await direct.close(); await deferred.close()
    }

    @Test func theToolListIsByteIdenticalAcrossTwoStarts() async throws {
        func encoded(_ hub: MCPHub) async throws -> String {
            var parts: [String] = []
            for tool in await hub.tools { parts.append(try tool.definition.schema(strict: false).serialized() + tool.definition.description + tool.name) }
            return parts.joined(separator: "\n")
        }
        let (first, _) = await hub(.automatic)
        let (second, _) = await hub(.automatic)
        #expect(try await encoded(first) == encoded(second))
        #expect(await first.fingerprint == second.fingerprint)
        await first.close(); await second.close()
    }

    @Test func hiddenToolsInADeferredServerAreNotSearchable() async throws {
        let servers = Servers { _ in bigServerTools() }
        let hub = MCPHub(servers: [config("big")], hidden: ["big": ["issue_create"]], deferral: MCPDeferral(mode: .always), makeTransport: servers.factory)
        await hub.start()
        let search = try #require(await hub.tools.first { $0.name == "tool_search" })
        let result = try await run(search, #"{"query":"create issue"}"#)
        #expect(!result.contains("mcp__big__issue_create"))
        await hub.close()
    }

    private func run(_ tool: any AgentTool, _ json: String) async throws -> String {
        try await tool.run(try ToolArguments(json: json), context: ToolContext(workspace: try TempProject().workspace, ledger: ReadLedger(), callID: "x"))
    }

    @Test func searchFindsTheRightToolsBestFirstAndHonorsServerAndLimit() async throws {
        let (hub, _) = await hub(.always, servers: ["big", "small"])
        let search = try #require(await hub.tools.first { $0.name == "tool_search" })
        let found = try await run(search, #"{"query":"create issue"}"#)
        let first = found.range(of: "mcp__big__issue_create")?.lowerBound
        let other = found.range(of: "mcp__big__issue_list")?.lowerBound
        #expect(first != nil)
        if let first, let other { #expect(first < other, "the better match comes first") }
        #expect(found.contains("schema: {"))
        #expect(found.hasPrefix("<untrusted source=\"tool_search\">"))

        let pulls = try await run(search, #"{"query":"list pull requests","limit":2}"#)
        #expect(pulls.contains("mcp__big__pull_request_list"))
        #expect(pulls.components(separatedBy: "schema:").count - 1 == 2)

        let scoped = try await run(search, #"{"query":"one","server":"small"}"#)
        #expect(scoped.contains("mcp__small__one") && !scoped.contains("mcp__big__"))
        let none = try await run(search, #"{"query":"zebra unicorn"}"#)
        #expect(none.contains("No tool matches") && none.contains("big (30 tools)"))
        await hub.close()
    }

    @Test func theSearchToolNamesTheServicesAndIsNotOfferedInPlanMode() async throws {
        let (hub, _) = await hub(.always, servers: ["big", "small"])
        let search = try #require(await hub.tools.first { $0.name == "tool_search" })
        #expect(search.definition.description.contains("- big: 30 tools"))
        #expect(search.definition.description.contains("- small: 2 tools"))
        #expect(search.isOffered(in: .acceptEdits) && !search.isOffered(in: .plan))
        let (session, client) = try await agent(hub, turns: [.text("plan")], mode: .plan)
        for await _ in await session.send("go") {}
        #expect(client.requests[0].tools.isEmpty)
        await hub.close()
    }
}

// MARK: - The gateway in a real session

@Suite struct MCPGatewaySessionTests {
    private func deferred(_ configure: @escaping @Sendable (FakeMCPServer) -> Void = { _ in }) async -> (MCPHub, Servers) {
        let servers = Servers({ _ in bigServerTools() }, configure: configure)
        let hub = MCPHub(servers: [config("big")], trimming: .standard, deferral: MCPDeferral(mode: .always), makeTransport: servers.factory)
        await hub.start()
        return (hub, servers)
    }

    private func call(_ name: String, _ arguments: String) -> MockTurn {
        .toolCalls((id: "c1", name: "tool_call", arguments: #"{"name":"\#(name)","arguments":\#(arguments)}"#))
    }

    @Test func searchThenCallRunsTheDeferredToolOnItsServer() async throws {
        let (hub, servers) = await deferred()
        let (session, client) = try await agent(hub, turns: [
            .toolCalls((id: "s1", name: "tool_search", arguments: #"{"query":"create issue"}"#)),
            call("mcp__big__issue_create", #"{"owner":"acme","repo":"widgets","title":"Fix login"}"#),
            .text("done"),
        ])
        for await _ in await session.send("go") {}
        let seen = await outputs(session)
        #expect(seen["s1"]?.contains("mcp__big__issue_create") == true)
        #expect(seen["c1"]?.contains("<untrusted source=\"mcp:big\">") == true)
        #expect(seen["c1"]?.contains("called issue_create") == true)
        #expect(servers.servers("big")[0].callArguments == [["owner": "acme", "repo": "widgets", "title": "Fix login"]])
        #expect(Set(client.requests[0].tools.map(\.name)) == ["tool_search", "tool_call"])
        await hub.close()
    }

    @Test func theApprovalCardAndRulesAreThoseOfTheRealTool() async throws {
        let (hub, servers) = await deferred()
        let (asking, _) = try await agent(hub, turns: [call("mcp__big__issue_create", #"{"owner":"a","repo":"r"}"#), .text("done")], approval: .askForCommands)
        var request: ApprovalRequest?
        for await event in await asking.send("go") {
            if case .approvalRequested(let asked) = event {
                request = asked
                await asking.resolveApproval(callID: asked.callID, decision: .approve)
            }
        }
        let card = try #require(request)
        #expect(card.toolName == "mcp__big__issue_create")
        #expect(card.title.hasPrefix("Use big:"))
        #expect(card.suggestedRule == "mcp__big__issue_create", "always-allow names the real tool, not tool_call")
        #expect(servers.servers("big")[0].callArguments.count == 1)

        let allow = PermissionRules(allow: [PermissionRule(tool: "mcp__big__issue_create")])
        let (allowed, _) = try await agent(hub, turns: [call("mcp__big__issue_create", #"{"owner":"a","repo":"r"}"#), .text("done")], approval: .askForCommands, rules: allow)
        var asked = false
        for await event in await allowed.send("go") { if case .approvalRequested = event { asked = true } }
        #expect(!asked, "an allow rule on the real name skips the card")

        let deny = PermissionRules(deny: [PermissionRule(tool: "mcp__big__issue_create")])
        let (denied, _) = try await agent(hub, turns: [call("mcp__big__issue_create", #"{"owner":"a","repo":"r"}"#), .text("done")], approval: .askForCommands, rules: deny)
        for await _ in await denied.send("go") {}
        #expect(await outputs(denied)["c1"]?.contains("Blocked by the user's permission rules") == true)
        #expect(servers.servers("big")[0].callArguments.count == 2, "only the approved and the allowed call reached the server")
        await hub.close()
    }

    @Test func aRuleOnTheGatewayNameDoesNotUnlockEverything() async throws {
        let (hub, servers) = await deferred()
        let rules = PermissionRules(allow: [PermissionRule(tool: "tool_call")])
        let (session, _) = try await agent(hub, turns: [call("mcp__big__issue_create", #"{"owner":"a","repo":"r"}"#), .text("done")], approval: .askForCommands, rules: rules)
        var asked = false
        for await event in await session.send("go") {
            if case .approvalRequested(let request) = event {
                asked = true
                await session.resolveApproval(callID: request.callID, decision: .deny(note: nil))
            }
        }
        #expect(asked, "allowing tool_call is not allowing what it forwards to")
        #expect(servers.servers("big")[0].callArguments.isEmpty)
        await hub.close()
    }

    @Test func missingArgumentsAnUnknownNameAndStringArgumentsAreHandled() async throws {
        let (hub, servers) = await deferred()
        let (session, _) = try await agent(hub, turns: [
            call("mcp__big__issue_create", #"{"title":"only a title"}"#),
            .toolCalls((id: "c2", name: "tool_call", arguments: #"{"name":"mcp__big__issue_creat","arguments":{}}"#)),
            .toolCalls((id: "c3", name: "tool_call", arguments: #"{"name":"mcp__big__issue_list","arguments":"{\"owner\":\"a\",\"repo\":\"r\"}"}"#)),
            .text("done"),
        ])
        for await _ in await session.send("go") {}
        let seen = await outputs(session)
        #expect(seen["c1"]?.contains("needs owner, repo") == true)
        #expect(seen["c1"]?.contains("schema") == true)
        #expect(seen["c2"]?.contains("Did you mean") == true && seen["c2"]?.contains("mcp__big__issue_create") == true)
        #expect(seen["c3"]?.contains("called issue_list") == true, "arguments written as a JSON string are read")
        #expect(servers.servers("big")[0].callArguments == [["owner": "a", "repo": "r"]])
        await hub.close()
    }

    @Test func aToolThatFailsOnTheServerComesBackAsAnError() async throws {
        let (hub, _) = await deferred {
            $0.call = { _, _ in .success(["content": [["type": "text", "text": "quota exceeded"]], "isError": true]) }
        }
        let (session, _) = try await agent(hub, turns: [call("mcp__big__issue_list", #"{"owner":"a","repo":"r"}"#), .text("done")])
        var finished: ToolOutput?
        for await event in await session.send("go") { if case .toolCallFinished(_, _, let out) = event { finished = out } }
        #expect(finished?.isError == true)
        #expect(finished?.text.contains("quota exceeded") == true)
        await hub.close()
    }
}
