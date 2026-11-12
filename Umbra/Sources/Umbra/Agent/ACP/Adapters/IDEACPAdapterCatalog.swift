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
        authHint: "Uses the providers you signed in to with opencode.",
        approximateInstallBytes: 0)

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

    static let entries: [IDEACPAdapterEntry] = [codex, claude, gemini, opencode]

    static func entry(id: String) -> IDEACPAdapterEntry? { entries.first { $0.id == id } }
    static func entry(presetID: String?) -> IDEACPAdapterEntry? {
        guard let presetID else { return nil }
        return entries.first { $0.presetID == presetID }
    }

    /// Entries Umbra can install itself.
    static var managedEntries: [IDEACPAdapterEntry] { entries.filter(\.isManaged) }
}
