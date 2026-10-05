import AgentKit
import Foundation

/// The project's own instructions for coding agents: `AGENTS.md` at the project root, else
/// `CLAUDE.md`. They go to the model in the system prompt, under a heading that says whose they
/// are, so the model follows the project's conventions without being asked.
/// The project's root instructions. Loading lives in AgentKit (`ProjectInstructions`) so every host,
/// including AgentEval, reads the same files the same way.
enum IDEAgentProjectNotes {
    static let fileNames = ProjectInstructions.fileNames
    static let byteLimit = ProjectInstructions.byteLimit

    static func load(root: URL) -> String? {
        ProjectInstructions.loadRoot(at: root)
    }

    /// `~/.claude/CLAUDE.md` and Umbra's own file, only when the user has opted in. Missing files
    /// are skipped. There is no walk above the project folder.
    @MainActor
    static func loadUser(settings: IDEAgentSettings) -> String? {
        guard settings.loadsUserInstructions else { return nil }
        var urls: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        urls.append(home.appendingPathComponent(".claude/CLAUDE.md"))
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let folder = support.appendingPathComponent("com.umbra.editor", isDirectory: true)
            urls.append(folder.appendingPathComponent("AGENTS.md"))
            urls.append(folder.appendingPathComponent("CLAUDE.md"))
        }
        return ProjectInstructions.load(urls: urls)
    }
}
