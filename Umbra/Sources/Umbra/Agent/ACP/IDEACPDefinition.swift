import Foundation

/// One user-configured external ACP agent: a name and a command line.
///
/// Presets fill `presetID` when the row came from the built-in catalog. The executable is a
/// name or a path the user typed; it is resolved on `PATH` at launch and is never started
/// during discovery.
struct IDEACPDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// Executable as typed: an absolute or relative path, or a bare name resolved on `PATH`.
    var command: String
    var args: [String]
    /// Extra environment for the agent process. Secret values stay in the Keychain; this
    /// dictionary is for non-secret values only.
    var env: [String: String]
    /// Catalog id (`claude-code`, `codex`, …) when this row was created from a preset.
    var presetID: String?
    /// A disabled agent stays in the list and is not launched.
    var isEnabled: Bool
    /// `.auto` lets Umbra pick the launch for a catalog agent (managed adapter, verified system
    /// adapter, native CLI). `.custom` runs `command` and `args` exactly as typed.
    var launchMode: LaunchMode

    enum LaunchMode: String, Codable, Sendable {
        case auto
        case custom
    }

    init(
        id: UUID = UUID(), name: String, command: String, args: [String] = [], env: [String: String] = [:],
        presetID: String? = nil, isEnabled: Bool = true, launchMode: LaunchMode = .custom
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.presetID = presetID
        self.isEnabled = isEnabled
        self.launchMode = launchMode
    }

    var displayName: String { name.isEmpty ? command : name }

    /// The catalog entry this row follows, when Umbra picks its launch.
    var adapterEntry: IDEACPAdapterEntry? {
        launchMode == .auto ? IDEACPAdapterCatalog.entry(presetID: presetID) : nil
    }

    /// What to show when the executable cannot be resolved. A path is not a `PATH` lookup.
    var missingExecutableMessage: String {
        if command.contains("/") {
            return "Could not find the ACP agent executable “\(command)”."
        }
        return "Could not find the ACP agent executable “\(command)” on PATH."
    }

    /// The command line shown in settings. Parts that contain spaces are quoted.
    var commandLine: String {
        ([command] + args).map { part in
            part.contains(where: \.isWhitespace) ? "\"\(part.replacingOccurrences(of: "\"", with: "\\\""))\"" : part
        }.joined(separator: " ")
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, command, args, env, presetID, isEnabled, launchMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let decodedCommand = try container.decode(String.self, forKey: .command)
        command = decodedCommand
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        presetID = try container.decodeIfPresent(String.self, forKey: .presetID)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        // Rows saved before launch modes: a catalog row that ran a package runner or the adapter's
        // own command follows the catalog. Anything else is the user's command line.
        if let mode = try container.decodeIfPresent(LaunchMode.self, forKey: .launchMode) {
            launchMode = mode
        } else if let presetID, let preset = IDEACPRegistry.preset(id: presetID),
                  decodedCommand == "npx" || preset.launchers.contains(where: { $0.command == decodedCommand })
        {
            launchMode = .auto
        } else {
            launchMode = .custom
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        try container.encode(args, forKey: .args)
        try container.encode(env, forKey: .env)
        try container.encodeIfPresent(presetID, forKey: .presetID)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(launchMode, forKey: .launchMode)
    }

    /// Splits a typed command line into executable + arguments, honouring single/double quotes.
    static func parseCommandLine(_ text: String) -> (command: String, args: [String])? {
        let parts = split(text)
        guard let first = parts.first, !first.isEmpty else { return nil }
        return (first, Array(parts.dropFirst()))
    }

    static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var hasCurrent = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                hasCurrent = true
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                continue
            }
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
                hasCurrent = true
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                hasCurrent = true
                continue
            }
            if character.isWhitespace {
                if hasCurrent || !current.isEmpty { parts.append(current); current = ""; hasCurrent = false }
                continue
            }
            current.append(character)
            hasCurrent = true
        }
        if hasCurrent || !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Resolves the executable to an absolute path, searching `pathValue` for a bare name.
    /// `isExecutable` is the only filesystem check; nothing is spawned.
    func resolvedExecutable(
        pathValue: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if command.contains("/") {
            return isExecutable(command) ? command : nil
        }
        for directory in pathValue.split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(command)"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}
