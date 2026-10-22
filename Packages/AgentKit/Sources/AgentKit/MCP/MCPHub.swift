import Foundation

public struct MCPServerStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case connected(tools: Int)
        case failed(String)
    }

    public var name: String
    public var state: State

    public init(name: String, state: State) {
        self.name = name
        self.state = state
    }
}

/// When a server's tools are reached through `tool_search` and `tool_call` instead of being listed in
/// every request (`MCPGateway.swift`). The listing costs tokens on every request whether or not a tool is
/// used, and a server with dozens of tools costs more than the conversation does.
public struct MCPDeferral: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case never
        /// By size: over `budgetTokens` or `toolCount`.
        case automatic
        case always
    }

    public var mode: Mode
    public var budgetTokens: Int
    public var toolCount: Int
    /// For `ToolCost`: the provider the tokens are counted for.
    public var provider: String
    /// A server named here (by the name the user gave it) overrides `mode`.
    public var perServer: [String: Mode]

    public init(mode: Mode = .never, budgetTokens: Int = 3_000, toolCount: Int = 20, provider: String = "", perServer: [String: Mode] = [:]) {
        self.mode = mode
        self.budgetTokens = budgetTokens
        self.toolCount = toolCount
        self.provider = provider
        self.perServer = perServer
    }

    public static let never = MCPDeferral()

    func mode(for server: String) -> Mode { perServer[server] ?? mode }
}

/// One tool of one server as the hub knows it, for Settings: what the server wrote, what is sent, and
/// whether it is hidden or reached through the gateway.
public struct MCPToolSummary: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// The server's name as the user wrote it.
    public var server: String
    /// The name the model sees (`mcp__server__tool`).
    public var name: String
    public var remoteName: String
    /// The server's own description, untrimmed.
    public var description: String
    /// What a request carries for the tool when it is listed.
    public var definition: ToolDefinition
    public var isHidden: Bool
    public var isDeferred: Bool
}

