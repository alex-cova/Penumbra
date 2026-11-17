import AgentKit
import Foundation

/// An npm package Umbra can install into its own folder.
struct IDEACPNpmSource: Equatable, Sendable {
    var package: String
    var binName: String
    /// Entry script inside the package directory.
    var entryPath: String
    /// The repository the publisher's provenance must name.
    var repository: String
    /// The npm trusted-publisher type the version must have been published with.
    var trustedPublisher: String
    /// Used when the package declares no `engines.node`.
    var fallbackMinimumNode: Int
}

enum IDEACPAdapterKind: Equatable, Sendable {
    /// Needs an adapter installed. Umbra can install it from npm.
    case npmPackage(IDEACPNpmSource)
    /// The agent's own CLI speaks ACP. Umbra detects it and never installs it.
    case nativeCLI(command: String, args: [String])
    /// A user-managed executable.
    case custom
}

/// A check on the file a bare command name resolved to, after following symbolic links. A
/// generic name (`agent`) can belong to another program on `PATH`: on a Mac with Grok's CLI the
/// first `agent` is Grok's, not Cursor's. A candidate that fails the check is skipped, never run.
struct IDEACPExecutableIdentity: Equatable, Sendable {
    /// The resolved path must contain one of these, ignoring case.
    var resolvedPathContainsAny: [String]

    func accepts(resolvedPath: String) -> Bool {
        let path = resolvedPath.lowercased()
        return resolvedPathContainsAny.contains { path.contains($0.lowercased()) }
    }
}

/// Provider extension methods Umbra can answer (`ACPClientExtension`).
enum IDEACPExtensionKind: Equatable, Sendable {
    case cursor

    func make() -> any ACPClientExtension {
        switch self {
        case .cursor: CursorACPExtension()
        }
    }
}

/// One agent in the catalog. The catalog is code, not downloaded data: what Umbra trusts to
/// install is decided here and reviewed with the source, never by a remote manifest.
/// Versions are not listed; they come from the registry at check time.
struct IDEACPAdapterEntry: Equatable, Sendable, Identifiable {
    var id: String
    var presetID: String
    var name: String
    var provider: String
    var symbol: String
    var kind: IDEACPAdapterKind
    /// Command that a system-wide install of the adapter would have on `PATH`.
    var systemCommand: String?
    var authHint: String
    /// Rough size of the whole install tree, platform binary included, for the disk check and the
    /// approval sheet. The registry only knows the adapter's own few megabytes.
    var approximateInstallBytes: Int64
    /// Other names a native CLI is installed under, tried after `kind`'s command.
    var alternateCommands: [String] = []
    /// Folders searched after `PATH` (`~` is the home folder), for CLIs whose installer puts them
    /// where a GUI app's `PATH` may not reach.
    var extraSearchDirectories: [String] = []
    /// Required when the command name is generic enough to belong to another program.
    var executableIdentity: IDEACPExecutableIdentity? = nil
    /// The CLI's own sign-in, shown when the agent says authentication is needed.
    var loginCommand: String? = nil
    /// `.userInitiated` never starts the agent's login flow unasked.
    var authenticationPolicy: ACPAuthenticationPolicy = .automatic
    var extensions: [IDEACPExtensionKind] = []
    /// Umbra's permission mode → the agent's own mode id, for agents whose modes are approval
    /// policies Umbra cannot otherwise enforce (they run tools themselves, not through Umbra's
    /// file and terminal services). Applied only when the agent advertised that id.
    var permissionModeMap: [PermissionMode: String] = [:]
    /// The agent mode to return to when Umbra leaves a mapped mode and the new one has no entry.
    var defaultAgentModeID: String? = nil
    /// Where to get the CLI, shown when it is not installed. Umbra never installs it.
    var installHint: String? = nil
    /// Shown beside the agent: its ACP support is early and may change.
    var isExperimental = false

