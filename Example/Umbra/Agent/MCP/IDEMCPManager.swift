import AgentKit
import Foundation
import Observation

/// What Settings shows for one server.
struct IDEMCPServerState: Identifiable, Equatable {
    enum Kind: Equatable {
        case running(tools: Int)
        case failed(String)
        case waiting(String)
        case off
    }

    var id: String
    var name: String
    var kind: Kind
}

/// The window's MCP servers: which ones to use (the ones the user added and switched on, and the
/// project's that they allowed), one `MCPHub` that runs them, and what to tell the user when one does
/// not start. Servers start when a chat first needs them, never when a window opens, and stop when the
/// window closes.
@MainActor
@Observable
final class IDEMCPManager {
    private let store: IDEMCPStore
    private(set) var project = IDEMCPProjectConfig.Loaded()
    private(set) var states: [IDEMCPServerState] = []

    @ObservationIgnored private var hub: MCPHub?
    @ObservationIgnored private var hubKey = ""
    @ObservationIgnored private var registry = TransportRegistry()
    @ObservationIgnored private var last: Task<Void, Never>?

    init(store: IDEMCPStore) {
        self.store = store
    }

    /// Re-reads the project's files. Cheap (two small files); called when a chat needs the servers and
    /// when Settings opens.
    func refreshProject(root: URL?) {
        project = root.map(IDEMCPProjectConfig.load(root:)) ?? IDEMCPProjectConfig.Loaded()
        if hub == nil { states = idleStates() }
    }

    func allow(_ config: MCPServerConfig) {
        store.trust(config)
        if hub == nil { states = idleStates() }
    }

    func revoke(_ config: MCPServerConfig) {
        store.decline(config)
        if hub == nil { states = idleStates() }
    }

    struct Prepared {
        var hub: MCPHub?
        /// Lines for the transcript: servers that did not start.
        var notices: [String] = []
    }

    /// The hub for the servers in use now, starting it if the set changed. `confirm` asks the user about
    /// project servers they have not answered yet; `willStart` is called before a start that may take
    /// a while. `nil` hub: nothing to use.
    func prepare(
        root: URL, confirm: @escaping @MainActor ([MCPServerConfig]) async -> Set<String>, willStart: @escaping @MainActor () -> Void
    ) async -> Prepared {
        await serialized { [self] in
            refreshProject(root: root)
            let unanswered = project.servers.filter { !store.isTrusted($0) && !store.isDeclined($0) }
            if !unanswered.isEmpty {
                let allowed = await confirm(unanswered)
                for server in unanswered {
                    if allowed.contains(IDEMCPStore.fingerprint(of: server)) { store.trust(server) } else { store.decline(server) }
                }
            }
            let active = store.enabledConfigs() + project.servers.filter { store.isTrusted($0) }
            let key = active.map(\.canonicalText).sorted().joined(separator: "\u{1}") + "|" + root.path
            if active.isEmpty {
                await stop()
                states = idleStates()
                return Prepared()
            }
            if let hub, key == hubKey { return Prepared(hub: hub) }

            await stop()
            willStart()
            let registry = self.registry
            let newHub = MCPHub(servers: active) { config in
                let environment = AgentCommandEnvironment.make(javaHome: nil, extras: config.env)
                let definition = IDEACPDefinition(name: config.name, command: config.command, args: config.args)
                guard definition.resolvedExecutable(pathValue: environment["PATH"] ?? "") != nil else {
                    throw MCPError.server(code: -32000, message: "Could not find “\(config.command)” on PATH. Install it, or give its full path.")
                }
                let transport = IDEACPTransport(definition: definition, workingDirectory: root, environment: environment)
                registry.set(transport, for: config.name)
                return transport
            }
            let statuses = await newHub.start()
            hub = newHub
            hubKey = key
            var notices: [String] = []
            var running: [String: IDEMCPServerState.Kind] = [:]
            for status in statuses {
                switch status.state {
                case .connected(let tools):
                    running[status.name] = .running(tools: tools)
                case .failed(let reason):
                    let detail = Self.withStandardError(reason, registry.recentStandardError(for: status.name))
                    running[status.name] = .failed(detail)
                    notices.append("MCP server “\(status.name)” did not start: \(detail)")
                }
            }
            states = idleStates(running: running)
            return Prepared(hub: newHub, notices: notices)
        }
    }

    /// Stops every server. Called when the window closes.
    func shutdown() {
        Task { await self.serialized { [self] in await stop() } }
    }

    // MARK: - Internals

    private func stop() async {
        let old = hub
        hub = nil
        hubKey = ""
        let oldRegistry = registry
        registry = TransportRegistry()
        await old?.close()
        oldRegistry.terminateAll()
    }

    /// Runs `body` after everything queued before it, so two chats asking at once start the servers once.
    private func serialized<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = last
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await body()
        }
        last = Task { _ = await task.value }
        return await task.value
    }

    private func idleStates(running: [String: IDEMCPServerState.Kind] = [:]) -> [IDEMCPServerState] {
        var result: [IDEMCPServerState] = []
        for entry in store.servers {
            let kind: IDEMCPServerState.Kind = store.isEnabled(entry.id) ? (running[entry.displayName] ?? .waiting("Starts with the next message")) : .off
            result.append(IDEMCPServerState(id: "user:\(entry.id)", name: entry.displayName, kind: kind))
        }
        for server in project.servers {
            let kind: IDEMCPServerState.Kind = store.isTrusted(server)
                ? (running[server.name] ?? .waiting("Starts with the next message"))
                : (store.isDeclined(server) ? .off : .waiting("Waiting for your OK"))
            result.append(IDEMCPServerState(id: "project:\(server.name)", name: server.name, kind: kind))
        }
        return result
    }

    static func withStandardError(_ reason: String, _ standardError: String) -> String {
        let tail = standardError.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? reason : "\(reason) (\(String(tail.suffix(300))))"
    }
}

/// The transports a hub made, so a start that failed can be explained with what the process said.
final class TransportRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [String: IDEACPTransport] = [:]

    func set(_ transport: IDEACPTransport, for name: String) { lock.withLock { transports[name] = transport } }

    func recentStandardError(for name: String) -> String { lock.withLock { transports[name]?.recentStderr ?? "" } }

    func terminateAll() {
        let all = lock.withLock { () -> [IDEACPTransport] in
            defer { transports = [:] }
            return Array(transports.values)
        }
        for transport in all { transport.terminate() }
    }
}