/// The MCP servers one window uses: connects them, offers their tools as ordinary `AgentTool`s, and
/// routes calls. The host supplies how a server is started (`makeTransport`: it spawns the process and
/// decides whether the user has agreed) so AgentKit starts nothing itself.
///
/// The tool list is read once, when `start()` ends, and does not change afterwards: it is part of the
/// request prefix, and a list that moved between turns would break the provider's cache. A server that
/// stops mid-session is started again by the next call that needs it, a few times at most.
public actor MCPHub {
    public typealias TransportFactory = @Sendable (MCPServerConfig) throws -> any ACPTransport

    private struct ToolSpec {
        var name: String
        /// The server's identifier, as used in tool names.
        var server: String
        var serverName: String
        var original: MCPToolInfo
        var info: MCPToolInfo
        var isHidden: Bool
        var isDeferred: Bool
    }

    private struct Entry {
        var config: MCPServerConfig
        var client: MCPClient?
    }

    public static let maxRestarts = 3

    private let makeTransport: TransportFactory
    private let connectTimeout: TimeInterval
    private let callTimeout: TimeInterval
    private let trimming: ToolTrimming
    private let hidden: [String: Set<String>]
    private let deferral: MCPDeferral
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var specs: [ToolSpec] = []
    private var restarts: [String: Int] = [:]
    private var reconnecting: [String: Task<MCPClient, Error>] = [:]
    private var closed = false
    public private(set) var statuses: [MCPServerStatus] = []

    public init(
        servers: [MCPServerConfig], connectTimeout: TimeInterval = 30, callTimeout: TimeInterval = 120,
        trimming: ToolTrimming = .none, hidden: [String: Set<String>] = [:], deferral: MCPDeferral = .never,
        makeTransport: @escaping TransportFactory
    ) {
        self.makeTransport = makeTransport
        self.connectTimeout = connectTimeout
        self.callTimeout = callTimeout
        self.trimming = trimming
        self.hidden = hidden
        self.deferral = deferral
        // Two servers whose names clean up to the same identifier get distinct ones.
        var used = Set<String>()
        for server in servers {
            var identifier = server.identifier
            var suffix = 2
            while !used.insert(identifier).inserted {
                identifier = String(server.identifier.prefix(20)) + "_\(suffix)"
                suffix += 1
            }
            entries[identifier] = Entry(config: server, client: nil)
            order.append(identifier)
        }
    }

    // MARK: - Tools

    /// The tools to put in the session's tool list, in a fixed order (server, then tool name): the
    /// servers' listed tools, then `tool_search` and `tool_call` if any server is deferred. Hidden tools
    /// are in neither.
    public var tools: [any AgentTool] {
        var result: [any AgentTool] = specs.filter { !$0.isHidden && !$0.isDeferred }
            .map { MCPTool(name: $0.name, server: $0.server, info: $0.info, hub: self) }
        let deferred = specs.filter { $0.isDeferred && !$0.isHidden }
        if !deferred.isEmpty {
            let catalog = MCPGatewayCatalog(entries: deferred.map {
                MCPGatewayEntry(serverName: $0.serverName, tool: MCPTool(name: $0.name, server: $0.server, info: $0.info, hub: self))
            })
            result += [MCPToolSearchTool(catalog: catalog), MCPToolCallTool(catalog: catalog)]
        }
        return result
    }

    /// Every tool the servers offer, hidden ones included, for Settings.
    public var summaries: [MCPToolSummary] {
        specs.map {
            MCPToolSummary(
                server: $0.serverName, name: $0.name, remoteName: $0.original.name, description: $0.original.description,
                definition: MCPTool(name: $0.name, server: $0.server, info: $0.info, hub: self).definition,
                isHidden: $0.isHidden, isDeferred: $0.isDeferred)
        }
    }

    /// Changes when a tool's name, description or schema does, or when a tool is hidden or deferred. A
    /// host puts it in its session fingerprint, so a changed server starts a new session instead of
    /// changing a live request.
    public var fingerprint: String {
        let parts = specs.map {
            "\($0.name)\u{0}\($0.info.description)\u{0}\((try? $0.info.inputSchema.serialized()) ?? "")\u{0}\($0.isHidden)\u{0}\($0.isDeferred)"
        }
        return String(ReadLedger.hash(parts.joined(separator: "\u{1}")), radix: 16)
    }

    // MARK: - Connecting

    private struct Outcome: Sendable {
        var tools: [MCPToolInfo] = []
        var failure: String?
    }

    /// Starts every server at once and waits for all of them (each at most `connectTimeout`). One that
    /// fails is reported and the others carry on.
    @discardableResult
    public func start() async -> [MCPServerStatus] {
        guard !closed, statuses.isEmpty else { return statuses }
        let timeout = connectTimeout
        let factory = makeTransport
        var results: [String: (client: MCPClient?, outcome: Outcome)] = [:]
        await withTaskGroup(of: (String, MCPClient?, Outcome).self) { group in
            for identifier in order {
                guard let config = entries[identifier]?.config else { continue }
                group.addTask {
                    let client: MCPClient
                    do {
                        client = MCPClient(transport: try factory(config))
                    } catch {
                        return (identifier, nil, Outcome(failure: error.localizedDescription))
                    }
                    let outcome = await Deadline.run(timeout) { () -> Outcome in
                        do {
                            try await client.start(timeout: .seconds(timeout))
                            return Outcome(tools: try await client.listTools(timeout: .seconds(timeout)))
                        } catch {
                            return Outcome(failure: error.localizedDescription)
                        }
                    }
                    guard let outcome, outcome.failure == nil else {
                        await client.close()
                        return (identifier, nil, outcome ?? Outcome(failure: "It did not start within \(Int(timeout)) seconds."))
                    }
                    return (identifier, client, outcome)
                }
            }
            for await (identifier, client, outcome) in group { results[identifier] = (client, outcome) }
        }
        var newSpecs: [ToolSpec] = []
        var usedNames = Set<String>()
        for identifier in order {
            guard let config = entries[identifier]?.config, let result = results[identifier] else { continue }
            if let failure = result.outcome.failure {
                statuses.append(MCPServerStatus(name: config.name, state: .failed(failure)))
                continue
            }
            entries[identifier]?.client = result.client
            let hiddenNames = hidden[config.name] ?? []
            let infos = result.outcome.tools.sorted(by: { $0.name < $1.name })
            let listed = infos.filter { !hiddenNames.contains($0.name) }.map { ToolDefinitionTrimmer.trim($0, trimming) }
            let deferServer: Bool
            switch deferral.mode(for: config.name) {
            case .never: deferServer = false
            case .always: deferServer = !listed.isEmpty
            case .automatic:
                let cost = ToolCost.tokens(of: listed.map { MCPTool(name: "x", server: identifier, info: $0, hub: self).definition }, provider: deferral.provider)
                deferServer = cost > deferral.budgetTokens || listed.count > deferral.toolCount
            }
            var count = 0
            for original in infos {
                let isHidden = hiddenNames.contains(original.name)
                var name = MCPNaming.toolName(server: identifier, tool: original.name)
                var suffix = 2
                while !usedNames.insert(name).inserted {
                    name = MCPNaming.toolName(server: identifier, tool: original.name + "_\(suffix)")
                    suffix += 1
                }
                newSpecs.append(ToolSpec(
                    name: name, server: identifier, serverName: config.name, original: original,
                    info: ToolDefinitionTrimmer.trim(original, trimming), isHidden: isHidden, isDeferred: deferServer))
                if !isHidden { count += 1 }
            }
            statuses.append(MCPServerStatus(name: config.name, state: .connected(tools: count)))
        }
        specs = newSpecs
        // The window may have closed while the servers were starting.
        if closed { await closeClients() }
        return statuses
    }

    // MARK: - Calling

    func call(server: String, tool: String, arguments: JSONValue) async throws -> MCPToolResult {
        guard !closed, entries[server] != nil else { throw MCPError.closed }
        let client = try await liveClient(for: server)
        do {
            return try await client.callTool(name: tool, arguments: arguments, timeout: .seconds(callTimeout))
        } catch MCPError.closed {
            // It stopped between the check and the call (or while answering): start it once more.
            entries[server]?.client = nil
            let again = try await liveClient(for: server)
            return try await again.callTool(name: tool, arguments: arguments, timeout: .seconds(callTimeout))
        }
    }

    private func liveClient(for server: String) async throws -> MCPClient {
        if let client = entries[server]?.client, await !client.isClosed { return client }
        if let pending = reconnecting[server] { return try await pending.value }
        guard let config = entries[server]?.config else { throw MCPError.closed }
        let count = restarts[server, default: 0]
        guard count < Self.maxRestarts else {
            throw MCPError.server(code: -32000, message: "The server “\(config.name)” keeps stopping, so it is not started again in this window. Check it in Settings.")
        }
        restarts[server] = count + 1
        let factory = makeTransport
        let timeout = connectTimeout
        let task = Task<MCPClient, Error> {
            let client = MCPClient(transport: try factory(config))
            try await client.start(timeout: .seconds(timeout))
            return client
        }
        reconnecting[server] = task
        defer { reconnecting[server] = nil }
        let client = try await task.value
        if closed {
            await client.close()
            throw MCPError.closed
        }
        entries[server]?.client = client
        return client
    }

    // MARK: - Closing

    /// Stops every server. Nothing is started again afterwards.
    public func close() async {
        closed = true
        await closeClients()
    }

    private func closeClients() async {
        for identifier in order {
            let client = entries[identifier]?.client
            entries[identifier]?.client = nil
            await client?.close()
        }
        for task in reconnecting.values { task.cancel() }
    }
}
