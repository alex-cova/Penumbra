import AgentKit
import Foundation

// MARK: - Presets

/// One way to start a known ACP agent. The command is a bare name or `npx`, resolved on `PATH`.
struct IDEACPLauncher: Equatable, Sendable {
    var command: String
    var args: [String]
    /// True when this launcher is an adapter rather than the agent's own ACP mode.
    var isAdapter: Bool
    var note: String

    /// True for a package runner that may download on first launch (`npx -y`).
    var downloadsPackage: Bool { command == "npx" }
}

/// A verified ACP agent Umbra knows how to offer. Discovery only checks that the command
/// resolves; it does not run it.
struct IDEACPPreset: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var summary: String
    var authHint: String
    /// Tried in order. The first command that resolves on `PATH` is the one offered.
    var launchers: [IDEACPLauncher]

    func preferredLaunch(
        pathValue: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> IDEACPLauncher {
        for launcher in launchers {
            let probe = IDEACPDefinition(name: name, command: launcher.command, args: launcher.args)
            if probe.resolvedExecutable(pathValue: pathValue, isExecutable: isExecutable) != nil {
                return launcher
            }
        }
        return launchers[0]
    }

    /// A real binary resolved. An `npx` fallback does not count as installed.
    func isInstalled(
        pathValue: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Bool {
        launchers.contains { launcher in
            guard !launcher.downloadsPackage else { return false }
            let probe = IDEACPDefinition(name: name, command: launcher.command, args: launcher.args)
            return probe.resolvedExecutable(pathValue: pathValue, isExecutable: isExecutable) != nil
        }
    }

    /// `npx` is on `PATH` and no adapter binary is. Running it can download a package.
    func canDownload(
        pathValue: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Bool {
        guard !isInstalled(pathValue: pathValue, isExecutable: isExecutable) else { return false }
        return launchers.contains { launcher in
            guard launcher.downloadsPackage else { return false }
            let probe = IDEACPDefinition(name: name, command: launcher.command, args: launcher.args)
            return probe.resolvedExecutable(pathValue: pathValue, isExecutable: isExecutable) != nil
        }
    }
}

enum IDEACPRegistry {
    /// Claude Code and Codex do not speak ACP themselves. Gemini CLI and OpenCode do.
    /// Commands verified against the ACP registry (November 2026):
    /// `npx @agentclientprotocol/claude-agent-acp`, `npx @agentclientprotocol/codex-acp`,
    /// `gemini --acp`, `opencode acp`. A globally installed adapter binary is preferred
    /// over `npx` so a later lookup does not download anything.
    static let presets: [IDEACPPreset] = [
        IDEACPPreset(
            id: "claude-code",
            name: "Claude Code",
            summary: "Claude Code through the Agent Client Protocol adapter.",
            authHint: "Uses a Claude Code login, or ANTHROPIC_API_KEY. Umbra never stores that key in the transcript.",
            launchers: [
                IDEACPLauncher(
                    command: "claude-agent-acp", args: [], isAdapter: true,
                    note: "Installed adapter binary."),
                IDEACPLauncher(
                    command: "npx", args: ["-y", "@agentclientprotocol/claude-agent-acp"], isAdapter: true,
                    note: "The first allowed run may download @agentclientprotocol/claude-agent-acp."),
            ]),
        IDEACPPreset(
            id: "codex",
            name: "Codex",
            summary: "Codex CLI through the Agent Client Protocol adapter.",
            authHint: "Uses a ChatGPT login, or CODEX_API_KEY / OPENAI_API_KEY.",
            launchers: [
                IDEACPLauncher(
                    command: "codex-acp", args: [], isAdapter: true,
                    note: "Installed adapter binary."),
                IDEACPLauncher(
                    command: "npx", args: ["-y", "@agentclientprotocol/codex-acp"], isAdapter: true,
                    note: "The first allowed run may download @agentclientprotocol/codex-acp."),
            ]),
        IDEACPPreset(
            id: "gemini",
            name: "Gemini CLI",
            summary: "Gemini CLI's built-in ACP mode.",
            authHint: "Uses the Gemini CLI login, or GEMINI_API_KEY.",
            launchers: [
                IDEACPLauncher(
                    command: "gemini", args: ["--acp"], isAdapter: false,
                    note: "Native ACP. gemini --acp"),
            ]),
        IDEACPPreset(
            id: "opencode",
            name: "OpenCode",
            summary: "OpenCode's built-in ACP mode.",
            authHint: "Uses the providers you signed in to with opencode.",
            launchers: [
                IDEACPLauncher(
                    command: "opencode", args: ["acp"], isAdapter: false,
                    note: "Native ACP. opencode acp"),
            ]),
    ]

    static func preset(id: String) -> IDEACPPreset? { presets.first { $0.id == id } }
}

// MARK: - Status

/// What the selector and the settings list say about an agent. Discovery never produces
/// `.connected`; that comes from a live session or a connection test the user started.
/// The ACP process for the chat that is on screen.
enum IDEACPLiveState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case authenticationRequired(String)
    case failed(String)
}

enum IDEACPAvailability: Equatable, Sendable {
    case installed
    case notInstalled
    /// The agent's own binary is absent. `npx` could download an adapter, and nothing has yet.
    case adapterMissing
    case authenticationRequired(String)
    case connected
    case disconnected
    case incompatibleProtocol(String)
    case failed(String)
    case disabled

    var title: String {
        switch self {
        case .installed: "Installed"
        case .notInstalled: "Not installed"
        case .adapterMissing: "Adapter not installed"
        case .authenticationRequired: "Authentication required"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .incompatibleProtocol: "Incompatible protocol"
        case .failed: "Error"
        case .disabled: "Disabled"
        }
    }

    var detail: String? {
        switch self {
        case .authenticationRequired(let method): method
        case .incompatibleProtocol(let message), .failed(let message): message
        default: nil
        }
    }
}

struct IDEACPProbe: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case running
        case connected(protocolVersion: Int, agentName: String?, loadSession: Bool)
        case authenticationRequired(String)
        case failed(String)
    }

    var phase: Phase
    var checkedAt: Date
}

