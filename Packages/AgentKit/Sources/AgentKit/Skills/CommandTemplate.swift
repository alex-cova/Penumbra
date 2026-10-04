import Foundation

/// A prompt the user wrote once and runs with `/name`: a Markdown file whose body is the message.
/// `$ARGUMENTS` stands for everything typed after the name, `$1` … `$9` for its words.
public struct CommandTemplate: Sendable, Equatable {
    /// `lint`, or `frontend:lint` for `frontend/lint.md`.
    public var name: String
    public var description: String
    public var argumentHint: String?
    /// Tools the command may use without asking, as permission rules (`Bash(git add:*)`).
    public var allowedTools: [String]
    public var body: String
    /// Where it came from, for the list: `.claude/commands`, `~/.claude/commands`.
    public var source: String

    public init(
        name: String, description: String, argumentHint: String? = nil, allowedTools: [String] = [], body: String, source: String = ""
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.allowedTools = allowedTools
        self.body = body
        self.source = source
    }

    /// `relativePath` is the file's path inside the commands folder, `frontend/lint.md`.
    public init(relativePath: String, contents: String, source: String) {
        let document = MarkdownFrontmatter.parse(contents)
        var name = relativePath
        if name.lowercased().hasSuffix(".md") { name = String(name.dropLast(3)) }
        name = name.split(separator: "/").joined(separator: ":")
        self.init(
            name: name,
            description: document.text("description") ?? Self.firstLine(of: document.body),
            argumentHint: document.text("argument-hint"),
            allowedTools: document.list("allowed-tools"),
            body: document.body, source: source)
    }

    static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        return line.count > 100 ? String(line.prefix(99)) + "…" : line
    }

    /// The message to send. A command that never mentions its arguments still gets them, after the body.
    public func expand(arguments: String) -> String {
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = CommandSegments.words(trimmed)
        var result = ""
        var mentioned = false
        let characters = Array(body)
        var index = 0
        let marker = Array("$ARGUMENTS")
        while index < characters.count {
            if characters[index] == "$" {
                if characters[index...].starts(with: marker) {
                    result += trimmed
                    mentioned = true
                    index += marker.count
                    continue
                }
                if index + 1 < characters.count, let digit = characters[index + 1].wholeNumberValue, (1...9).contains(digit) {
                    result += digit <= words.count ? words[digit - 1] : ""
                    mentioned = true
                    index += 2
                    continue
                }
            }
            result.append(characters[index])
            index += 1
        }
        if !mentioned, !trimmed.isEmpty { result += "\n\nARGUMENTS: " + trimmed }
        return result
    }

    /// The body asks for shell output (`!`git status``) that AgentKit never runs; the host says so.
    public var usesShellSubstitution: Bool { body.contains("!`") }
}
