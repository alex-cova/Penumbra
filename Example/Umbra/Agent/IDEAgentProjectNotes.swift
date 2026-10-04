import Foundation

/// The project's own instructions for coding agents: `AGENTS.md` at the project root, else
/// `CLAUDE.md`. They go to the model in the system prompt, under a heading that says whose they
/// are, so the model follows the project's conventions without being asked.
enum IDEAgentProjectNotes {
    static let fileNames = ["AGENTS.md", "CLAUDE.md"]
    /// Large enough for a thorough instruction file, small enough not to eat a local model's window.
    static let byteLimit = 16 * 1024

    static func load(root: URL) -> String? {
        for name in fileNames {
            let url = root.appendingPathComponent(name)
            // A symlink could point anywhere on disk; the instructions file must be a file in the project.
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let handle = try? FileHandle(forReadingFrom: url)
            else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: byteLimit + 1) else { continue }
            let truncated = data.count > byteLimit
            // Cutting at the byte limit can split a character; drop the broken tail.
            var text = String(decoding: data.prefix(byteLimit), as: UTF8.self)
            while text.last == "\u{FFFD}" { text.removeLast() }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            return truncated ? text + "\n\n[\(name) continues; the rest was left out.]" : text
        }
        return nil
    }
}