    /// The agent's mode for a permission mode change, or nil to leave the agent's mode alone.
    /// `current` is the agent's mode now: leaving a mapped mode for an unmapped one goes back to the
    /// default, and a mode the user picked on the agent's own chip is otherwise kept.
    func agentModeID(for mode: PermissionMode, current: String?, advertised: [String]) -> String? {
        let target: String?
        if let mapped = permissionModeMap[mode] {
            target = mapped
        } else if let current, permissionModeMap.values.contains(current) {
            target = defaultAgentModeID
        } else {
            target = nil
        }
        guard let target, target != current, advertised.contains(target) else { return nil }
        return target
    }

    var npm: IDEACPNpmSource? {
        if case .npmPackage(let source) = kind { return source }
        return nil
    }

    var isManaged: Bool { npm != nil }

    var strategies: [String] {
        switch kind {
        case .npmPackage: ["Isolated npm prefix, scripts disabled"]
        case .nativeCLI: ["Existing CLI with native ACP support"]
        case .custom: ["User-managed executable"]
        }
    }
}

enum IDEACPAdapterCatalog {
    static let codex = IDEACPAdapterEntry(
        id: "codex-acp",
        presetID: "codex",
        name: "Codex",
        provider: "OpenAI",
        symbol: "terminal",
        kind: .npmPackage(IDEACPNpmSource(
            package: "@agentclientprotocol/codex-acp",
            binName: "codex-acp",
            entryPath: "dist/index.js",
            repository: "https://github.com/agentclientprotocol/codex-acp",
            trustedPublisher: "github",
            fallbackMinimumNode: 20)),
        systemCommand: "codex-acp",
        authHint: "Uses a ChatGPT login, or CODEX_API_KEY / OPENAI_API_KEY.",
        approximateInstallBytes: 450_000_000)

    static let claude = IDEACPAdapterEntry(
        id: "claude-agent-acp",
        presetID: "claude-code",
        name: "Claude Code",
        provider: "Anthropic",
        symbol: "sparkle",
        kind: .npmPackage(IDEACPNpmSource(
            package: "@agentclientprotocol/claude-agent-acp",
            binName: "claude-agent-acp",
            entryPath: "dist/index.js",
            repository: "https://github.com/agentclientprotocol/claude-agent-acp",
            trustedPublisher: "github",
            fallbackMinimumNode: 22)),
        systemCommand: "claude-agent-acp",
        authHint: "Uses a Claude Code login, or ANTHROPIC_API_KEY. Umbra never stores that key in the transcript.",
        approximateInstallBytes: 400_000_000)

    static let gemini = IDEACPAdapterEntry(
        id: "gemini",
        presetID: "gemini",
        name: "Gemini CLI",
        provider: "Google",
        symbol: "diamond",
        kind: .nativeCLI(command: "gemini", args: ["--acp"]),
        systemCommand: nil,
        authHint: "Uses the Gemini CLI login, or GEMINI_API_KEY.",
        approximateInstallBytes: 0)

    static let opencode = IDEACPAdapterEntry(
        id: "opencode",
        presetID: "opencode",
        name: "OpenCode",
        provider: "OpenCode",
        symbol: "chevron.left.forwardslash.chevron.right",
        kind: .nativeCLI(command: "opencode", args: ["acp"]),
        systemCommand: nil,
        authHint: "Uses the providers you signed in to with opencode (opencode auth login). Umbra never copies them.",
        approximateInstallBytes: 0,
        extraSearchDirectories: ["~/.opencode/bin", "~/.local/bin"],
        loginCommand: "opencode auth login",
        authenticationPolicy: .userInitiated,
        installHint: "Install OpenCode (opencode.ai), then press Detect Again.")

