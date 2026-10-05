import Foundation

/// A folder of instructions the model can load when a task calls for them: `<name>/SKILL.md`, with
/// anything else in the folder (scripts, references) available through the `skill` tool.
public struct Skill: Sendable, Equatable {
    public var name: String
    public var description: String
    public var body: String
    public var directory: URL
    /// Tools the skill may use without asking while it is in use, as permission rules.
    public var allowedTools: [String]
    /// Globs. Empty means the skill is always listed. Otherwise it is listed only after a file tool
    /// has touched a matching path.
    public var paths: [String]
    public var source: String

    public init(
        name: String, description: String, body: String, directory: URL, allowedTools: [String] = [],
        paths: [String] = [], source: String = ""
    ) {
        self.name = name
        self.description = description
        self.body = body
        self.directory = directory
        self.allowedTools = allowedTools
        self.paths = paths
        self.source = source
    }
}

/// The skills and commands found in the folders a host chose, earlier folders winning when two use a
/// name (a project's over the user's). Reading is plain file access; nothing is run.
public struct SkillCatalog: Sendable, Equatable {
    public struct Location: Sendable, Equatable {
        public var url: URL
        /// What the list calls it: `.claude/skills`, `~/.claude/skills`.
        public var label: String

        public init(url: URL, label: String) {
            self.url = url
            self.label = label
        }
    }

    public static let maxFileBytes = 256_000
    static let maxCommandFiles = 300
    static let maxCommandDepth = 4

    public private(set) var skills: [Skill]
    public private(set) var commands: [CommandTemplate]

    public init(skills: [Skill] = [], commands: [CommandTemplate] = []) {
        self.skills = skills.sorted { $0.name.lowercased() < $1.name.lowercased() }
        self.commands = commands.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    public var isEmpty: Bool { skills.isEmpty && commands.isEmpty }

    public func skill(named name: String) -> Skill? { skills.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    public func command(named name: String) -> CommandTemplate? { commands.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    /// Changes when a skill's name, description or text does, so a host can start a new session for it.
    public var fingerprint: String {
        let parts = skills.map { "\($0.name)\u{0}\($0.description)\u{0}\(ReadLedger.hash($0.body))\u{0}\($0.directory.path)" }
        return String(ReadLedger.hash(parts.joined(separator: "\u{1}")), radix: 16)
    }

    // MARK: - Loading

    public static func load(skillFolders: [Location], commandFolders: [Location]) -> SkillCatalog {
        var skills: [Skill] = []
        var seenSkills = Set<String>()
        for folder in skillFolders {
            for skill in loadSkills(in: folder) where seenSkills.insert(skill.name.lowercased()).inserted { skills.append(skill) }
        }
        var commands: [CommandTemplate] = []
        var seenCommands = Set<String>()
        for folder in commandFolders {
            for command in loadCommands(in: folder) where seenCommands.insert(command.name.lowercased()).inserted { commands.append(command) }
        }
        return SkillCatalog(skills: skills, commands: commands)
    }

    private static func loadSkills(in folder: Location) -> [Skill] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: folder.url.path) else { return [] }
        var skills: [Skill] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let directory = folder.url.appendingPathComponent(entry, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let contents = readText(directory.appendingPathComponent("SKILL.md"))
            else { continue }
            let document = MarkdownFrontmatter.parse(contents)
            let name = sanitized(document.text("name") ?? entry)
            guard !name.isEmpty else { continue }
            skills.append(Skill(
                name: name, description: document.text("description") ?? CommandTemplate.firstLine(of: document.body),
                body: document.body, directory: directory, allowedTools: document.list("allowed-tools"),
                paths: document.list("paths"), source: folder.label))
        }
        return skills
    }

    private static func loadCommands(in folder: Location) -> [CommandTemplate] {
        var commands: [CommandTemplate] = []
        var visited = 0
        func walk(_ directory: URL, prefix: String, depth: Int) {
            guard depth <= maxCommandDepth, let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                guard visited < maxCommandFiles else { return }
                let url = directory.appendingPathComponent(entry)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    walk(url, prefix: prefix + entry + "/", depth: depth + 1)
                } else if entry.lowercased().hasSuffix(".md"), let contents = readText(url) {
                    visited += 1
                    let command = CommandTemplate(relativePath: prefix + entry, contents: contents, source: folder.label)
                    if !sanitized(command.name).isEmpty { commands.append(command) }
                }
            }
        }
        walk(folder.url, prefix: "", depth: 0)
        return commands
    }

    /// Text files only, and not unreasonably big.
    static func readText(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size <= maxFileBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Names are typed after a slash, so they are letters, digits and `-_.:`.
    static func sanitized(_ name: String) -> String {
        let mapped = name.trimmingCharacters(in: .whitespaces).map { character -> Character in
            character.isLetter || character.isNumber || "-_.:".contains(character) ? character : "-"
        }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