enum IDEACPAvailabilityResolver {
    /// `isLive` is a session that is up now. A saved probe never outranks a missing executable,
    /// and a disabled agent is never reported as connected.
    static func resolve(
        isEnabled: Bool, executableFound: Bool, probe: IDEACPProbe?, isLive: Bool, downloadsOnUse: Bool = false
    ) -> IDEACPAvailability {
        if !isEnabled { return .disabled }
        if isLive { return .connected }
        if let probe {
            switch probe.phase {
            case .authenticationRequired(let method): return .authenticationRequired(method)
            case .failed(let message):
                if !executableFound { return .notInstalled }
                if Self.isProtocolMismatch(message) { return .incompatibleProtocol(message) }
                if Self.isDisconnect(message) { return .disconnected }
                return .failed(message)
            case .connected, .running:
                break
            }
        }
        if !executableFound { return .notInstalled }
        if downloadsOnUse, probe == nil { return .adapterMissing }
        return .installed
    }

    static func isProtocolMismatch(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("protocol version")
    }

    static func isDisconnect(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("disconnected")
    }
}

/// How a saved ACP session id is used on the next connection. The live `initialize`
/// result is the authority. A saved id is never assumed to still exist.
enum IDEACPSessionResume {
    static let restoredNotice = "Restored the remote session. Earlier messages were not sent again."
    static let unsupportedNotice = "This agent cannot resume a remote session. The transcript was kept, and a new session was started. Earlier messages were not sent again."
    static let staleNotice = "The previous remote session is no longer available. The transcript was kept, and a new session was started. Earlier messages were not sent again."
    static let freshHistoryNotice = "This transcript was kept. A new remote session was started. Earlier messages were not sent again."

    enum Plan: Equatable {
        case load(String)
        case create(notice: String?)
    }

    /// A blank or whitespace-only id is not a session. It is not sent to `session/load`.
    static func normalizedSessionID(_ savedSessionID: String?) -> String? {
        guard let trimmed = savedSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func plan(savedSessionID: String?, agentSupportsLoad: Bool, hasEarlierTranscript: Bool) -> Plan {
        let savedSessionID = normalizedSessionID(savedSessionID)
        if let savedSessionID, agentSupportsLoad {
            return .load(savedSessionID)
        }
        if savedSessionID != nil {
            return .create(notice: unsupportedNotice)
        }
        if hasEarlierTranscript { return .create(notice: freshHistoryNotice) }
        return .create(notice: nil)
    }
}

/// The tail of an agent process's stderr, safe to show in the chat. Secrets are removed
/// and the text is capped so a noisy process cannot fill the transcript.
enum IDEACPDiagnostics {
    static let maxCharacters = 400
    static let maxLines = 4