    /// Kiro CLI (https://kiro.dev/docs/cli/acp/). Its modes are agent configurations, not approval
    /// policies, so no permission mapping. Models come in the session's `models` field.
    static let kiro = IDEACPAdapterEntry(
        id: "kiro",
        presetID: "kiro",
        name: "Kiro",
        provider: "Kiro",
        symbol: "wand.and.stars",
        kind: .nativeCLI(command: "kiro-cli", args: ["acp"]),
        systemCommand: nil,
        authHint: "Uses your Kiro sign-in. Run kiro-cli login in Terminal if Umbra says you need to sign in.",
        approximateInstallBytes: 0,
        extraSearchDirectories: ["~/.local/bin"],
        loginCommand: "kiro-cli login",
        authenticationPolicy: .userInitiated,
        installHint: "Install Kiro CLI from kiro.dev/cli, then press Detect Again.")

    /// Cursor CLI (https://cursor.com/docs/cli/acp). `agent` is a generic name, so the resolved file
    /// must be Cursor's (its installer links `agent` and `cursor-agent` into a `cursor-agent` folder;
    /// Homebrew's cask is named `cursor-cli`).
    static let cursor = IDEACPAdapterEntry(
        id: "cursor",
        presetID: "cursor",
        name: "Cursor",
        provider: "Anysphere",
        symbol: "cursorarrow.rays",
        kind: .nativeCLI(command: "agent", args: ["acp"]),
        systemCommand: nil,
        authHint: "Uses your Cursor CLI login (agent login), or CURSOR_API_KEY set as a secret below.",
        approximateInstallBytes: 0,
        alternateCommands: ["cursor-agent"],
        extraSearchDirectories: ["~/.local/bin"],
        executableIdentity: IDEACPExecutableIdentity(resolvedPathContainsAny: ["cursor-agent", "cursor-cli", "/cursor"]),
        loginCommand: "agent login",
        authenticationPolicy: .userInitiated,
        extensions: [.cursor],
        permissionModeMap: [.plan: "plan"],
        defaultAgentModeID: "agent",
        installHint: "Install Cursor CLI from cursor.com/cli, then press Detect Again.")

    /// Muse Code (`muse acp`). It reads and writes the disk and runs tools itself, never through
    /// Umbra's file and terminal services, and starts in `allowAll` ("run every action without
    /// asking"). Umbra's permission mode is therefore applied as Muse's approval mode.
    static let muse = IDEACPAdapterEntry(
        id: "muse",
        presetID: "muse",
        name: "Muse",
        provider: "Meta",
        symbol: "sparkles",
        kind: .nativeCLI(command: "muse", args: ["acp"]),
        systemCommand: nil,
        authHint: "Uses your Muse Code login. Run muse login in Terminal if Umbra says you need to sign in.",
        approximateInstallBytes: 0,
        extraSearchDirectories: ["~/.local/bin"],
        loginCommand: "muse login",
        authenticationPolicy: .userInitiated,
        permissionModeMap: [
            .manual: "promptUnmatched",
            .acceptEdits: "promptUnmatched",
            .auto: "onRequest",
            .plan: "denyUnmatched",
        ],
        installHint: "Install Muse Code, then press Detect Again.",
        isExperimental: true)

    /// Google Antigravity (`agy acp`, https://antigravity.google/docs/cli/acp/). Measured against
    /// agy 1.5.3: its modes `default`, `accept-edits` and `plan` are approval policies, so Umbra's
    /// permission mode is applied as the agent's mode (only when the agent advertised the id).
    static let antigravity = IDEACPAdapterEntry(
        id: "antigravity",
        presetID: "antigravity",
        name: "Antigravity",
        provider: "Google",
        symbol: "arrow.up.forward.circle",
        kind: .nativeCLI(command: "agy", args: ["acp"]),
        systemCommand: nil,
        authHint: "Uses your Antigravity CLI sign-in (Google account, Gemini Enterprise or a Gemini API key). Run agy in Terminal to sign in.",
        approximateInstallBytes: 0,
        extraSearchDirectories: ["~/.local/bin"],
        loginCommand: "agy",
        authenticationPolicy: .userInitiated,
        permissionModeMap: [.manual: "default", .acceptEdits: "accept-edits", .plan: "plan"],
        defaultAgentModeID: "default",
        installHint: "Install the Antigravity CLI from antigravity.google, then press Detect Again.")

