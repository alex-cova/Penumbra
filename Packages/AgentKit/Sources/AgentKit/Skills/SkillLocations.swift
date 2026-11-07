import Foundation

extension SkillCatalog {
    /// How far above the project folder the search for a repository goes.
    static let maxAncestorLevels = 8

    /// The folders a host reads for `kind` (`skills`, `commands` or `agents`), in the order they win:
    ///
    /// 1. the project's `.umbra/<kind>` and `.claude/<kind>`, and for skills `.agents/skills`, the folder other
    ///    clients that follow the Agent Skills convention share;
    /// 2. for skills, the same `.claude/skills` and `.agents/skills` in each folder above the project, nearest
    ///    first, up to the folder that holds `.git`. That is what finds a repository's skills when a window opens
    ///    one of its subfolders. Nothing is read above a folder without `.git` in reach, and the walk never takes
    ///    the home folder, which is the user's scope below;
    /// 3. the user's `~/.claude/<kind>` and for skills `~/.agents/skills`, only when `includeUserFolders`;
    /// 4. the app's own folder in `appSupport`.
    ///
    /// Only existence checks on disk; nothing is run.
    public static func standardLocations(
        kind: String, projectRoot: URL?, home: URL?, includeUserFolders: Bool, appSupport: URL?, appLabel: String = "App"
    ) -> [Location] {
        let isSkills = kind == "skills"
        var locations: [Location] = []
        if let projectRoot {
            locations.append(Location(url: projectRoot.appendingPathComponent(".umbra/\(kind)"), label: ".umbra/\(kind)", scope: .project))
            locations.append(Location(url: projectRoot.appendingPathComponent(".claude/\(kind)"), label: ".claude/\(kind)", scope: .project))
            if isSkills {
                locations.append(Location(url: projectRoot.appendingPathComponent(".agents/skills"), label: ".agents/skills", scope: .project))
                locations += ancestorLocations(of: projectRoot, home: home)
            }
        }
        if includeUserFolders, let home {
            locations.append(Location(url: home.appendingPathComponent(".claude/\(kind)"), label: "~/.claude/\(kind)", scope: .user))
            if isSkills {
                locations.append(Location(url: home.appendingPathComponent(".agents/skills"), label: "~/.agents/skills", scope: .user))
            }
        }
        if let appSupport {
            locations.append(Location(url: appSupport.appendingPathComponent(kind), label: "\(appLabel) \(kind)", scope: .app))
        }
        return locations
    }

    /// `.claude/skills` and `.agents/skills` of the folders between `root` and its repository's top.
    static func ancestorLocations(of root: URL, home: URL?) -> [Location] {
        let fileManager = FileManager.default
        func hasGit(_ url: URL) -> Bool { fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) }

        let start = root.standardizedFileURL
        // The project is the repository: its own folders were read above.
        if hasGit(start) { return [] }
        let homePath = home?.standardizedFileURL.path
        var found: [Location] = []
        var current = start
        for level in 1...maxAncestorLevels {
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path || parent.path == "/" || parent.path == homePath { return [] }
            let up = String(repeating: "../", count: level)
            found.append(Location(url: parent.appendingPathComponent(".claude/skills"), label: up + ".claude/skills", scope: .ancestor))
            found.append(Location(url: parent.appendingPathComponent(".agents/skills"), label: up + ".agents/skills", scope: .ancestor))
            if hasGit(parent) { return found }
            current = parent
        }
        return []
    }
}