    static func detail(_ raw: String) -> String? {
        let scrubbed = IDEACPSecretScrubber.scrub(raw)
        let lines = scrubbed.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        var tail = lines.suffix(maxLines).joined(separator: "\n")
        if tail.count > maxCharacters {
            tail = "…" + String(tail.suffix(maxCharacters))
        }
        return tail
    }
}

// MARK: - Binding and switching

/// Which agent a chat is bound to. `agentID == nil` is Umbra Native.
/// A missing pin means the chat still follows the default.
struct IDEACPBinding: Equatable, Sendable, Codable {
    var agentID: UUID?

    static let native = IDEACPBinding(agentID: nil)
    static func agent(_ id: UUID) -> IDEACPBinding { IDEACPBinding(agentID: id) }
}

enum IDEACPBindingResolver {
    /// A chat with its own model choice (AI mode) wins, including a choice that names no ACP agent.
    /// Otherwise a pin wins over the default, so a later default does not move a transcript.
    static func agentID(pin: IDEACPBinding?, modelChoice: IDEAIModelChoice?, defaultID: UUID?) -> UUID? {
        if let modelChoice { return modelChoice.acpAgentID }
        if let pin { return pin.agentID }
        return defaultID
    }
}

struct IDEACPChatRef: Equatable, Sendable {
    var id: UUID
    var isEmpty: Bool
    var isRunning: Bool
    var pin: IDEACPBinding?
    var hasModelChoice: Bool
    var modelACPAgentID: UUID?

    func resolvedAgentID(defaultID: UUID?) -> UUID? {
        IDEACPBindingResolver.agentID(
            pin: pin,
            modelChoice: hasModelChoice
                ? IDEAIModelChoice(provider: .mlx, model: "", acpAgentID: modelACPAgentID)
                : nil,
            defaultID: defaultID)
    }
}

enum IDEACPSwitchEffect: Equatable, Sendable {
    case stay
    /// The selected chat has no transcript. Bind it in place.
    case rebind(UUID)
    /// Leave the selected chat as it is and show another one. `existing` is an empty chat
    /// already bound to the target; nil means a new chat should be opened.
    case open(keeping: UUID, existing: UUID?, previousIsRunning: Bool)
}

enum IDEACPProviderSwitch {
    /// Switching never rewrites a chat that already has messages. A running chat is left
    /// running; Stop is still the way to cancel it.
    static func plan(
        selected: IDEACPChatRef, chats: [IDEACPChatRef], target: IDEACPBinding, defaultID: UUID?
    ) -> IDEACPSwitchEffect {
        if selected.resolvedAgentID(defaultID: defaultID) == target.agentID { return .stay }
        if selected.isEmpty, !selected.isRunning { return .rebind(selected.id) }
        let existing = chats.first {
            $0.id != selected.id && $0.isEmpty && !$0.isRunning
                && $0.resolvedAgentID(defaultID: defaultID) == target.agentID
        }
        return .open(keeping: selected.id, existing: existing?.id, previousIsRunning: selected.isRunning)
    }
}

// MARK: - Secrets in diagnostics

enum IDEACPSecretScrubber {
    /// Removes values that look like credentials from a diagnostic string. The original
    /// process environment is never written here.
    static func scrub(_ text: String) -> String {
        var result = text
        let patterns = [
            #"sk-[A-Za-z0-9_\-]{8,}"#,
            #"(?i)bearer\s+[A-Za-z0-9._\-]{8,}"#,
            #"(?i)(api[_-]?key|token|secret|password)\s*[=:]\s*\S+"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return result
    }
}

enum IDEACPAuth {
    /// A failed `session/new` that the agent described as authentication. A missing executable
    /// uses the same JSON-RPC code and must not be reported as a sign-in.
    static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let acp = error as? ACPError, case .agentError(let rpc) = acp else { return false }
        let message = rpc.message.lowercased()
        return message.contains("auth") || message.contains("sign in") || message.contains("login")
            || message.contains("unauthor")
    }
}

extension ACPConfigOption {
    /// Values the agent advertised for a select option. Empty when the option has none,
    /// so the UI does not invent a model list.
    var selectableChoices: [(value: String, title: String)] {
        (raw["options"]?.arrayValue ?? []).compactMap { option in
            guard let value = option["value"]?.stringValue ?? option["id"]?.stringValue, !value.isEmpty else { return nil }
            return (value, option["name"]?.stringValue ?? value)
        }
    }
}