    /// GitHub Copilot CLI (`copilot --acp`, public preview). Needs a Copilot plan; the entitlement
    /// is GitHub's to decide, and an account without one shows up as the agent's own error.
    static let copilot = IDEACPAdapterEntry(
        id: "copilot",
        presetID: "copilot",
        name: "GitHub Copilot",
        provider: "GitHub",
        symbol: "airplane",
        kind: .nativeCLI(command: "copilot", args: ["--acp"]),
        systemCommand: nil,
        authHint: "Uses your GitHub Copilot CLI login (copilot login) and your Copilot plan.",
        approximateInstallBytes: 0,
        extraSearchDirectories: ["~/.local/bin", "~/.npm-global/bin"],
        loginCommand: "copilot login",
        authenticationPolicy: .userInitiated,
        installHint: "Install GitHub Copilot CLI (brew install copilot-cli, or npm install -g @github/copilot), then press Detect Again.",
        isExperimental: true)

    /// Kimi Code CLI (`kimi acp`). stdout carries the protocol only; stderr is diagnostics.
    static let kimi = IDEACPAdapterEntry(
        id: "kimi",
        presetID: "kimi",
        name: "Kimi Code",
        provider: "Moonshot AI",
        symbol: "moon.stars",
        kind: .nativeCLI(command: "kimi", args: ["acp"]),
        systemCommand: nil,
        authHint: "Uses your Kimi Code login. Run kimi login in Terminal if Umbra says you need to sign in.",
        approximateInstallBytes: 0,
        extraSearchDirectories: ["~/.local/bin"],
        loginCommand: "kimi login",
        authenticationPolicy: .userInitiated,
        installHint: "Install Kimi Code CLI (uv tool install kimi-cli), then press Detect Again.")

    /// Qwen Code (`qwen --acp`; the older `--experimental-acp` is deprecated and never used).
    static let qwen = IDEACPAdapterEntry(
        id: "qwen",
        presetID: "qwen",
        name: "Qwen Code",
        provider: "Alibaba",
        symbol: "q.circle",
        kind: .nativeCLI(command: "qwen", args: ["--acp"]),
        systemCommand: nil,
        authHint: "Uses your Qwen Code authentication and settings. Run qwen in Terminal and sign in with /auth if Umbra says you need to.",
        approximateInstallBytes: 0,
        extraSearchDirectories: ["~/.local/bin", "~/.npm-global/bin"],
        loginCommand: "qwen",
        authenticationPolicy: .userInitiated,
        installHint: "Install Qwen Code (npm install -g @qwen-code/qwen-code), then press Detect Again.")

    /// The custom executable row: not installable, always user-managed.
    static let custom = IDEACPAdapterEntry(
        id: "custom",
        presetID: "custom",
        name: "Custom",
        provider: "You",
        symbol: "slider.horizontal.3",
        kind: .custom,
        systemCommand: nil,
        authHint: "Whatever the program you configure needs.",
        approximateInstallBytes: 0)

    static let entries: [IDEACPAdapterEntry] = [codex, claude, gemini, opencode, kiro, cursor, muse, antigravity, copilot, kimi, qwen]

    static func entry(id: String) -> IDEACPAdapterEntry? { entries.first { $0.id == id } }
    static func entry(presetID: String?) -> IDEACPAdapterEntry? {
        guard let presetID else { return nil }
        return entries.first { $0.presetID == presetID }
    }

    /// Entries Umbra can install itself.
    static var managedEntries: [IDEACPAdapterEntry] { entries.filter(\.isManaged) }
}
