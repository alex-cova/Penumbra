import Foundation

/// A kind of subagent the model can hand work to with the `task` tool. Built in: `general`. A host
/// adds more from `agents/*.md` files; reading is plain file access and nothing is run.
///
/// ```
/// ---
/// description: Reviews a diff for bugs
/// tools: [read_file, grep, git_diff]
/// mode: read-only
/// max-iterations: 12
/// model: helper
/// ---
/// Review the change the task names. Report only real defects, each with path:line.
/// ```
public struct AgentDefinition: Sendable, Equatable, Hashable {
    public var name: String
    /// One line the model reads in the `task` tool's description to pick an agent.
    public var description: String
    /// The tools the child may use, by name. Empty: every tool a child may have.
    public var tools: [String]
    /// May the child change files? Only then does it get the edit tools, and only when the session is
    /// in a mode that applies edits without asking.
    public var editsFiles: Bool
    public var maxIterations: Int
    /// The model the child runs on: a key the host resolves (`helper`, or a `provider:model` id).
    /// `nil` shares the parent's model.
    public var model: String?
    /// Added to the child's system prompt.
    public var instructions: String
    public var source: String

    public init(
        name: String, description: String, tools: [String] = [], editsFiles: Bool = false,
        maxIterations: Int = 15, model: String? = nil, instructions: String = "", source: String = ""
    ) {
        self.name = name
        self.description = description
        self.tools = tools
        self.editsFiles = editsFiles
        self.maxIterations = maxIterations
        self.model = model
        self.instructions = instructions
        self.source = source
    }

    /// Does the work a task describes, including changing files. The default agent.
    public static let general = AgentDefinition(
        name: "general",
        description: "Carries out a self-contained task with its own context: research, or a change to a few files. Use it for work that would fill your own context.",
        editsFiles: true, maxIterations: 25, source: "built in")

    /// Parses one `agents/<name>.md` file. `nil` for a name that is not usable.
    public static func parse(fileName: String, contents: String, source: String) -> AgentDefinition? {
        let document = MarkdownFrontmatter.parse(contents)
        let fallback = (fileName as NSString).deletingPathExtension
        let name = SkillCatalog.sanitized(document.text("name") ?? fallback)
        guard !name.isEmpty else { return nil }
        let mode = document.text("mode")?.lowercased()
        let edits = mode == "edit" || mode == "write"
        let iterations = document.text("max-iterations").flatMap { Int($0) }.map { min(max($0, 1), 60) } ?? (edits ? 25 : 15)
        let rawModel = document.text("model")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = rawModel?.isEmpty == false ? rawModel : nil
        return AgentDefinition(
            name: name,
            description: document.text("description") ?? CommandTemplate.firstLine(of: document.body),
            tools: document.list("tools").filter { !$0.isEmpty },
            editsFiles: edits, maxIterations: iterations, model: model,
            instructions: document.body, source: source)
    }
}

/// The agent definitions found in the folders a host chose, earlier folders winning when two use a
/// name, with the built-in `general` last so a file can replace it.
public struct AgentCatalog: Sendable, Equatable {
    public static let maxFiles = 50

    public private(set) var agents: [AgentDefinition]

    public init(agents: [AgentDefinition] = []) {
        var seen = Set<String>()
        var list = agents.filter { seen.insert($0.name.lowercased()).inserted }
        if seen.insert(AgentDefinition.general.name).inserted { list.append(.general) }
        self.agents = list.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    public static let builtIn = AgentCatalog()

    public func agent(named name: String) -> AgentDefinition? {
        agents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Changes when an agent's name, description, tools, model or text does, so a host can start a new session for it.
    public var fingerprint: String {
        let parts = agents.map {
            "\($0.name)\u{0}\($0.description)\u{0}\($0.tools.joined(separator: ","))\u{0}\($0.editsFiles)\u{0}\($0.maxIterations)\u{0}\($0.model ?? "")\u{0}\(ReadLedger.hash($0.instructions))"
        }
        return String(ReadLedger.hash(parts.joined(separator: "\u{1}")), radix: 16)
    }

    public static func load(folders: [SkillCatalog.Location]) -> AgentCatalog {
        var found: [AgentDefinition] = []
        var visited = 0
        for folder in folders {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.url.path) else { continue }
            for entry in entries.sorted() where entry.lowercased().hasSuffix(".md") && !entry.hasPrefix(".") {
                guard visited < maxFiles else { break }
                visited += 1
                guard let contents = SkillCatalog.readText(folder.url.appendingPathComponent(entry)),
                      let agent = AgentDefinition.parse(fileName: entry, contents: contents, source: folder.label)
                else { continue }
                found.append(agent)
            }
        }
        return AgentCatalog(agents: found)
    }
}
