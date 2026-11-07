import Foundation

/// Where a skill or command came from. A host asks before it believes the `allowed-tools` of something a
/// repository ships (`project`, `ancestor`); the user's own folders and the app's are theirs.
public enum SkillScope: String, Sendable, Equatable {
    case project
    case ancestor
    case user
    case app

    /// True for folders that travel with a repository, which may be someone else's.
    public var comesFromRepository: Bool { self == .project || self == .ancestor }
}

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
    public var scope: SkillScope
    /// False with `disable-model-invocation: true`: the model is not told the skill exists, only the user
    /// can start it (`/name`).
    public var modelInvocable: Bool
    /// False with `user-invocable: false`: the skill is for the model only, so `/` and `@skill:` do not offer it.
    public var userInvocable: Bool

    public init(
        name: String, description: String, body: String, directory: URL, allowedTools: [String] = [],
        paths: [String] = [], source: String = "", scope: SkillScope = .project,
        modelInvocable: Bool = true, userInvocable: Bool = true
    ) {
        self.name = name
        self.description = description
        self.body = body
        self.directory = directory
        self.allowedTools = allowedTools
        self.paths = paths
        self.source = source
        self.scope = scope
        self.modelInvocable = modelInvocable
        self.userInvocable = userInvocable
    }

    /// The `SKILL.md` this skill was read from.
    public var location: URL { directory.appendingPathComponent("SKILL.md") }
}

/// Something worth telling the user about a skill file: loaded with a warning, or left out.
public struct SkillDiagnostic: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case warning
        case skipped
    }

    public var kind: Kind
    public var path: String
    public var skillName: String?
    public var message: String

    public init(kind: Kind, path: String, skillName: String? = nil, message: String) {
        self.kind = kind
        self.path = path
        self.skillName = skillName
        self.message = message
    }
}

/// The skills and commands found in the folders a host chose, earlier folders winning when two use a
/// name (a project's over the user's). Reading is plain file access; nothing is run.
public struct SkillCatalog: Sendable, Equatable {
    public struct Location: Sendable, Equatable {
        public var url: URL
        /// What the list calls it: `.claude/skills`, `~/.claude/skills`.
        public var label: String
        public var scope: SkillScope

        public init(url: URL, label: String, scope: SkillScope = .project) {
            self.url = url
            self.label = label
            self.scope = scope
        }
    }

    public static let maxFileBytes = 256_000
    /// The longest name the specification allows; a longer one loads with a warning.
    public static let maxNameLength = 64
    static let maxCommandFiles = 300
    static let maxCommandDepth = 4

    public private(set) var skills: [Skill]
    public private(set) var commands: [CommandTemplate]
    /// What reading the folders turned up. Not part of `fingerprint`: the model never sees it.
    public private(set) var diagnostics: [SkillDiagnostic]
    /// Skills that lost their name to an earlier folder, for a list that wants to say so.
    public private(set) var shadowed: [Skill]

    public init(
        skills: [Skill] = [], commands: [CommandTemplate] = [],
        diagnostics: [SkillDiagnostic] = [], shadowed: [Skill] = []
    ) {
        self.skills = skills.sorted { $0.name.lowercased() < $1.name.lowercased() }
        self.commands = commands.sorted { $0.name.lowercased() < $1.name.lowercased() }
        self.diagnostics = diagnostics
        self.shadowed = shadowed
    }

    public var isEmpty: Bool { skills.isEmpty && commands.isEmpty }

