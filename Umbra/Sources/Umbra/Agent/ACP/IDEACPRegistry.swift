import AgentKit
import Foundation

// MARK: - Presets

/// One way to start a known ACP agent. The command is a bare name resolved on `PATH`.
struct IDEACPLauncher: Equatable, Sendable {
    var command: String
    var args: [String]
    /// True when this launcher is an adapter rather than the agent's own ACP mode.
    var isAdapter: Bool
    var note: String
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

    /// The catalog entry that installs or detects this agent.
    var entry: IDEACPAdapterEntry? { IDEACPAdapterCatalog.entry(presetID: id) }

    /// The command a definition created from this preset records. It is documentation for an
    /// `.auto` row: the real launch comes from `IDEACPLaunchResolver`.
    var recordedLauncher: IDEACPLauncher { launchers[0] }

    /// Resolves this preset the way an `.auto` row would, against a managed install if given.
    func resolution(
        active: IDEACPActiveInstall?, pathValue: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        systemPackageName: (String) -> String? = IDEACPLaunchResolver.packageName(ofExecutable:)
    ) -> IDEACPLaunchResolver.Resolution {
        let launcher = recordedLauncher
        let definition = IDEACPDefinition(
            name: name, command: launcher.command, args: launcher.args, presetID: id, launchMode: .auto)
        return IDEACPLaunchResolver.resolve(
            definition: definition, entry: entry, active: active, pathValue: pathValue,
            isExecutable: isExecutable, systemPackageName: systemPackageName)
    }
}

