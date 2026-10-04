import Foundation

/// Loads a skill's instructions, or a file from its folder. The tool's description lists every skill,
/// so the model can see what exists and ask for what the task needs. It reads inside the skill's own
/// folder only, which is why a user-level skill can ship scripts and notes the project jail would hide.
public struct SkillTool: AgentTool {
    public static let maxFileBytes = 64_000
    static let maxListedFiles = 60
    static let maxDescriptionLength = 220
    static let maxCatalogBytes = 8_000

    public let catalog: SkillCatalog

    public init(catalog: SkillCatalog) { self.catalog = catalog }

    public var risk: ToolRisk { .read }

    public var definition: ToolDefinition {
        var listing = ""
        for skill in catalog.skills {
            let description = skill.description.count > Self.maxDescriptionLength
                ? String(skill.description.prefix(Self.maxDescriptionLength - 1)) + "…" : skill.description
            let line = "- \(skill.name): \(description)\n"
            guard listing.utf8.count + line.utf8.count <= Self.maxCatalogBytes else {
                listing += "- (more skills exist; ask for one by name)\n"
                break
            }
            listing += line
        }
        return ToolDefinition(
            name: "skill",
            description: """
            Load a skill: written instructions for a kind of task, kept by the user or the project. When a task matches \
            one of these, load it first and follow it. With `file`, read a file from that skill's folder instead \
            (a script, a reference the instructions mention).
            Skills:
            \(listing)
            """,
            parameters: [
                ToolParameter("name", .string, "The skill's name."),
                ToolParameter("file", .string, "A file inside the skill's folder, such as references/api.md.", optional: true),
            ])
    }

    public func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let name = try arguments.string("name")
        guard let skill = catalog.skill(named: name) else {
            throw ToolError("No skill named \"\(name)\". Available: \(catalog.skills.map(\.name).joined(separator: ", ")).")
        }
        if let file = try arguments.optionalString("file"), !file.isEmpty {
            return try Self.readFile(file, in: skill)
        }
        var text = skill.body
        let others = Self.listFiles(in: skill.directory)
        if !others.isEmpty {
            text += "\n\n[Files in this skill's folder: \(others.joined(separator: ", ")). Read one with skill(name: \"\(skill.name)\", file: …).]"
        }
        return text
    }

    /// A file inside the skill's folder, after symlinks and `..` are resolved.
    static func readFile(_ file: String, in skill: Skill) throws -> String {
        let root = skill.directory.resolvingSymlinksInPath().standardizedFileURL.path
        let target = skill.directory.appendingPathComponent(file).resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(root + "/") else {
            throw ToolError("\(file) is outside the skill's folder. Only files inside it can be read.")
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path), let size = attributes[.size] as? Int else {
            throw ToolError("\(file) does not exist in the skill \"\(skill.name)\".")
        }
        guard size <= maxFileBytes else { throw ToolError("\(file) is \(size) bytes; at most \(maxFileBytes) can be read.") }
        guard let data = try? Data(contentsOf: target), let text = String(data: data, encoding: .utf8) else {
            throw ToolError("\(file) is not a text file.")
        }
        return text
    }

    /// Files other than SKILL.md, relative to the folder, a few levels deep.
    static func listFiles(in directory: URL) -> [String] {
        var found: [String] = []
        let base = directory.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        for case let url as URL in enumerator {
            guard found.count < maxListedFiles else { break }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                enumerator.skipDescendants()
                continue
            }
            if relative.split(separator: "/").count > 3 { enumerator.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, relative != "SKILL.md" else { continue }
            found.append(relative)
        }
        return found.sorted()
    }
}
