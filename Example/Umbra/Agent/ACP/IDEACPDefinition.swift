import Foundation

/// One user-configured external ACP agent: a name and a command line (plan: command-based
/// definitions only, no auto-discovery in v1).
struct IDEACPDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// Executable as typed: an absolute/relative path, or a bare name resolved on `PATH`.
    var command: String
    var args: [String]
    /// Extra environment for the agent process. Values may name Keychain-backed secrets by
    /// literal value only; the settings UI stores them with the definition, never in a repo.
    var env: [String: String]

    init(id: UUID = UUID(), name: String, command: String, args: [String] = [], env: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }

    var displayName: String { name.isEmpty ? command : name }

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
    func resolvedExecutable(pathValue: String) -> String? {
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        for directory in pathValue.split(separator: ":") {
            let candidate = "\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