    public func skill(named name: String) -> Skill? { skills.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    public func command(named name: String) -> CommandTemplate? { commands.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    /// The skills the model may load: everything not marked `disable-model-invocation`.
    public var modelSkills: [Skill] { skills.filter(\.modelInvocable) }

    /// The same catalog without the skills the user switched off (names compare ignoring case).
    public func excluding(_ names: Set<String>) -> SkillCatalog {
        guard !names.isEmpty else { return self }
        let lowered = Set(names.map { $0.lowercased() })
        return SkillCatalog(
            skills: skills.filter { !lowered.contains($0.name.lowercased()) }, commands: commands,
            diagnostics: diagnostics, shadowed: shadowed)
    }

    /// Changes when a skill's name, description or text does, so a host can start a new session for it.
    public var fingerprint: String {
        let parts = skills.map {
            "\($0.name)\u{0}\($0.description)\u{0}\(ReadLedger.hash($0.body))\u{0}\($0.directory.path)\u{0}\($0.modelInvocable)"
        }
        return String(ReadLedger.hash(parts.joined(separator: "\u{1}")), radix: 16)
    }

    // MARK: - Loading

    public static func load(skillFolders: [Location], commandFolders: [Location]) -> SkillCatalog {
        var diagnostics: [SkillDiagnostic] = []
        var skills: [Skill] = []
        var shadowed: [Skill] = []
        var winners: [String: Skill] = [:]
        for folder in skillFolders {
            for skill in loadSkills(in: folder, diagnostics: &diagnostics) {
                if let winner = winners[skill.name.lowercased()] {
                    shadowed.append(skill)
                    diagnostics.append(SkillDiagnostic(
                        kind: .warning, path: skill.location.path, skillName: skill.name,
                        message: "Shadowed by the skill of the same name in \(winner.source), which is read first."))
                } else {
                    winners[skill.name.lowercased()] = skill
                    skills.append(skill)
                }
            }
        }
        var commands: [CommandTemplate] = []
        var seenCommands = Set<String>()
        for folder in commandFolders {
            for command in loadCommands(in: folder) where seenCommands.insert(command.name.lowercased()).inserted { commands.append(command) }
        }
        return SkillCatalog(skills: skills, commands: commands, diagnostics: diagnostics, shadowed: shadowed)
    }

    private static func loadSkills(in folder: Location, diagnostics: inout [SkillDiagnostic]) -> [Skill] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: folder.url.path) else { return [] }
        var skills: [Skill] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let directory = folder.url.appendingPathComponent(entry, isDirectory: true)
            var isDirectory: ObjCBool = false
            let file = directory.appendingPathComponent("SKILL.md")
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  fileManager.fileExists(atPath: file.path)
            else { continue }
            guard let contents = readText(file) else {
                diagnostics.append(SkillDiagnostic(
                    kind: .skipped, path: file.path,
                    message: "Not loaded: SKILL.md is over \(maxFileBytes / 1_000) KB or is not UTF-8 text."))
                continue
            }
            let document = MarkdownFrontmatter.parse(contents)
            let declared = document.text("name")
            let name = sanitized(declared ?? entry)
            guard !name.isEmpty else {
                diagnostics.append(SkillDiagnostic(kind: .skipped, path: file.path, message: "Not loaded: the skill has no usable name."))
                continue
            }
            func warn(_ message: String) {
                diagnostics.append(SkillDiagnostic(kind: .warning, path: file.path, skillName: name, message: message))
            }
            if let declared, declared != name, sanitized(declared) != declared.trimmingCharacters(in: .whitespaces) {
                warn("The name \"\(declared)\" has characters that cannot be typed after a slash, so it is called \"\(name)\".")
            } else if name != entry {
                warn("The name \"\(name)\" does not match its folder \"\(entry)\".")
            }
            if name.count > maxNameLength { warn("The name is longer than \(maxNameLength) characters.") }

            var description = document.text("description")
            if description == nil {
                let fallback = CommandTemplate.firstLine(of: document.body)
                guard !fallback.isEmpty else {
                    diagnostics.append(SkillDiagnostic(
                        kind: .skipped, path: file.path, skillName: name,
                        message: "Not loaded: there is no description and no instructions."))
                    continue
                }
                warn("There is no description, so the first line of the instructions is used.")
                description = fallback
            }
            skills.append(Skill(
                name: name, description: description ?? "",
                body: document.body, directory: directory, allowedTools: document.list("allowed-tools"),
                paths: document.list("paths"), source: folder.label, scope: folder.scope,
                modelInvocable: !document.flag("disable-model-invocation"),
                userInvocable: document.flag("user-invocable", default: true)))
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
                    let command = CommandTemplate(relativePath: prefix + entry, contents: contents, source: folder.label, scope: folder.scope)
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
