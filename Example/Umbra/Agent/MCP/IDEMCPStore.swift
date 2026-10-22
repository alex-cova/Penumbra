import AgentKit
import CryptoKit
import Foundation
import Observation

/// A server the user added in Settings. The secret half of its environment is in the Keychain.
struct IDEMCPServerEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var command: String
    var args: [String]
    /// Names of the environment variables whose values are in the Keychain.
    var envKeys: [String]

    init(id: UUID = UUID(), name: String, command: String, args: [String] = [], envKeys: [String] = []) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.envKeys = envKeys
    }

    var displayName: String { name.isEmpty ? command : name }
    var commandLine: String { ([command] + args).joined(separator: " ") }
}

/// What the user told Umbra about MCP servers: the ones they added, which of those are switched on, and
/// which servers a project file asked for that they said yes or no to. Kept on this Mac; environment
/// values are in the Keychain, never in `UserDefaults`.
@MainActor
@Observable
final class IDEMCPStore {
    private let defaults: UserDefaults
    private let keyStore: any IDEAgentKeyStore

    var servers: [IDEMCPServerEntry] { didSet { persistServers() } }
    /// "Use" is the consent to run an added server.
    private(set) var enabledIDs: Set<UUID> { didSet { defaults.set(enabledIDs.map(\.uuidString).sorted(), forKey: Keys.enabled) } }
    /// Fingerprints of project-file servers the user allowed or refused. A server that changes in any
    /// way (command, arguments, environment) has a new fingerprint and is asked about again.
    private(set) var trusted: Set<String> { didSet { defaults.set(trusted.sorted(), forKey: Keys.trusted) } }
    private(set) var declined: Set<String> { didSet { defaults.set(declined.sorted(), forKey: Keys.declined) } }

    private enum Keys {
        static let servers = "umbra.agent.mcpServers"
        static let enabled = "umbra.agent.mcpEnabled"
        static let trusted = "umbra.agent.mcpTrusted"
        static let declined = "umbra.agent.mcpDeclined"
    }

    init(defaults: UserDefaults, keyStore: any IDEAgentKeyStore) {
        self.defaults = defaults
        self.keyStore = keyStore
        servers = defaults.data(forKey: Keys.servers).flatMap { try? JSONDecoder().decode([IDEMCPServerEntry].self, from: $0) } ?? []
        enabledIDs = Set((defaults.stringArray(forKey: Keys.enabled) ?? []).compactMap(UUID.init(uuidString:)))
        trusted = Set(defaults.stringArray(forKey: Keys.trusted) ?? [])
        declined = Set(defaults.stringArray(forKey: Keys.declined) ?? [])
    }

    // MARK: - Added servers

    /// Adds a server from a typed command line and `KEY=VALUE` lines. Turning "Use" on is a separate
    /// step: adding one does not start it.
    @discardableResult
    func add(name: String, commandLine: String, environment: String) -> IDEMCPServerEntry? {
        guard let parsed = IDEACPDefinition.parseCommandLine(commandLine) else { return nil }
        var entry = IDEMCPServerEntry(name: name.trimmingCharacters(in: .whitespaces), command: parsed.command, args: parsed.args)
        for (key, value) in Self.parseEnvironment(environment) {
            if (try? keyStore.save(value, account: Self.account(entry.id, key))) != nil { entry.envKeys.append(key) }
        }
        servers.append(entry)
        return entry
    }

    func remove(id: UUID) {
        if let entry = servers.first(where: { $0.id == id }) {
            for key in entry.envKeys { try? keyStore.delete(account: Self.account(id, key)) }
        }
        servers.removeAll { $0.id == id }
        enabledIDs.remove(id)
    }

    func isEnabled(_ id: UUID) -> Bool { enabledIDs.contains(id) }

    func setEnabled(_ enabled: Bool, id: UUID) {
        if enabled { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
    }

    /// The servers to start: the ones added here and switched on.
    func enabledConfigs() -> [MCPServerConfig] {
        servers.filter { enabledIDs.contains($0.id) }.map(config(for:))
    }

    func config(for entry: IDEMCPServerEntry) -> MCPServerConfig {
        var env: [String: String] = [:]
        for key in entry.envKeys {
            if let value = try? keyStore.load(account: Self.account(entry.id, key)), !value.isEmpty { env[key] = value }
        }
        return MCPServerConfig(name: entry.displayName, command: entry.command, args: entry.args, env: env)
    }

    static func account(_ id: UUID, _ key: String) -> String { "mcp.\(id.uuidString).\(key)" }

    /// `KEY=VALUE` lines; blank lines, `#` comments and names that are not variable names are skipped.
    static func parseEnvironment(_ text: String) -> [(key: String, value: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            let valid = !key.isEmpty && !(key.first?.isNumber ?? true)
                && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            guard valid else { return nil }
            return (key, String(trimmed[trimmed.index(after: equals)...]))
        }
    }

    // MARK: - Project servers

    /// What the user's yes is about: a hash of everything that decides what would run.
    nonisolated static func fingerprint(of config: MCPServerConfig) -> String {
        SHA256.hash(data: Data(config.canonicalText.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func isTrusted(_ config: MCPServerConfig) -> Bool { trusted.contains(Self.fingerprint(of: config)) }
    func isDeclined(_ config: MCPServerConfig) -> Bool { declined.contains(Self.fingerprint(of: config)) }

    func trust(_ config: MCPServerConfig) {
        let fingerprint = Self.fingerprint(of: config)
        trusted.insert(fingerprint)
        declined.remove(fingerprint)
    }

    func decline(_ config: MCPServerConfig) {
        let fingerprint = Self.fingerprint(of: config)
        declined.insert(fingerprint)
        trusted.remove(fingerprint)
    }

    /// Forgets the answer, so the next chat in the project asks again.
    func forget(_ config: MCPServerConfig) {
        let fingerprint = Self.fingerprint(of: config)
        trusted.remove(fingerprint)
        declined.remove(fingerprint)
    }

    private func persistServers() {
        if let data = try? JSONEncoder().encode(servers) { defaults.set(data, forKey: Keys.servers) }
    }
}

/// The servers a project's own files list: `.umbra/mcp.json`, then `.mcp.json` (Claude Code's file).
/// Read, never run: a server listed here starts only after the user has said yes to exactly it.
enum IDEMCPProjectConfig {
    struct Loaded: Equatable {
        var servers: [MCPServerConfig] = []
        var skipped: [(name: String, reason: String)] = []
        /// A file that exists but cannot be used, for the settings pane.
        var problems: [String] = []

        static func == (lhs: Loaded, rhs: Loaded) -> Bool {
            lhs.servers == rhs.servers && lhs.problems == rhs.problems
                && lhs.skipped.map(\.name) == rhs.skipped.map(\.name)
        }
    }

    static let fileNames = [".umbra/mcp.json", ".mcp.json"]

    static func load(root: URL) -> Loaded {
        var loaded = Loaded()
        var names = Set<String>()
        for name in fileNames {
            let url = root.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            // A link could point anywhere on the Mac; the file must be the project's own.
            guard values.isSymbolicLink != true else {
                loaded.problems.append("\(name) is a symbolic link, which is not read.")
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let file = try MCPConfigFile.parse(data)
                for server in file.servers where names.insert(server.name).inserted { loaded.servers.append(server) }
                loaded.skipped += file.skipped
            } catch {
                loaded.problems.append("\(name): \(error.localizedDescription)")
            }
        }
        return loaded
    }
}