enum IDEACPRegistry {
    /// Claude Code and Codex do not speak ACP themselves. Gemini CLI and OpenCode do.
    /// Commands verified against the ACP registry (November 2026): the
    /// `@agentclientprotocol/claude-agent-acp` and `codex-acp` packages, `gemini --acp`,
    /// `opencode acp`. Umbra installs the two adapters itself (`IDEACPAdapterManager`); it never
    /// falls back to `npx`, which would download and run a package as a side effect.
    static let presets: [IDEACPPreset] = [
        IDEACPPreset(
            id: "claude-code",
            name: "Claude Code",
            summary: "Claude Code through the Agent Client Protocol adapter.",
            authHint: "Uses a Claude Code login, or ANTHROPIC_API_KEY. Umbra never stores that key in the transcript.",
            launchers: [
                IDEACPLauncher(
                    command: "claude-agent-acp", args: [], isAdapter: true,
                    note: "Adapter installed by Umbra, or a verified system copy."),
            ]),
        IDEACPPreset(
            id: "codex",
            name: "Codex",
            summary: "Codex CLI through the Agent Client Protocol adapter.",
            authHint: "Uses a ChatGPT login, or CODEX_API_KEY / OPENAI_API_KEY.",
            launchers: [
                IDEACPLauncher(
                    command: "codex-acp", args: [], isAdapter: true,
                    note: "Adapter installed by Umbra, or a verified system copy."),
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
        // Kiro, Cursor and Muse speak ACP themselves. Commands verified against the installed CLIs on
        // 2026-11-16 (Kiro CLI 2.24.1, Cursor CLI 2026.11.05, Muse 1.4.20): initialize and session/new.
        IDEACPPreset(
            id: "kiro",
            name: "Kiro",
            summary: "Kiro CLI's built-in ACP mode.",
            authHint: IDEACPAdapterCatalog.kiro.authHint,
            launchers: [
                IDEACPLauncher(
                    command: "kiro-cli", args: ["acp"], isAdapter: false,
                    note: "Native ACP. kiro-cli acp"),
            ]),
        IDEACPPreset(
            id: "cursor",
            name: "Cursor",
            summary: "Cursor CLI's built-in ACP mode.",
            authHint: IDEACPAdapterCatalog.cursor.authHint,
            launchers: [
                IDEACPLauncher(
                    command: "agent", args: ["acp"], isAdapter: false,
                    note: "Native ACP. agent acp (Cursor's agent, checked by its install path)"),
            ]),
        IDEACPPreset(
            id: "muse",
            name: "Muse",
            summary: "Muse Code's ACP mode (experimental).",
            authHint: IDEACPAdapterCatalog.muse.authHint,
            launchers: [
                IDEACPLauncher(
                    command: "muse", args: ["acp"], isAdapter: false,
                    note: "Native ACP. muse acp"),
            ]),
        IDEACPPreset(
            id: "antigravity",
            name: "Antigravity",
            summary: "Antigravity CLI's built-in ACP mode.",
            authHint: IDEACPAdapterCatalog.antigravity.authHint,
            launchers: [
                IDEACPLauncher(
                    command: "agy", args: ["acp"], isAdapter: false,
                    note: "Native ACP. agy acp"),
            ]),
        IDEACPPreset(
            id: "copilot",
            name: "GitHub Copilot",
            summary: "GitHub Copilot CLI's ACP mode (public preview).",
            authHint: IDEACPAdapterCatalog.copilot.authHint,
            launchers: [
                IDEACPLauncher(
                    command: "copilot", args: ["--acp"], isAdapter: false,
                    note: "Native ACP. copilot --acp"),
            ]),
        IDEACPPreset(
            id: "kimi",
            name: "Kimi Code",
            summary: "Kimi Code CLI's built-in ACP mode.",
            authHint: IDEACPAdapterCatalog.kimi.authHint,
            launchers: [
                IDEACPLauncher(
                    command: "kimi", args: ["acp"], isAdapter: false,
                    note: "Native ACP. kimi acp"),
            ]),
        IDEACPPreset(
            id: "qwen",
            name: "Qwen Code",
            summary: "Qwen Code's ACP mode.",
            authHint: IDEACPAdapterCatalog.qwen.authHint,
            launchers: [
                IDEACPLauncher(
                    command: "qwen", args: ["--acp"], isAdapter: false,
                    note: "Native ACP. qwen --acp"),
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
    /// The adapter is not installed. Settings ▸ Agent ▸ Adapters installs it.
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
    /// `installable` is an agent Umbra can install itself: without an executable it reads
    /// "Adapter not installed" and points at Settings instead of "Not installed".
    static func resolve(
        isEnabled: Bool, executableFound: Bool, probe: IDEACPProbe?, isLive: Bool, installable: Bool = false
    ) -> IDEACPAvailability {
        if !isEnabled { return .disabled }
        if isLive { return .connected }
        if let probe {
            switch probe.phase {
            case .authenticationRequired(let method): return .authenticationRequired(method)
            case .failed(let message):
                if !executableFound { return installable ? .adapterMissing : .notInstalled }
                if Self.isProtocolMismatch(message) { return .incompatibleProtocol(message) }
                if Self.isDisconnect(message) { return .disconnected }
                return .failed(message)
            case .connected, .running:
                break
            }
        }
        if !executableFound { return installable ? .adapterMissing : .notInstalled }
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
    static let unsupportedNotice = "This agent cannot resume a remote session, so a new session was started. Your next message brings the earlier conversation with it."
    static let staleNotice = "The previous remote session is no longer available, so a new session was started. Your next message brings the earlier conversation with it."
    static let freshHistoryNotice = "A new remote session was started for this transcript. Your next message brings the earlier conversation with it."

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
            || message.contains("log in") || message.contains("logged in") || message.contains("unauthor")
    }

    /// `isAuthenticationFailure`, or ACP's auth-required code (`-32000`) from an agent that advertised
    /// a way to sign in, whatever its wording.
    static func isAuthenticationRequired(_ error: Error, agentAdvertisedMethods: Bool) -> Bool {
        if isAuthenticationFailure(error) { return true }
        guard agentAdvertisedMethods, let acp = error as? ACPError, case .agentError(let rpc) = acp else { return false }
        return rpc.code == -32000
    }

    /// What to tell the user when an agent that never signs in on its own needs a login. The agent's
    /// own message is kept (Muse puts the device link and code there), scrubbed of anything that looks
    /// like a credential, then the CLI's login command.
    static func signInMessage(agent: String, agentMessage: String, loginCommand: String?) -> String {
        var parts = ["\(agent) needs you to sign in."]
        let detail = IDEACPSecretScrubber.scrub(agentMessage).trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty, detail.lowercased() != "authentication required" { parts.append(detail) }
        if let loginCommand {
            parts.append("Run “\(loginCommand)” in Terminal, then send your message again.")
        }
        return parts.joined(separator: " ")
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

    /// The advertised values with the agent's description of each and its price multiplier, for the model list.
    var selectableChoiceDetails: [(value: String, title: String, detail: String?, rate: ACPChoiceRate?)] {
        (raw["options"]?.arrayValue ?? []).compactMap { option in
            guard let value = option["value"]?.stringValue ?? option["id"]?.stringValue, !value.isEmpty else { return nil }
            let detail = option["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return (value, option["name"]?.stringValue ?? value, detail, ACPChoiceRate(option: option))
        }
    }

    /// The model as a config option (Muse, Kiro 3.x): ACP's `model` category, or an uncategorized `model` id.
    var isModelOption: Bool {
        if let category { return category == "model" }
        return id.lowercased() == "model"
    }

    /// A speed switch: category `speed` (the Codex and Claude Code adapters: `fast-mode` / `fast`, Off and On,
    /// captured 2026-11-21), or an uncategorized option named for it (`fast`, `speed`…). Nothing is shown for an
    /// agent that does not advertise one.
    var isSpeedOption: Bool {
        guard !selectableChoices.isEmpty else { return false }
        if category == "speed" { return true }
        guard category == nil else { return false }
        let key = (id + " " + name).lowercased()
        return key.contains("speed") || key.contains("fast")
    }

    /// Whether `value` of a speed option means the fast setting.
    static func isFastValue(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return ["on", "true", "1", "yes", "enabled"].contains(value) || value.contains("fast")
    }

    /// ACP's `thought_level` category, or an uncategorized option named for effort or reasoning
    /// (`effort`, `reasoning_effort`, …) from an agent that predates the category.
    var isEffortOption: Bool {
        if let category { return category == "thought_level" }
        let key = id.lowercased()
        return key.contains("effort") || key.contains("reasoning") || key == "thought_level"
    }

    /// The advertised title of the current value ("High" for `high`).
    var currentChoiceTitle: String? {
        guard let current = currentValueDescription else { return nil }
        return selectableChoices.first { $0.value == current }?.title ?? current
    }
}

/// What a choice costs relative to the agent's base rate, from its `_meta` (Kiro sends
/// `_meta.kiro.rateMultiplier` and `rateUnit: "Credit"` on each model: `auto` 1, claude-opus-5.5 2,
/// gpt-5.6-sol 4.4, claude-haiku-5.5 0.06). Read from any vendor key, since ACP has no standard field for it.
struct ACPChoiceRate: Equatable {
    let multiplier: Double
    /// The agent's unit ("Credit"), when it named one.
    let unit: String?

    init?(option: JSONValue) {
        guard case .object(let meta)? = option["_meta"] else { return nil }
        for key in meta.keys.sorted() {
            guard case .object(let vendor)? = meta[key] else { continue }
            let number: Double?
            switch vendor["rateMultiplier"] {
            case .int(let value)?: number = Double(value)
            case .double(let value)?: number = value
            default: number = nil
            }
            guard let number, number.isFinite, number >= 0 else { continue }
            multiplier = number
            unit = vendor["rateUnit"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return
        }
        return nil
    }

    init(multiplier: Double, unit: String?) {
        self.multiplier = multiplier
        self.unit = unit
    }

    /// "2×", "0.06×", "4.4×".
    var label: String {
        let text = multiplier.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
        return text + "×"
    }

    /// "Uses 2× the credits of the base rate per request."
    var help: String {
        let unit = (unit ?? "usage").lowercased()
        return "Uses \(label) the \(unit == "credit" ? "credits" : unit) of the base rate."
    }
}

/// The settings an agent writes into a model id. Cursor offers each model as fixed variants named like
/// `claude-opus-5-5[context=300k,effort=medium,fast=false]` (captured from cursor-agent on 2026-11-21): the effort
/// and speed cannot be set apart from the model, so Umbra only shows them, on the chip and the model's row.
struct ACPModelVariant: Equatable {
    /// The parameters in the order the agent wrote them.
    let parameters: [Parameter]

    struct Parameter: Equatable {
        let key: String
        let value: String
    }

    init?(modelID: String) {
        guard modelID.hasSuffix("]"), let open = modelID.lastIndex(of: "[") else { return nil }
        let body = modelID[modelID.index(after: open)..<modelID.index(before: modelID.endIndex)]
        let pairs: [Parameter] = body.split(separator: ",").compactMap { part in
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !kv[0].isEmpty, !kv[1].isEmpty else { return nil }
            return Parameter(key: kv[0].lowercased(), value: kv[1])
        }
        guard !pairs.isEmpty else { return nil }
        parameters = pairs
    }

    private func value(_ keys: String...) -> String? {
        parameters.first { keys.contains($0.key) }?.value
    }

    /// `effort`, `reasoning_effort` or `reasoning`, as written ("medium", "xhigh").
    var effort: String? { value("effort", "reasoning_effort", "reasoning") }

    var isFast: Bool { value("fast")?.lowercased() == "true" }

    /// "300k context · effort medium · thinking · fast", for the model's row.
    var summary: String {
        var parts: [String] = []
        if let context = value("context") { parts.append("\(context) context") }
        if let effort { parts.append("effort \(effort)") }
        if value("thinking")?.lowercased() == "true" { parts.append("thinking") }
        if isFast { parts.append("fast") }
        return parts.joined(separator: " · ")
    }

    /// "Medium", "xHigh", for the chip.
    static func effortTitle(_ effort: String) -> String {
        effort.lowercased() == "xhigh" ? "xHigh" : effort.prefix(1).uppercased() + effort.dropFirst()
    }
}
