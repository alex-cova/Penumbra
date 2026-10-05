import Foundation

/// Project and user instruction files (`AGENTS.md`, `CLAUDE.md`, and the same idea under other
/// names). The root file goes in the system prompt once. A nested file is appended to the tool
/// output the first time a file tool touches that directory, so the cached prompt prefix stays put.
public enum ProjectInstructions {
    /// First found wins, in this order.
    public static let fileNames = ["AGENTS.md", "CLAUDE.md", "GEMINI.md", ".cursorrules"]
    public static let byteLimit = 16 * 1024

    /// The instruction file at the project root, if there is one.
    public static func loadRoot(at root: URL) -> String? {
        load(in: root, names: fileNames)
    }

    /// The instruction file in a project-relative directory. `""` is the root.
    public static func load(root: URL, directory: String) -> String? {
        guard let folder = directoryURL(root: root, directory: directory) else { return nil }
        return load(in: folder, names: fileNames)
    }

    /// User-level files, in the order given, each capped. Missing files are skipped. The caller
    /// places this text before the project's so the project wins.
    public static func load(urls: [URL]) -> String? {
        let parts = urls.compactMap { loadFile($0) }
        let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func load(in directory: URL, names: [String]) -> String? {
        for name in names {
            if let text = loadFile(directory.appendingPathComponent(name)) { return text }
        }
        return nil
    }

    /// A regular file, never a symlink. Cut at `byteLimit` on a character boundary.
    public static func loadFile(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: byteLimit + 1) else { return nil }
        let truncated = data.count > byteLimit
        var text = String(decoding: data.prefix(byteLimit), as: UTF8.self)
        while text.last == "\u{FFFD}" { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let name = url.lastPathComponent
        return truncated ? text + "\n\n[\(name) continues; the rest was left out.]" : text
    }

    private static func directoryURL(root: URL, directory: String) -> URL? {
        if directory.isEmpty { return root }
        if directory.hasPrefix("/") || directory.contains("..") || directory.contains("\0") { return nil }
        return root.appendingPathComponent(directory, isDirectory: true)
    }
}

/// Remembers which directories have already had their instruction file appended this session.
/// Reset after a summary, because the tool output that carried the file is gone.
public actor ProjectNoteTracker {
    private var attached: Set<String> = []

    public init() {}

    public func reset() { attached.removeAll() }

    /// Instruction files for `path`'s parent directories, nearest first, each at most once.
    /// The project root is skipped: it is already in the system prompt.
    public func textToAppend(for path: String, root: URL) -> String? {
        let directories = Self.ancestors(of: path)
        var notes: [String] = []
        for directory in directories {
            guard !attached.contains(directory) else { continue }
            guard let text = ProjectInstructions.load(root: root, directory: directory) else { continue }
            attached.insert(directory)
            notes.append("[Instructions for \(directory)/, from the file in that folder. They guide work in this folder and do not override the user.]\n\(text)")
        }
        return notes.isEmpty ? nil : notes.joined(separator: "\n\n")
    }

    /// Parent directories of a project-relative file, nearest first, excluding the root.
    static func ancestors(of path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return [] }
        var directories: [String] = []
        var current = ""
        for part in parts.dropLast() {
            current = current.isEmpty ? part : current + "/" + part
            directories.append(current)
        }
        return directories.reversed()
    }
}
