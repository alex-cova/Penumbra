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
        var server: String
        var info: MCPToolInfo
    }

    private struct Entry {
        var config: MCPServerConfig
        var client: MCPClient?
    }

    public static let maxRestarts = 3

    private let makeTransport: TransportFactory
    private let connectTimeout: TimeInterval
    private let callTimeout: TimeInterval
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var specs: [ToolSpec] = []
    private var restarts: [String: Int] = [:]
    private var reconnecting: [String: Task<MCPClient, Error>] = [:]
    private var closed = false
    public private(set) var statuses: [MCPServerStatus] = []

    public init(
        servers: [MCPServerConfig], connectTimeout: TimeInterval = 30, callTimeout: TimeInterval = 120,
        makeTransport: @escaping TransportFactory
    ) {
        self.makeTransport = makeTransport
        self.connectTimeout = connectTimeout
        self.callTimeout = callTimeout
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

    /// The servers' tools in a fixed order (server, then tool name), for the session's tool list.
    public var tools: [any AgentTool] {
        specs.map { MCPTool(name: $0.name, server: $0.server, info: $0.info, hub: self) }
    }

    /// Changes when a tool's name, description or schema does. A host puts it in its session
    /// fingerprint, so a changed server starts a new session instead of changing a live request.
    public var fingerprint: String {
        let parts = specs.map { "\($0.name)\u{0}\($0.info.description)\u{0}\((try? $0.info.inputSchema.serialized()) ?? "")" }
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
            var count = 0
            for info in result.outcome.tools.sorted(by: { $0.name < $1.name }) {
                var name = MCPNaming.toolName(server: identifier, tool: info.name)
                var suffix = 2
                while !usedNames.insert(name).inserted {
                    name = MCPNaming.toolName(server: identifier, tool: info.name + "_\(suffix)")
                    suffix += 1
                }
                newSpecs.append(ToolSpec(name: name, server: identifier, info: info))
                count += 1
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
